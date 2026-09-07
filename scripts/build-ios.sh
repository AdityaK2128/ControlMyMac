#!/bin/bash
# Builds the iOS client for the simulator and assembles the .app.
#
# Deliberately does not use an Xcode project: the sources are compiled
# directly, with ControlMyMacKit built into the app target rather than
# linked as a separate module. ControlMyMac.xcodeproj exists alongside
# this for interactive development and device builds.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

if [ -z "${DEVELOPER_DIR:-}" ]; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    [ -d "$candidate/Contents/Developer" ] && export DEVELOPER_DIR="$candidate/Contents/Developer" && break
  done
fi
[ -n "${DEVELOPER_DIR:-}" ] || { echo "error: need a full Xcode install" >&2; exit 1; }

# Signing identity comes from scripts/local.env when present, so a
# public checkout carries nobody's Apple account details. See
# scripts/local.env.example.
if [ -f "$ROOT/scripts/local.env" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/scripts/local.env"
fi

BUNDLE_ID="${CONTROLMYMAC_IOS_BUNDLE_ID:-com.example.controlmymac.ios}"
APP_NAME="ControlMyMac"
APP="$ROOT/build/ios/$APP_NAME.app"
DEPLOYMENT_TARGET="17.0"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"   # arm64 on Apple Silicon hosts

echo "==> compiling for iphonesimulator ($ARCH)"
rm -rf "$APP"
mkdir -p "$APP"

xcrun -sdk iphonesimulator swiftc \
  -target "${ARCH}-apple-ios${DEPLOYMENT_TARGET}-simulator" \
  -sdk "$SDK" \
  -O \
  ControlMyMaciOS/*.swift Sources/ControlMyMacKit/*.swift \
  -o "$APP/$APP_NAME"

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>ControlMyMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>MinimumOSVersion</key><string>$DEPLOYMENT_TARGET</string>
    <key>UIDeviceFamily</key><array><integer>1</integer></array>
    <key>UILaunchScreen</key><dict/>
    <key>UIApplicationSceneManifest</key>
    <dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <!-- Tailnet addresses live in CGNAT space, which iOS treats as
         local network. Without this the first connection is refused. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>ControlMyMac connects to your Mac over your Tailscale network to show its screen.</string>
    <!-- Add-only: screenshots go in, nothing is ever read back out. -->
    <key>NSPhotoLibraryAddUsageDescription</key>
    <string>ControlMyMac saves screenshots of your Mac's screen to your photo library.</string>
    <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
    <key>DTPlatformName</key><string>iphonesimulator</string>
</dict>
</plist>
PLIST

# Simulator builds still need a signature, ad-hoc is enough.
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'

echo "==> built $APP"
