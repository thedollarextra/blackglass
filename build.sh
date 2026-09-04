#!/bin/bash
# Builds BlackGlass.app from the Swift package.
#   ./build.sh            release build -> ./BlackGlass.app
#   ./build.sh debug      debug build
set -euo pipefail

cd "$(dirname "$0")"

APP="BlackGlass.app"
CONFIG="${1:-release}"
FINISHED="${FINISHED_APPS_DIR:-}"

# Build outside the source tree. This project lives in iCloud Drive, and letting
# SwiftPM keep intermediates in ./.build there makes every compile fight the
# sync daemon. Override with SCRATCH_PATH.
SCRATCH="${SCRATCH_PATH:-${TMPDIR:-/tmp}/LiquidNotes-build}"

echo "==> Compiling ($CONFIG) in ${SCRATCH}..."
swift build -c "$CONFIG" --disable-sandbox --scratch-path "$SCRATCH"

BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)/LiquidNotes"
if [ ! -x "$BIN" ]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

# Assemble and sign on local disk, never in place. iCloud's file provider stamps
# FinderInfo onto the bundle and codesign rejects that detritus.
STAGE="$SCRATCH/stage/$APP"

echo "==> Assembling ${APP}..."
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/LiquidNotes"
chmod +x "$STAGE/Contents/MacOS/LiquidNotes"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"

BUILD_NUMBER="$(date +%Y%m%d%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
  "$STAGE/Contents/Info.plist" 2>/dev/null || true

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
fi
mkdir -p "$STAGE/Contents/Resources/Web"
cp -R Sources/LiquidNotes/Web/. "$STAGE/Contents/Resources/Web/"
BIN_DIR="$(dirname "$BIN")"
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$STAGE/Contents/Resources/"
done
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
xattr -cr "$STAGE"

echo "==> Signing (ad-hoc)..."
codesign --force --sign - --timestamp=none "$STAGE"
codesign --verify --deep --strict "$STAGE"

echo "==> Installing to $(pwd)/${APP}..."
rm -rf "$APP"
ditto --noextattr --norsrc "$STAGE" "$APP"

if [ -d "$FINISHED" ]; then
  echo "==> Copying to ${FINISHED}/${APP}..."
  rm -rf "$FINISHED/$APP"
  ditto --noextattr --norsrc "$STAGE" "$FINISHED/$APP"
fi

NEW_HASH="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F'=' '/^CDHash=/{print $2}')"
echo "==> Done: $(pwd)/$APP"
echo "    cdhash: ${NEW_HASH:-unknown}"
echo "    Run with: open \"$APP\""
