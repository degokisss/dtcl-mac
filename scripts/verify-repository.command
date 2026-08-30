#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

readonly PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

fail() {
    print -u2 "Repository validation failed: $*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

require_command find
require_command jq
require_command perl
require_command plutil
require_command rg
require_command xattr
require_command xcrun
require_command zsh

typeset -a REQUIRED_FILES
REQUIRED_FILES=(
    .editorconfig
    .gitattributes
    .gitignore
    .github/workflows/ci.yml
    .github/ISSUE_TEMPLATE/bug_report.yml
    .github/ISSUE_TEMPLATE/feature_request.yml
    .github/ISSUE_TEMPLATE/config.yml
    .github/pull_request_template.md
    .github/repository-metadata.yml
    CHANGELOG.md
    CONTRIBUTING.md
    LICENSE
    NOTICE.md
    README.md
    SECURITY.md
    SUPPORT.md
    docs/architecture.md
    docs/benchmarks.md
    docs/building.md
    docs/launch-profiles.md
    docs/releasing.md
    docs/reproducibility.md
    docs/research-log.md
    docs/troubleshooting.md
    docs/telemetry-contract/SHA256SUMS
    docs/telemetry-contract/activation-snapshot-v2.json
    docs/telemetry-contract/daily-active-v2.json
    docs/telemetry-contract/first-game-session-v2.json
    docs/telemetry-contract/game-session-diagnostics-v2.json
    docs/telemetry-contract/game-session-summary-v2.json
    launcher/Info.plist
    launcher/Resources/EmulatorHost-Info.plist
    launcher/Resources/EmulatorIcon.icns
    launcher/Resources/EmulatorIcon-1024.png
    launcher/Resources/Mactician.icns
    launcher/Resources/Mactician-1024.png
    launcher/Resources/MacticianHero.png
    launcher/Resources/release-manifest.json
    scripts/android-environment.sh
    scripts/build-mactician.command
    scripts/build-mactician-icns.pl
    scripts/generate-mactician-assets.command
    scripts/integration-test-mactician.command
    scripts/publish-mactician-update.command
    scripts/test-mactician.command
    scripts/verify-branding.command
    scripts/verify-telemetry-contract.command
    scripts/verify-repository.command
    run-tft-best-verified.command
    branding/mactician-app-icon.svg
    branding/mactician-game-host-icon.svg
    branding/mactician-favicon.svg
    branding/mactician-mark.svg
    branding/mactician-mark-dark.svg
    branding/mactician-mark-light.svg
    branding/mactician-mark-monochrome.svg
    branding/mactician-open-graph.svg
    branding/mactician-product-hero.svg
    branding/mactician-small-size-test.svg
    branding/mactician-social-preview.svg
    branding/mactician-wordmark.svg
    branding/generated/Mactician.icns
    branding/generated/EmulatorIcon.icns
    branding/generated/mactician-favicon.ico
    branding/generated/mactician-open-graph.png
    branding/generated/mactician-small-size-test.png
    branding/generated/mactician-social-preview.png
)
for required_file in "${REQUIRED_FILES[@]}"; do
    [[ -f "$required_file" ]] || fail "required file is missing: $required_file"
done
[[ -x scripts/build-mactician-icns.pl ]] || fail "ICNS builder is not executable"

typeset script_file
while IFS= read -r script_file; do
    [[ -x "$script_file" ]] || fail "script is not executable: $script_file"
    zsh -o NO_BG_NICE -n "$script_file" || fail "zsh syntax check failed: $script_file"
done < <(find . -type f \( -name '*.command' -o -name '*.sh' \) \
    -not -path './.git/*' -not -path './launcher/.build/*' \
    -not -path './dist/*' -not -path './dist-build*/*' \
    -not -path './runtime/*' | LC_ALL=C sort)

plutil -lint launcher/Info.plist >/dev/null || fail "launcher Info.plist is invalid"
plutil -lint launcher/Resources/EmulatorHost-Info.plist >/dev/null \
    || fail "emulator host Info.plist is invalid"
plutil -lint launcher/Resources/QEMU-Hypervisor.entitlements >/dev/null \
    || fail "hypervisor entitlements are invalid"
typeset strings_file
for strings_file in launcher/Resources/*.lproj/Localizable.strings; do
    plutil -lint "$strings_file" >/dev/null || fail "strings file is invalid: $strings_file"
done

typeset json_file
while IFS= read -r json_file; do
    jq -e . "$json_file" >/dev/null || fail "JSON file is invalid: $json_file"
done < <(find . -type f -name '*.json' -not -path './.git/*' \
    -not -path './launcher/.build/*' -not -path './dist/*' \
    -not -path './dist-build*/*' -not -path './runtime/*' | LC_ALL=C sort)

xcrun clang -x objective-c -target arm64-apple-macosx12.0 \
    -fsyntax-only launcher/EmulatorHost/main.c

typeset developer_root="/""Users/"
typeset local_user="sb""naumov"
typeset path_match
while IFS= read -r path_match; do
    case "$path_match" in
        ./scripts/build-mactician.command:*|./launcher/Tests/LauncherTests.swift:*) ;;
        *) fail "developer-specific absolute path remains: $path_match" ;;
    esac
done < <(rg -n --hidden --glob '!.git' --glob '!.git/**' --glob '!launcher/.build/**' \
    --glob '!scripts/verify-repository.command' "$developer_root" . || true)

typeset identity_match
while IFS= read -r identity_match; do
    [[ "$identity_match" == *"local.${local_user}.tft-pbe-"* ]] \
        || fail "personal identifier remains outside the documented compatibility IDs: $identity_match"
done < <(rg -n --hidden --glob '!.git' --glob '!.git/**' --glob '!launcher/.build/**' \
    --glob '!scripts/verify-repository.command' "$local_user" . || true)

typeset codex_match
while IFS= read -r codex_match; do
    [[ "$codex_match" == *'Android_Codex'* ]] \
        || fail "workspace-only Codex label remains: $codex_match"
done < <(rg -ni --hidden --glob '!.git' --glob '!.git/**' --glob '!launcher/.build/**' \
    --glob '!scripts/verify-repository.command' 'codex' . || true)
while IFS= read -r codex_match; do
    [[ "${codex_match:t}" == Android_Codex.DeviceProfiles*.ini ]] \
        || fail "workspace-only Codex filename remains: $codex_match"
done < <(find . -iname '*codex*' -not -path './.git/*' \
    -not -path './launcher/.build/*' -not -path './dist/*' \
    -not -path './dist-build*/*' -not -path './runtime/*' | LC_ALL=C sort)

if rg -ni --hidden --glob '!.git' --glob '!.git/**' --glob '!launcher/.build/**' \
        --glob '!scripts/verify-repository.command' \
        'next chat|handoff for the next|managed workspace|documents/codex|files-mentioned-by-the-user' .; then
    fail "internal handoff or managed-workspace language remains"
fi

if rg -n '[А-Яа-яЁё]' --hidden --glob '!.git' --glob '!.git/**' --glob '!launcher/.build/**' \
        --glob '!launcher/Resources/ru.lproj/**' \
        --glob '!tools/tft-screen-classifier.swift' \
        --glob '!scripts/test-mactician.command' \
        --glob '!scripts/verify-repository.command' .; then
    fail "repository text is not in English"
fi

typeset junk_path
while IFS= read -r junk_path; do
    fail "macOS metadata or AppleDouble file remains: $junk_path"
done < <(find . \( -name '.DS_Store' -o -name '._*' \) -not -path './.git/*' \
    -not -path './launcher/.build/*' -not -path './dist/*' \
    -not -path './dist-build*/*' -not -path './runtime/*')

typeset attr_path
while IFS= read -r attr_path; do
    if [[ -n "$(xattr "$attr_path" 2>/dev/null)" ]]; then
        fail "extended attributes remain on: $attr_path"
    fi
done < <(find . -not -path './.git' -not -path './.git/*' \
    -not -path './launcher/.build' -not -path './launcher/.build/*' \
    -not -path './dist' -not -path './dist/*' \
    -not -path './dist-build*' -not -path './dist-build*/*' \
    -not -path './runtime' -not -path './runtime/*' \
    -not -path './private' -not -path './private/*')

typeset forbidden_path
while IFS= read -r forbidden_path; do
    if git check-ignore -q "$forbidden_path" 2>/dev/null; then
        continue
    fi
    fail "private or generated artifact is present and not ignored: $forbidden_path"
done < <(find . -type f \( -name '*.apk' -o -name '*.apks' -o -name '*.xapk' \
    -o -name '*.aab' -o -name '*.obb' -o -name '*.qcow2' -o -name 'userdata*.img' \
    -o -name 'encryptionkey*.img' -o -name '*.p12' -o -name '*.pfx' -o -name '*.jks' \
    -o -name '*.keystore' -o -name '*.key' -o -name '*.pem' -o -name '*.crt' \
    -o -name '*.cer' -o -name '*.mobileprovision' -o -name '*.token' \
    -o -name '*.secret' -o -name '.DS_Store' \) \
    -not -path './.git/*' -not -path './dist-build*/*')

if rg -n --hidden --glob '!.git' --glob '!.git/**' --glob '!launcher/.build/**' \
        --glob '!scripts/verify-repository.command' \
        -- '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}' .; then
    fail "text resembling a private key or access token remains"
fi

typeset owner_placeholder='<OW'"NER>"
typeset repository_placeholder='<REPOS'"ITORY>"
if rg -n --hidden --glob '!.git' --glob '!.git/**' --glob '!launcher/.build/**' \
        --glob '!scripts/verify-repository.command' \
        "$owner_placeholder|$repository_placeholder|NAME \(TEAM_ID\)|TODO_PUBLIC" .; then
    fail "publication placeholder remains"
fi

typeset markdown_file link target
while IFS= read -r markdown_file; do
    while IFS=$'\t' read -r link; do
        [[ -n "$link" ]] || continue
        case "$link" in
            \#*|http://*|https://*|mailto:*|../../releases/*) continue ;;
        esac
        link="${link%%#*}"
        link="${link%%\?*}"
        [[ -n "$link" ]] || continue
        [[ "$link" != /* ]] || fail "absolute local Markdown link in $markdown_file: $link"
        target="${markdown_file:h}/$link"
        [[ -e "$target" ]] || fail "broken Markdown link in $markdown_file: $link"
    done < <(perl -ne 'while (/\[[^]]*\]\(([^)]+)\)/g) { print "$1\n" }' "$markdown_file")
done < <(find . -type f -name '*.md' -not -path './.git/*' \
    -not -path './launcher/.build/*' -not -path './dist/*' \
    -not -path './dist-build*/*' -not -path './runtime/*' | LC_ALL=C sort)

typeset -a DOCUMENTED_LAUNCHERS
DOCUMENTED_LAUNCHERS=(
    run-tft-angle-opengl.command
    run-tft-best-verified.command
    run-tft-mvk128-experimental.command
)
typeset documented_launcher
for documented_launcher in "${DOCUMENTED_LAUNCHERS[@]}"; do
    [[ -x "$documented_launcher" ]] \
        || fail "documented launcher is absent or not executable: $documented_launcher"
done
while IFS= read -r documented_launcher; do
    [[ -f "$documented_launcher" || -f "scripts/$documented_launcher" ]] \
        || fail "documentation names a missing launcher: $documented_launcher"
done < <(rg -o --no-filename 'run-tft-[A-Za-z0-9-]+[.]command' \
    README.md launcher/README.md docs | LC_ALL=C sort -u)

typeset version build_number host_version host_build
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' launcher/Info.plist)"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' launcher/Info.plist)"
host_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' launcher/Resources/EmulatorHost-Info.plist)"
host_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' launcher/Resources/EmulatorHost-Info.plist)"
[[ "$version" == "$host_version" ]] || fail "launcher and emulator host versions differ"
[[ "$build_number" == "$host_build" ]] || fail "launcher and emulator host build numbers differ"
grep -Fq "Version: **$version** (build $build_number)" README.md \
    || fail "README version/build does not match Info.plist"
grep -Fq "version $version, build $build_number" CHANGELOG.md \
    || fail "CHANGELOG version/build does not match Info.plist"
grep -Fq "## Unreleased" CHANGELOG.md || fail "CHANGELOG has no Unreleased section"
grep -Fq "version $version, build $build_number" docs/releasing.md \
    || fail "release guide version/build does not match Info.plist"

[[ "$(plutil -extract CFBundleDisplayName raw launcher/Info.plist)" == "Mactician" ]] \
    || fail "unexpected app display name"
[[ "$(plutil -extract CFBundleExecutable raw launcher/Info.plist)" == "Mactician" ]] \
    || fail "unexpected app executable"
[[ "$(plutil -extract CFBundleIdentifier raw launcher/Info.plist)" \
    == "dev.sergeinaumov.mactician" ]] || fail "unexpected bundle identifier"
grep -Fq 'Mactician-$VERSION.dmg' scripts/build-mactician.command \
    || fail "versioned DMG naming is missing"
grep -Fq -- '-volname "Mactician"' scripts/build-mactician.command \
    || fail "DMG volume name is missing"
grep -Fq 'Sparkle-LICENSE.txt' scripts/build-mactician.command \
    || fail "Sparkle license is not packaged in the application"
grep -Fq 'readonly LICENSE_FILE=' scripts/prepare-sparkle.command \
    || fail "prepared Sparkle dependency does not retain its license"

jq -e '.schemaVersion == 1
    and (.components | length == 3)
    and (.game.apks | length == 4)
    and (.components[] | .sha256 | test("^[0-9a-f]{64}$"))
    and (.game.apks[] | .sha256 | test("^[0-9a-f]{64}$"))' \
    launcher/Resources/release-manifest.json >/dev/null \
    || fail "release manifest structure or hashes are invalid"

typeset required_ignore
for required_ignore in '/runtime/' '/dist/' '/dist-build*/' '/launcher/.build/' '/private/' '*.apk' '*.qcow2' '*.p12' '*.pem' '*.mobileprovision' '.DS_Store'; do
    grep -Fqx "$required_ignore" .gitignore \
        || fail ".gitignore lacks required rule: $required_ignore"
done

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git diff --check
    git diff --cached --check
fi

./scripts/verify-branding.command
./scripts/verify-telemetry-contract.command

print "Repository validation: OK ($version build $build_number)"
