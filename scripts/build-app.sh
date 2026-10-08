#!/usr/bin/env bash
# Builds MeetingRecorder with Swift Package Manager and wraps it in a signed .app bundle.
#
# Why a bundle: macOS ties privacy permissions (Screen Recording, Microphone, Speech) to a
# bundle identifier and a code signature. A bare `swift run` binary gets re-prompted
# constantly and cannot read Info.plist usage strings, so the system refuses mic access.
#
# Usage:
#   scripts/build-app.sh                 # ad-hoc signed, fine for your own Mac
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
#   scripts/build-app.sh --open          # build then launch
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/MeetingRecorder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MeetingRecorder "$APP/Contents/MacOS/MeetingRecorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - --entitlements Resources/MeetingRecorder.entitlements "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements Resources/MeetingRecorder.entitlements "$APP"
fi

echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then
  open "$APP"
fi
