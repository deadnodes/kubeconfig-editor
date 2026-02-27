#!/usr/bin/env bash
set -euo pipefail

APP_NAME="KubeconfigEditor"
BUNDLE_ID="dev.weiss.kubeconfig-editor"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
VERSION_FILE="$ROOT_DIR/VERSION"
if [[ -n "${APP_VERSION:-}" ]]; then
  VERSION="$APP_VERSION"
elif [[ -f "$VERSION_FILE" ]]; then
  VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
else
  echo "VERSION file not found: $VERSION_FILE" >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  echo "Version is empty. Set APP_VERSION or provide VERSION file." >&2
  exit 1
fi

SWIFT_BUILD_PATH="${SWIFT_BUILD_PATH:-$ROOT_DIR/.build-local}"
CLANG_MODULE_CACHE_DIR="${CLANG_MODULE_CACHE_PATH:-$SWIFT_BUILD_PATH/clang-module-cache}"
BUILD_DIR="$SWIFT_BUILD_PATH/release"
DIST_DIR="$ROOT_DIR/dist"
ASSETS_DIR="$ROOT_DIR/assets"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
DMG_STAGING_DIR="$DIST_DIR/dmg-staging"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
ICON_PNG_PATH="$ASSETS_DIR/icon.png"
ICON_ICNS_SOURCE_PATH="$ASSETS_DIR/AppIcon.icns"
DMG_BACKGROUND_PNG_PATH="$ASSETS_DIR/dmg-background.png"
DMG_WINDOW_WIDTH="${DMG_WINDOW_WIDTH:-860}"
DMG_WINDOW_HEIGHT="${DMG_WINDOW_HEIGHT:-560}"
DMG_BG_WIDTH="${DMG_BG_WIDTH:-820}"
DMG_BG_HEIGHT="${DMG_BG_HEIGHT:-500}"
DMG_ICON_SIZE="${DMG_ICON_SIZE:-72}"
DMG_TEXT_SIZE="${DMG_TEXT_SIZE:-10}"
DMG_APP_X="${DMG_APP_X:-233}"
DMG_APP_Y="${DMG_APP_Y:-222}"
DMG_APPS_X="${DMG_APPS_X:-582}"
DMG_APPS_Y="${DMG_APPS_Y:-222}"
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
ICON_ICNS_PATH="$RESOURCES_DIR/AppIcon.icns"
RW_DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-temp.dmg"

rm -rf "$APP_DIR" "$DMG_PATH" "$ICONSET_DIR" "$DMG_STAGING_DIR" "$RW_DMG_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "==> Building release binary"
cd "$ROOT_DIR"
mkdir -p "$SWIFT_BUILD_PATH" "$CLANG_MODULE_CACHE_DIR"
CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_DIR" \
SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_DIR" \
swift build --build-path "$SWIFT_BUILD_PATH" -c release

if [[ ! -f "$BUILD_DIR/$APP_NAME" ]]; then
  echo "Release binary not found: $BUILD_DIR/$APP_NAME" >&2
  exit 1
fi

cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

ICON_PLIST_ENTRY=""
if [[ -f "$ICON_ICNS_SOURCE_PATH" ]]; then
  echo "==> Using prebuilt icon: $ICON_ICNS_SOURCE_PATH"
  cp "$ICON_ICNS_SOURCE_PATH" "$ICON_ICNS_PATH"
  ICON_PLIST_ENTRY=$'  <key>CFBundleIconFile</key>\n  <string>AppIcon.icns</string>'
elif [[ -f "$ICON_PNG_PATH" ]]; then
  echo "==> Generating app icon from $ICON_PNG_PATH"
  mkdir -p "$ICONSET_DIR"

  sips -z 16 16 "$ICON_PNG_PATH" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_PNG_PATH" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_PNG_PATH" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_PNG_PATH" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_PNG_PATH" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_PNG_PATH" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_PNG_PATH" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_PNG_PATH" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_PNG_PATH" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_PNG_PATH" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS_PATH"
  ICON_PLIST_ENTRY=$'  <key>CFBundleIconFile</key>\n  <string>AppIcon.icns</string>'
else
  echo "==> No icon source found (expected $ICON_ICNS_SOURCE_PATH or $ICON_PNG_PATH), app icon generation skipped"
fi

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
${ICON_PLIST_ENTRY}
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if [[ -n "${APPLE_DEV_ID:-}" ]]; then
  echo "==> Signing app with identity: $APPLE_DEV_ID"
  codesign --deep --force --verify --verbose --sign "$APPLE_DEV_ID" "$APP_DIR"
else
  echo "==> APPLE_DEV_ID is not set, skipping codesign (Gatekeeper may block app on other Macs)"
fi

echo "==> Creating DMG"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_DIR" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
if [[ -f "$DMG_BACKGROUND_PNG_PATH" ]]; then
  mkdir -p "$DMG_STAGING_DIR/.background"
  sips -z "$DMG_BG_HEIGHT" "$DMG_BG_WIDTH" "$DMG_BACKGROUND_PNG_PATH" \
    --out "$DMG_STAGING_DIR/.background/background.png" >/dev/null
  chflags hidden "$DMG_STAGING_DIR/.background" || true
  echo "==> Using DMG background: $DMG_BACKGROUND_PNG_PATH (${DMG_BG_WIDTH}x${DMG_BG_HEIGHT})"
else
  echo "==> No DMG background found at $DMG_BACKGROUND_PNG_PATH (skip pretty background)"
fi

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -fs HFS+ \
  -ov -format UDRW \
  "$RW_DMG_PATH"

ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG_PATH")"
DEVICE="$(echo "$ATTACH_OUTPUT" | awk '/\/Volumes\// {print $1; exit}')"
MOUNT_POINT="$(echo "$ATTACH_OUTPUT" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
if [[ -z "$MOUNT_POINT" ]]; then
  MOUNT_POINT="/Volumes/$APP_NAME"
fi
VOLUME_NAME="$(basename "$MOUNT_POINT")"

if [[ -n "$DEVICE" ]] && command -v osascript >/dev/null 2>&1; then
  HAS_DMG_BG="false"
  if [[ -f "$DMG_BACKGROUND_PNG_PATH" ]]; then
    HAS_DMG_BG="true"
  fi
  OSA_OUT="$(
    osascript - \
      "$VOLUME_NAME" "$MOUNT_POINT" "$APP_NAME" "$HAS_DMG_BG" \
      "$DMG_WINDOW_WIDTH" "$DMG_WINDOW_HEIGHT" \
      "$DMG_ICON_SIZE" "$DMG_TEXT_SIZE" \
      "$DMG_APP_X" "$DMG_APP_Y" "$DMG_APPS_X" "$DMG_APPS_Y" <<'OSA' 2>&1
on run argv
try
  set volumeName to item 1 of argv
  set mountPoint to item 2 of argv
  set appName to item 3 of argv
  set hasBg to item 4 of argv
  set windowWidth to item 5 of argv as integer
  set windowHeight to item 6 of argv as integer
  set iconSize to item 7 of argv as integer
  set textSize to item 8 of argv as integer
  set appX to item 9 of argv as integer
  set appY to item 10 of argv as integer
  set appsX to item 11 of argv as integer
  set appsY to item 12 of argv as integer
  set leftEdge to 100
  set topEdge to 100
  set rightEdge to leftEdge + windowWidth
  set bottomEdge to topEdge + windowHeight

  tell application "Finder"
    tell disk volumeName
      open
      delay 1
      set theWindow to container window
      set current view of theWindow to icon view
      set bounds of theWindow to {leftEdge, topEdge, rightEdge, bottomEdge}
      set opts to the icon view options of theWindow
      set arrangement of opts to not arranged
      set icon size of opts to iconSize
      set text size of opts to textSize
      set label position of opts to bottom
      if hasBg is "true" then
        try
          set bgAlias to (POSIX file (mountPoint & "/.background/background.png")) as alias
          set background picture of opts to bgAlias
        on error
          set background picture of opts to file ".background:background.png"
        end try
      end if
      set position of item (appName & ".app") of theWindow to {appX, appY}
      set position of item "Applications" of theWindow to {appsX, appsY}
      try
        set position of item ".background" of theWindow to {1000, 1000}
      end try
      try
        set position of item ".fseventsd" of theWindow to {1000, 1120}
      end try
      close
      delay 1
      close
    end tell
  end tell
on error errMsg number errNum
  error ("Finder layout failed (" & errNum & "): " & errMsg)
end try
end run
OSA
  )" || {
    echo "==> Warning: Finder layout customization failed"
    echo "$OSA_OUT"
  }
fi

if mount | grep -q " on $MOUNT_POINT "; then
  chflags hidden "$MOUNT_POINT/.background" >/dev/null 2>&1 || true
  chflags hidden "$MOUNT_POINT/.fseventsd" >/dev/null 2>&1 || true
fi

sync
if [[ -n "$DEVICE" ]]; then
  hdiutil detach "$DEVICE" -force >/dev/null || true
elif mount | grep -q " on $MOUNT_POINT "; then
  hdiutil detach "$MOUNT_POINT" -force >/dev/null || true
fi
sleep 1

for dev in $(hdiutil info | awk -v p="$RW_DMG_PATH" '
  $1=="image-path" { inblk = index($0, p) > 0; next }
  inblk && $1 ~ "^/dev/" { print $1 }
'); do
  hdiutil detach "$dev" -force >/dev/null 2>&1 || true
done
sleep 1

hdiutil convert "$RW_DMG_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$RW_DMG_PATH"

if [[ -n "${APPLE_DEV_ID:-}" ]]; then
  echo "==> Signing DMG"
  codesign --force --verify --verbose --sign "$APPLE_DEV_ID" "$DMG_PATH"
fi

if [[ -n "${APPLE_DEV_ID:-}" && -n "$NOTARY_PROFILE" ]]; then
  echo "==> Notarizing DMG with profile: $NOTARY_PROFILE"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler staple "$APP_DIR" || true
fi

echo "==> Done"
echo "App: $APP_DIR"
echo "DMG: $DMG_PATH"
