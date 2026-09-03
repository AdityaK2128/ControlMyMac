#!/bin/bash
# Builds a distributable ControlMyMac.dmg.
#
# Distribution is a different signing story from development. A build
# signed with an "Apple Development" certificate runs on the machines in
# your team's provisioning profile and nowhere else — on anyone else's
# Mac, Gatekeeper refuses it outright. Shipping needs:
#
#   1. a "Developer ID Application" certificate (Apple Developer Program,
#      $99/year — the free tier does not issue one)
#   2. the hardened runtime, which scripts/build.sh already enables
#   3. notarization: Apple scans the upload and returns a ticket
#   4. stapling, so the ticket travels with the download and the first
#      launch works offline
#
# Steps 1-2 happen here unconditionally. Steps 3-4 need credentials, so
# they run only if you have stored a notarytool profile:
#
#   xcrun notarytool store-credentials ControlMyMac \
#     --apple-id you@example.com --team-id TEAMID --password APP-SPECIFIC-PW
#
#   NOTARY_PROFILE=ControlMyMac ./scripts/package.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="ControlMyMac"
APP="$ROOT/build/$APP_NAME.app"
VOLUME="$APP_NAME"
DMG="$ROOT/build/$APP_NAME.dmg"
STAGING="$ROOT/build/dmg-staging"

DEVELOPER_ID="$(security find-identity -v -p codesigning \
  | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"

if [ -n "$DEVELOPER_ID" ]; then
  echo "==> distribution identity: $DEVELOPER_ID"
  CODESIGN_IDENTITY="$DEVELOPER_ID" "$ROOT/scripts/build.sh"
else
  echo "warning: no 'Developer ID Application' certificate in the keychain." >&2
  echo "         Building with whatever signs locally. The result runs on" >&2
  echo "         YOUR Mac only — Gatekeeper will block it everywhere else." >&2
  "$ROOT/scripts/build.sh"
fi

[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }

echo "==> staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
# The drag-to-install convention. Without it people run the app from
# inside the mounted image, where it cannot be updated and its TCC
# grants are attached to a path that disappears on eject.
ln -s /Applications "$STAGING/Applications"

echo "==> building disk image"
hdiutil create -volname "$VOLUME" \
               -srcfolder "$STAGING" \
               -ov -format UDZO \
               "$DMG" | sed 's/^/    /'
rm -rf "$STAGING"

if [ -n "$DEVELOPER_ID" ]; then
  echo "==> signing the disk image"
  codesign --force --sign "$DEVELOPER_ID" "$DMG"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  if [ -z "$DEVELOPER_ID" ]; then
    echo "error: notarization needs a Developer ID certificate." >&2
    exit 1
  fi
  echo "==> notarizing (this takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "==> verifying as Gatekeeper sees it"
  spctl --assess --type open --context context:primary-signature -vv "$DMG" || true
else
  echo "==> skipping notarization (set NOTARY_PROFILE to enable)"
  echo "    Without it, downloaders get 'Apple could not verify ControlMyMac'"
  echo "    and have to right-click > Open to get past it."
fi

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "==> $DMG ($SIZE)"
