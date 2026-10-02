#!/bin/bash
# Builds and installs ControlMyMac.app into /Applications.
#
# Until you run this, the app only exists inside build/, where Spotlight
# and Launchpad will not find it and where it is one `rm -rf build` away
# from disappearing. /Applications is where a Mac app lives.
#
# Replacing the bundle in place keeps the code signature and bundle
# identifier identical, which is what TCC keys its grants on — so the
# Screen Recording and Accessibility permissions survive the move.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="ControlMyMac"
BUILT="$ROOT/build/$APP_NAME.app"
INSTALLED="/Applications/$APP_NAME.app"

"$ROOT/scripts/build.sh"

[ -d "$BUILT" ] || { echo "error: nothing was built at $BUILT" >&2; exit 1; }

# A running copy cannot be replaced cleanly, and a half-replaced bundle
# fails signature validation on next launch.
if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
  echo "==> quitting the running copy"
  osascript -e "tell application id \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT/Contents/Info.plist")\" to quit" 2>/dev/null || true
  sleep 2
  pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  sleep 1
fi

echo "==> installing to $INSTALLED"
rm -rf "$INSTALLED"
cp -R "$BUILT" "$INSTALLED"

# LaunchServices caches bundle metadata by path; without this the app
# can keep its old icon or fail to appear in Spotlight for a while.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$INSTALLED" >/dev/null 2>&1 || true

codesign --verify --verbose=1 "$INSTALLED" 2>&1 | sed 's/^/    /'

echo "==> installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED/Contents/Info.plist")"
echo "    Open it from Launchpad, Spotlight, or: open -a ControlMyMac"
echo
echo "    Note: scripts/build.sh only updates build/. Re-run this script"
echo "    to push a new build into /Applications."
