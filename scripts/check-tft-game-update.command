#!/bin/zsh
# Checks the public Google Play listing for VNG's "Dau Truong Chan Ly" TFT
# package (com.riotgames.league.teamfighttacticsvn) and reports whether its
# "last updated" date has moved past the date we last saw, and whether it
# has moved past the version currently pinned in release-manifest.json.
#
# This does NOT download or touch any APK. Play's public listing never
# exposes an exact versionName/versionCode, only a human "last updated"
# date, so this is a signal that a newer build likely exists -- not proof
# of the exact version. Confirm the real version/versionCode from the APK
# itself (aapt, or `adb shell dumpsys package`) before repinning.
#
# On a detected change: re-run scripts/switch-to-vng-tft.command with fresh
# split APKs (TFT_VNG_APK_DIR=... or TFT_VNG_SERIAL=...) to repin, then
# rebuild.
#
# Usage:
#   ./scripts/check-tft-game-update.command
#
# Exit codes:
#   0  no change since the last recorded check
#   1  Play's last-updated date moved forward (possible new game update)
#   2  usage/environment error (missing curl/jq, fetch failed, page shape changed)

set -euo pipefail

readonly PROJECT_DIR="${0:A:h:h}"
readonly PACKAGE="com.riotgames.league.teamfighttacticsvn"
readonly PLAY_URL="https://play.google.com/store/apps/details?id=${PACKAGE}&hl=vi"
readonly MANIFEST="$PROJECT_DIR/launcher/Resources/release-manifest.json"
readonly STATE_DIR="$PROJECT_DIR/private"
readonly STATE_FILE="$STATE_DIR/.tft-playstore-last-update"
readonly UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

command -v curl >/dev/null || { print -u2 "curl is required."; exit 2; }
command -v jq >/dev/null || { print -u2 "jq is required."; exit 2; }

readonly PAGE="$(curl -fsSL -A "$UA" -H 'Accept-Language: vi-VN,vi;q=0.9' "$PLAY_URL")"
[[ -n "$PAGE" ]] || { print -u2 "Empty response from Play Store. Network issue or the listing moved."; exit 2; }

# The label text is stable even when Play's obfuscated CSS class names churn;
# pull the very next '<div ...>...</div>' payload that follows it. python3
# is used (not perl) so the UTF-8 Vietnamese label matches as text, not bytes.
readonly LATEST_DATE="$(print -r -- "$PAGE" | python3 -c '
import re, sys
page = sys.stdin.read()
m = re.search(r"L\u1ea7n c\u1eadp nh\u1eadt g\u1ea7n \u0111\u00e2y nh\u1ea5t</div><div[^>]*>([^<]+)</div>", page)
if m:
    print(m.group(1))
')"
[[ -n "$LATEST_DATE" ]] || {
    print -u2 "Could not find the \"last updated\" date on the Play listing. The page layout likely changed; update this script's parser."
    exit 2
}

readonly PINNED_VERSION="$(jq -r '.game.version // "unknown"' "$MANIFEST")"
readonly PINNED_VERSION_CODE="$(jq -r '.game.versionCode // "unknown"' "$MANIFEST")"

mkdir -p "$STATE_DIR"
readonly PREVIOUS_DATE="$( [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || print -n '' )"

print "Package         : $PACKAGE"
print "Pinned version   : $PINNED_VERSION (code $PINNED_VERSION_CODE)"
print "Play last update : $LATEST_DATE"

if [[ -z "$PREVIOUS_DATE" ]]; then
    print "$LATEST_DATE" >"$STATE_FILE"
    print "No prior recorded check; recorded this as the baseline."
    exit 0
fi

if [[ "$LATEST_DATE" == "$PREVIOUS_DATE" ]]; then
    print "No change since the last check ($PREVIOUS_DATE)."
    exit 0
fi

print ""
print "Play's last-updated date moved: $PREVIOUS_DATE -> $LATEST_DATE"
print "A newer game build likely exists. To repin:"
print "  1. Get fresh split APKs for $PACKAGE (device pull or a trusted download)."
print "  2. TFT_VNG_APK_DIR=/path/to/splits ./scripts/switch-to-vng-tft.command"
print "  3. Copy the same splits into private/tft-apks-vng/ and rebuild."
print "$LATEST_DATE" >"$STATE_FILE"
exit 1
