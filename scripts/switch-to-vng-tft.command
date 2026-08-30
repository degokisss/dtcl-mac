#!/bin/zsh
# Migrates Mactician's pinned game target from Riot's global Direct package
# (com.riotgames.league.teamfighttactics) to VNG's Vietnam-licensed package
# (com.riotgames.league.teamfighttacticsvn, "Dau Truong Chan Ly"), which is
# published by VNG GROUP JSC under Vietnam's game distribution law but shares
# Riot's own support/account backend and SEA region.
#
# This script performs the FULL cutover atomically: it never leaves the repo
# with a manifest/build-script pointing at one package while source code
# expects another. If any step fails, nothing after it has been written.
#
# It needs real, unmodified split APKs for the target package. It never
# fabricates a hash: every value written comes from hashing real bytes you
# provide.
#
# Usage (four real split files already on disk):
#   TFT_VNG_APK_DIR=/path/to/vng/splits ./scripts/switch-to-vng-tft.command
#
# Usage (pull directly from a device where "Dau Truong Chan Ly" is installed
# and authorized for adb):
#   TFT_VNG_SERIAL=<adb-serial> ./scripts/switch-to-vng-tft.command
#
# Either mode requires that you are legitimately entitled to these bytes
# (your own install, your own device). This script does not download or
# source the APK itself.

set -euo pipefail

readonly PROJECT_DIR="${0:A:h:h}"
readonly OLD_PACKAGE="com.riotgames.league.teamfighttactics"
readonly NEW_PACKAGE="com.riotgames.league.teamfighttacticsvn"
readonly MANIFEST="$PROJECT_DIR/launcher/Resources/release-manifest.json"
readonly BUILD_SCRIPT="$PROJECT_DIR/scripts/build-mactician.command"
readonly WORK_DIR="$(mktemp -d /private/tmp/mactician-vng.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

typeset -a RENAME_TARGETS
RENAME_TARGETS=(
    "$PROJECT_DIR/launcher/Sources/CoreModels.swift"
    "$PROJECT_DIR/launcher/Sources/FPSOverlayService.swift"
    "$PROJECT_DIR/launcher/Sources/RiotLoginAnimationRepairService.swift"
    "$PROJECT_DIR/launcher/Resources/launcher-runtime.command"
    "$PROJECT_DIR/run-tft-gles32.command"
    "$PROJECT_DIR/run-tft-root-affinity.command"
    "$PROJECT_DIR/scripts/capture-frame-pacing.command"
    "$PROJECT_DIR/launcher/Tests/LauncherTests.swift"
    "$PROJECT_DIR/docs/reproducibility.md"
)

# --- 1. Collect real split APK bytes -----------------------------------
readonly SPLITS_DIR="$WORK_DIR/splits"
mkdir -p "$SPLITS_DIR"

if [[ -n "${TFT_VNG_SERIAL:-}" ]]; then
    readonly SERIAL="$TFT_VNG_SERIAL"
    readonly ADB="${TFT_VNG_ADB:-adb}"
    print "Pulling $NEW_PACKAGE splits from device $SERIAL..."
    typeset -a REMOTE_PATHS
    REMOTE_PATHS=("${(@f)$("$ADB" -s "$SERIAL" shell pm path "$NEW_PACKAGE" 2>/dev/null | tr -d '\r' | sed 's/^package://')}")
    if [[ ${#REMOTE_PATHS[@]} -eq 0 ]]; then
        print -u2 "No installed splits found for $NEW_PACKAGE on $SERIAL. Is the VNG app installed and adb authorized?"
        exit 1
    fi
    for remote in "${REMOTE_PATHS[@]}"; do
        local_name="${remote:t}"
        local_name="${local_name#split_}"
        "$ADB" -s "$SERIAL" pull "$remote" "$SPLITS_DIR/$local_name" >/dev/null
    done
    readonly VERSION_NAME="$("$ADB" -s "$SERIAL" shell dumpsys package "$NEW_PACKAGE" 2>/dev/null | tr -d '\r' | grep -m1 'versionName=' | sed 's/.*versionName=//')"
    readonly VERSION_CODE="$("$ADB" -s "$SERIAL" shell dumpsys package "$NEW_PACKAGE" 2>/dev/null | tr -d '\r' | grep -m1 'versionCode=' | sed -E 's/.*versionCode=([0-9]+).*/\1/')"
elif [[ -n "${TFT_VNG_APK_DIR:-}" ]]; then
    [[ -d "$TFT_VNG_APK_DIR" ]] || { print -u2 "TFT_VNG_APK_DIR does not exist: $TFT_VNG_APK_DIR"; exit 1; }
    cp "$TFT_VNG_APK_DIR"/*.apk "$SPLITS_DIR/"
    readonly VERSION_NAME="${TFT_VNG_VERSION:-}"
    readonly VERSION_CODE="${TFT_VNG_VERSION_CODE:-}"
    if [[ -z "$VERSION_NAME" || -z "$VERSION_CODE" ]]; then
        if command -v aapt >/dev/null 2>&1 && [[ -f "$SPLITS_DIR/base.apk" ]]; then
            badging="$(aapt dump badging "$SPLITS_DIR/base.apk")"
            [[ -z "$VERSION_NAME" ]] && readonly VERSION_NAME="$(print -r -- "$badging" | grep -m1 versionName | sed -E "s/.*versionName='([^']*)'.*/\1/")"
            [[ -z "$VERSION_CODE" ]] && readonly VERSION_CODE="$(print -r -- "$badging" | grep -m1 versionCode | sed -E "s/.*versionCode='([^']*)'.*/\1/")"
        else
            print -u2 "TFT_VNG_VERSION and TFT_VNG_VERSION_CODE must be set (no device/aapt available to read them from the APK)."
            exit 1
        fi
    fi
else
    print -u2 "Set TFT_VNG_APK_DIR=<dir with real splits> or TFT_VNG_SERIAL=<adb serial>."
    exit 1
fi

[[ -f "$SPLITS_DIR/base.apk" ]] || { print -u2 "No base.apk found among the collected splits."; exit 1; }
[[ -n "$VERSION_NAME" && -n "$VERSION_CODE" ]] || { print -u2 "Could not determine version/versionCode for $NEW_PACKAGE."; exit 1; }

print "Package    : $NEW_PACKAGE"
print "Version    : $VERSION_NAME (code $VERSION_CODE)"
print "Splits     : $(ls "$SPLITS_DIR")"

# --- 2. Optional sanity check: same Unreal activity names as today ------
if command -v aapt >/dev/null 2>&1; then
    badging="$(aapt dump badging "$SPLITS_DIR/base.apk")"
    for expected in "com.epicgames.unreal.SplashActivity" "com.epicgames.unreal.GameActivity"; do
        if ! print -r -- "$badging" | grep -q "$expected"; then
            print -u2 "Warning: $expected not found in the VNG base.apk manifest. run-tft-root-affinity.command and the FPS overlay assume this Activity exists; verify manually before relying on it."
        fi
    done
else
    print "aapt not found on PATH: skipping the Activity-name sanity check. Verify com.epicgames.unreal.SplashActivity/GameActivity manually if launch/FPS-overlay detection misbehaves."
fi

# --- 3. Compute real hashes and rewrite manifest + build script ---------
python3 - "$MANIFEST" "$BUILD_SCRIPT" "$SPLITS_DIR" "$NEW_PACKAGE" "$VERSION_NAME" "$VERSION_CODE" <<'PY'
import hashlib, json, os, re, sys

manifest_path, build_script_path, splits_dir, package, version, version_code = sys.argv[1:7]

names = sorted(os.listdir(splits_dir))
if "base.apk" in names:
    names.remove("base.apk")
    names = ["base.apk"] + names

entries = []
for name in names:
    path = os.path.join(splits_dir, name)
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    entries.append({
        "name": name,
        "size": os.path.getsize(path),
        "sha256": digest.hexdigest(),
    })

base_sha256 = entries[0]["sha256"]

with open(manifest_path) as f:
    manifest = json.load(f)

manifest["game"] = {
    "packageName": package,
    "version": version,
    "versionCode": int(version_code),
    "baseSHA256": base_sha256,
    "apks": entries,
}

with open(manifest_path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")

with open(build_script_path) as f:
    build_script = f.read()

hash_lines = "\n".join(f"    {e['name']} {e['sha256']}" for e in entries)
new_block = (
    "typeset -A EXPECTED_APK_HASHES\n"
    "EXPECTED_APK_HASHES=(\n"
    f"{hash_lines}\n"
    ")"
)
build_script, count = re.subn(
    r"typeset -A EXPECTED_APK_HASHES\nEXPECTED_APK_HASHES=\(\n(?:.*\n)*?\)",
    new_block,
    build_script,
    count=1,
)
if count != 1:
    sys.exit("Could not locate EXPECTED_APK_HASHES block in build-mactician.command")

with open(build_script_path, "w") as f:
    f.write(build_script)

print(f"Wrote {len(entries)} split(s) into release-manifest.json and build-mactician.command.")
PY

# --- 4. Rename the hardcoded package literal everywhere else ------------
for target in "${RENAME_TARGETS[@]}"; do
    [[ -f "$target" ]] || continue
    perl -0pi -e "s/\\Q$OLD_PACKAGE\\E(?!vn)/$NEW_PACKAGE/g" "$target"
done

print "Renamed $OLD_PACKAGE -> $NEW_PACKAGE in ${#RENAME_TARGETS[@]} source/doc files."

# --- 5. Verify -----------------------------------------------------------
"$PROJECT_DIR/scripts/verify-repository.command"
"$PROJECT_DIR/scripts/test-mactician.command"

print ""
print "Cutover complete. Remaining manual step: place these same split APKs in"
print "the directory you pass as TFT_GAME_APK_DIR to build-mactician.command."
