#!/bin/zsh
set -euo pipefail

readonly PROJECT_DIR="${0:A:h:h}"

typeset -i PREPARE_ONLY=0
typeset -i ALLOW_ADHOC=0
usage() {
    print -u2 "Usage: ${0:t} [--prepare-only] [--allow-adhoc]"
}
for argument in "$@"; do
    case "$argument" in
        --prepare-only)
            (( PREPARE_ONLY == 0 )) || { usage; exit 2; }
            PREPARE_ONLY=1
            ;;
        --allow-adhoc)
            (( ALLOW_ADHOC == 0 )) || { usage; exit 2; }
            ALLOW_ADHOC=1
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

readonly SPARKLE_ROOT="$("$PROJECT_DIR/scripts/prepare-sparkle.command")"
readonly GENERATE_APPCAST="$SPARKLE_ROOT/bin/generate_appcast"
readonly SPARKLE_ACCOUNT="${MACTICIAN_SPARKLE_ACCOUNT:-}"
readonly UPDATE_BASE_URL="${MACTICIAN_UPDATE_BASE_URL:-}"
readonly PRODUCT_URL="${MACTICIAN_UPDATE_PRODUCT_URL:-}"
readonly SSH_TARGET="${MACTICIAN_UPDATE_SSH_TARGET:-}"
readonly SSH_PORT="${MACTICIAN_UPDATE_SSH_PORT:-}"
readonly REMOTE_ROOT="${MACTICIAN_UPDATE_REMOTE_ROOT:-}"
readonly APP="${MACTICIAN_APP:-$PROJECT_DIR/dist/Mactician.app}"
readonly UPDATE_ROOT="${MACTICIAN_UPDATE_WORKDIR:-$PROJECT_DIR/dist/mactician-updates}"

if [[ -z "$SPARKLE_ACCOUNT" ]]; then
    print -u2 "MACTICIAN_SPARKLE_ACCOUNT must name the Sparkle Ed25519 key stored in Keychain."
    exit 2
fi
if [[ -z "$UPDATE_BASE_URL" || -z "$PRODUCT_URL" ]]; then
    print -u2 "MACTICIAN_UPDATE_BASE_URL and MACTICIAN_UPDATE_PRODUCT_URL must name the update host you control."
    exit 2
fi

if [[ ! -d "$APP" ]]; then
    print -u2 "Build Mactician before preparing an update."
    exit 1
fi

readonly INFO_PLIST="$APP/Contents/Info.plist"
readonly VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
readonly BUILD="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
readonly BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")"
readonly PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw "$INFO_PLIST")"
readonly DMG="${MACTICIAN_DMG:-$PROJECT_DIR/dist/Mactician-$VERSION.dmg}"
readonly RELEASE_BASENAME="Mactician-$VERSION"
readonly RELEASE_ARCHIVE="$UPDATE_ROOT/$RELEASE_BASENAME.dmg"
readonly RELEASE_NOTES_SOURCE="${MACTICIAN_RELEASE_NOTES:-$PROJECT_DIR/launcher/Resources/release-notes/$VERSION.md}"
readonly RELEASE_NOTES="$UPDATE_ROOT/$RELEASE_BASENAME.md"
readonly APPCAST="$UPDATE_ROOT/appcast.xml"

if [[ ! -f "$DMG" ]]; then
    print -u2 "Mactician DMG not found: $DMG"
    exit 1
fi

if [[ "$BUNDLE_ID" != "dev.sergeinaumov.mactician" ]]; then
    print -u2 "Unexpected launcher bundle identifier: $BUNDLE_ID"
    exit 1
fi
if [[ "$PUBLIC_KEY" != "dXc0pibzXEfshBc97jXV0dMBsrTbshGAQyIilZO7CP4=" ]]; then
    print -u2 "The launcher does not contain the expected Sparkle public key."
    exit 1
fi
if [[ ! -f "$RELEASE_NOTES_SOURCE" ]]; then
    print -u2 "Release notes not found: $RELEASE_NOTES_SOURCE"
    exit 1
fi

if (( PREPARE_ONLY == 0 )); then
    readonly CODESIGN_DETAILS="$(codesign -dvv "$APP" 2>&1)"
    if [[ "$CODESIGN_DETAILS" == *'Authority=Developer ID Application:'* ]]; then
        codesign --verify --deep --strict "$APP"
        xcrun stapler validate "$DMG"
        spctl --assess --type open --context context:primary-signature "$DMG"
    elif (( ALLOW_ADHOC == 1 )); then
        if [[ "$CODESIGN_DETAILS" != *'Signature=adhoc'* ]]; then
            print -u2 "The temporary release must contain a valid ad-hoc app signature."
            exit 1
        fi
        codesign --verify --deep --strict "$APP"
        hdiutil verify "$DMG" >/dev/null
        print -u2 "Warning: publishing an ad-hoc build without Apple notarization."
    else
        print -u2 "Publishing requires a Developer ID-signed launcher build."
        print -u2 "Use --allow-adhoc only for an explicitly approved temporary release."
        exit 1
    fi
fi

mkdir -p "$UPDATE_ROOT"
ditto "$DMG" "$RELEASE_ARCHIVE"
ditto "$RELEASE_NOTES_SOURCE" "$RELEASE_NOTES"

"$GENERATE_APPCAST" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "$UPDATE_BASE_URL/releases/" \
    --release-notes-url-prefix "$UPDATE_BASE_URL/releases/" \
    --link "$PRODUCT_URL" \
    --maximum-versions 3 \
    --maximum-deltas 5 \
    "$UPDATE_ROOT"

MACTICIAN_RELEASE_TITLE="Mactician $VERSION" \
    perl -0pi -e '
        s{(<channel>.*?<title>).*?(</title>)}{$1Mactician Updates$2}s;
        s{(<item>.*?<title>).*?(</title>)}{$1$ENV{MACTICIAN_RELEASE_TITLE}$2}s;
    ' "$APPCAST"

xmllint --noout "$APPCAST"
if ! grep -Fq '<title>Mactician Updates</title>' "$APPCAST" \
        || ! grep -Fq "<title>Mactician $VERSION</title>" "$APPCAST"; then
    print -u2 "Generated appcast titles do not match the Mactician release metadata."
    exit 1
fi
if ! grep -Fq 'sparkle:edSignature=' "$APPCAST"; then
    print -u2 "Generated appcast does not contain an Ed25519 archive signature."
    exit 1
fi

if (( PREPARE_ONLY == 1 )); then
    print "Prepared Sparkle feed with signed update archives: $APPCAST"
    exit 0
fi

if [[ -z "$SSH_TARGET" || -z "$SSH_PORT" || -z "$REMOTE_ROOT" ]]; then
    print -u2 "Publishing requires MACTICIAN_UPDATE_SSH_TARGET, MACTICIAN_UPDATE_SSH_PORT, and MACTICIAN_UPDATE_REMOTE_ROOT."
    exit 2
fi
if [[ "$SSH_PORT" != <-> ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    print -u2 "MACTICIAN_UPDATE_SSH_PORT must be a TCP port from 1 through 65535."
    exit 2
fi

case "$REMOTE_ROOT" in
    "/"|"/var"|"/var/www"|"/usr"|"/etc"|"/home"|"/tmp")
        print -u2 "Refusing unsafe remote update root: $REMOTE_ROOT"
        exit 2
        ;;
esac

remote_quote() {
    print -r -- "'${1//\'/\'\\\'\'}'"
}

ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "$SSH_TARGET" \
    "mkdir -p -- $(remote_quote "$REMOTE_ROOT/releases")"

typeset -a RELEASE_FILES
RELEASE_FILES=("$RELEASE_ARCHIVE" "$RELEASE_NOTES")
for release_file in "$UPDATE_ROOT"/Mactician"$BUILD"-*.delta(.N); do
    RELEASE_FILES+=("$release_file")
done

scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new \
    "${RELEASE_FILES[@]}" \
    "$SSH_TARGET:$REMOTE_ROOT/releases/"

readonly REMOTE_APPCAST_NEXT="$REMOTE_ROOT/.appcast-$BUILD.xml"
scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new \
    "$APPCAST" \
    "$SSH_TARGET:$REMOTE_APPCAST_NEXT"
ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "$SSH_TARGET" \
    "chmod 644 -- $(remote_quote "$REMOTE_APPCAST_NEXT") && mv -f -- $(remote_quote "$REMOTE_APPCAST_NEXT") $(remote_quote "$REMOTE_ROOT/appcast.xml")"

print "Published Mactician $VERSION (build $BUILD) to $UPDATE_BASE_URL"
