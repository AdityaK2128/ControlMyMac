#!/bin/bash
# Builds ControlMyMac.app — the Mac app and the headless agent are the
# same binary, so there is one bundle, one identity, one set of
# permissions to grant.
#
# The bundle is not cosmetic. A bare executable run from Terminal gets
# its TCC decisions attributed to Terminal; a signed bundle with a stable
# identifier gets its own Screen Recording grant that survives rebuilds.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

# The CommandLineTools SwiftPM shipped with this macOS beta is broken:
# its libPackageDescription.dylib is missing symbols its own
# .swiftinterface advertises, so manifests fail to link. Route through
# Xcode's toolchain instead. DEVELOPER_DIR avoids needing sudo
# xcode-select and keeps the choice local to this build.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$candidate/Contents/Developer" ]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi
[ -n "${DEVELOPER_DIR:-}" ] || { echo "error: need a full Xcode install (CommandLineTools SwiftPM is broken)" >&2; exit 1; }
echo "==> toolchain: $DEVELOPER_DIR"


# Signing identity comes from scripts/local.env when present, so a
# public checkout carries nobody's Apple account details. See
# scripts/local.env.example.
if [ -f "$ROOT/scripts/local.env" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/scripts/local.env"
fi

# TCC keys its grants on the bundle identifier, so whatever you pick,
# keep it: renaming silently throws away the Screen Recording and
# Accessibility permissions already granted.
BUNDLE_ID="${CONTROLMYMAC_BUNDLE_ID:-com.example.controlmymac.agent}"
APP_NAME="ControlMyMac"
PRODUCT="ControlMyMacAgent"
VERSION="0.3.0"
APP="$ROOT/build/$APP_NAME.app"
CONFIG="${CONFIG:-release}"

# Signing with a real Development cert (rather than ad-hoc) means TCC
# keys the grant on team + bundle id, so it survives recompiles.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep 'Apple Development' | head -1 | sed -E 's/.*"(.*)"/\1/')}"

if [ -z "$IDENTITY" ]; then
  echo "warning: no Apple Development identity found, falling back to ad-hoc." >&2
  echo "         TCC will re-prompt on every rebuild, and Open at Login will refuse." >&2
  IDENTITY="-"
fi

# Build everything, not just the app: a stale test harness is worse than
# a slow build.
#
# Note the deliberate absence of a comment inside the command
# substitution below. A `#` in there swallows the closing paren, the
# script dies mid-pipeline, and you spend an afternoon testing a stale
# bundle. It has happened.
echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$PRODUCT"
[ -x "$BIN" ] || { echo "error: no binary at $BIN" >&2; exit 1; }

if [ ! -f "$ROOT/build/AppIcon.icns" ]; then
  echo "==> drawing the app icon"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/build" >/dev/null
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>ControlMyMac</string>
    <key>CFBundleDisplayName</key><string>ControlMyMac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- A regular app: it has a window worth looking at. The Dock icon
         can be hidden from Settings, which flips the activation policy
         at runtime instead of here. -->
    <key>LSUIElement</key><false/>
    <key>NSHumanReadableCopyright</key><string>ControlMyMac</string>
</dict>
</plist>
PLIST

echo "==> codesign ($IDENTITY)"
codesign --force --sign "$IDENTITY" \
         --identifier "$BUNDLE_ID" \
         --options runtime \
         --timestamp=none \
         "$APP" 2>&1 | sed 's/^/    /'

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> built $APP ($VERSION)"
