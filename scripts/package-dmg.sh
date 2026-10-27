#!/usr/bin/env bash
# Build MacCode.app and wrap it in a Developer ID-signed DMG.
# This script must fail if a Developer ID Application identity is unavailable.
set -euo pipefail
cd "$(dirname "$0")/.."

ASSET_NAME="${RC2_DMG_NAME:-stable-macos-arm64-RemoteCode.dmg}"
DIST="dist"
APP_NAME="MacCode.app"
DMG_ROOT="$DIST/dmg-root"
DMG_BUILD_ROOT="$DIST/dmg-build"
DMG_BUILD_APP="$DMG_BUILD_ROOT/$APP_NAME"
OUTPUT="$DIST/$ASSET_NAME"
SIGN_IDENTITY="${RC2_CODESIGN_IDENTITY:-}"
BACKGROUND_DIR="$DMG_ROOT/background"
BACKGROUND_IMAGE="$BACKGROUND_DIR/background.png"
RW_DMG="$DIST/RemoteCode-rw.dmg"

if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "[package] RC2_CODESIGN_IDENTITY must be a Developer ID Application identity" >&2
  exit 1
fi

rm -rf "$DMG_BUILD_ROOT"
RC2_PACKAGE_APP_OUTPUT="$DMG_BUILD_APP" "$(dirname "$0")/package-app.sh"

rm -rf "$DMG_ROOT" "$OUTPUT"
mkdir -p "$DMG_ROOT"
mkdir -p "$BACKGROUND_DIR"

cp -R "$DMG_BUILD_APP" "$DMG_ROOT/$APP_NAME"
ln -s /Applications "$DMG_ROOT/Applications"
"$(dirname "$0")/generate-dmg-background.swift" "$BACKGROUND_IMAGE"
chflags hidden "$BACKGROUND_DIR" 2>/dev/null || true

APP_BUNDLE="$DMG_ROOT/$APP_NAME"

# Sign inside-out. Nested Mach-Os under Contents/Resources are NOT re-signed with
# the outer app's --options by `codesign --deep` (Apple TN2206): the outer flags
# do not cascade. RemoteCodeScheduledTaskAgent lived there without hardened
# runtime / secure timestamp, and Apple notarization returned Invalid from
# v2.0.69 onward.
sign_nested_runtime() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    return 0
  fi
  echo "[package] signing with hardened runtime: $path" >&2
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$path"
}

if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
  # Sparkle ships nested apps/XPCs in standard locations; deep is appropriate here.
  codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

sign_nested_runtime "$APP_BUNDLE/Contents/Resources/RemoteCodeScheduledTaskAgent"
sign_nested_runtime "$APP_BUNDLE/Contents/MacOS/RemoteCodeRunAsUserHelper"
sign_nested_runtime "$APP_BUNDLE/Contents/MacOS/rc2"
sign_nested_runtime "$APP_BUNDLE/Contents/MacOS/RemoteCodeDistillService"
sign_nested_runtime "$APP_BUNDLE/Contents/MacOS/RemoteCode"

# Outer bundle last (no --deep: nested code already signed with correct options).
ENTITLEMENTS="$(cd "$(dirname "$0")/.." && pwd)/Sources/AppShell/RemoteCode.entitlements"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"

# Fail closed before DMG creation: nested Mach-Os + outer app must have hardened
# runtime + secure timestamp (notarization requirement for Developer ID).
# Note: do not `find -perm +111` alone — directories are executable and are not
# independent code objects.
assert_runtime_signature() {
  local code_path="$1"
  local meta
  if [[ ! -e "$code_path" ]]; then
    return 0
  fi
  meta="$(codesign -dv --verbose=2 "$code_path" 2>&1 || true)"
  if ! printf '%s\n' "$meta" | grep -Eq 'flags=0x[0-9a-fA-F]*\(runtime\)|flags=.*runtime'; then
    echo "[package] ERROR: missing hardened runtime on $code_path" >&2
    printf '%s\n' "$meta" >&2
    exit 1
  fi
  if ! printf '%s\n' "$meta" | grep -q '^Timestamp='; then
    echo "[package] ERROR: missing secure timestamp on $code_path" >&2
    printf '%s\n' "$meta" >&2
    exit 1
  fi
}

assert_runtime_signature "$APP_BUNDLE"
assert_runtime_signature "$APP_BUNDLE/Contents/Resources/RemoteCodeScheduledTaskAgent"
assert_runtime_signature "$APP_BUNDLE/Contents/MacOS/RemoteCode"
assert_runtime_signature "$APP_BUNDLE/Contents/MacOS/RemoteCodeDistillService"
assert_runtime_signature "$APP_BUNDLE/Contents/MacOS/RemoteCodeRunAsUserHelper"
assert_runtime_signature "$APP_BUNDLE/Contents/MacOS/rc2"
assert_runtime_signature "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
assert_runtime_signature "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate"
assert_runtime_signature "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app"
assert_runtime_signature "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Downloader.xpc"
assert_runtime_signature "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Installer.xpc"

# A volume left mounted by an earlier failed run makes Finder style the wrong
# "MacCode" disk (-10006) and the next create fail; detach strays first.
detach_stale_volumes() {
  local volume
  for volume in /Volumes/MacCode /Volumes/MacCode\ *; do
    [[ -d "$volume" ]] || continue
    echo "[package] detaching stale volume: $volume" >&2
    hdiutil detach "$volume" >/dev/null 2>&1 || hdiutil detach -force "$volume" >/dev/null 2>&1 || true
  done
}

# retry <attempts> <command...>: transient hdiutil/Finder failures on the runner.
retry() {
  local attempts="$1" n=1
  shift
  until "$@"; do
    if (( n >= attempts )); then
      return 1
    fi
    echo "[package] attempt $n failed: $1; retrying" >&2
    detach_stale_volumes
    sleep $(( n * 5 ))
    n=$(( n + 1 ))
  done
}

detach_stale_volumes
rm -f "$RW_DMG"
retry 3 hdiutil create \
  -volname "MacCode" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDRW \
  -fs HFS+ \
  "$RW_DMG"

MOUNT_DIR=""
cleanup_mount() {
  if [[ -n "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup_mount EXIT

ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify "$RW_DMG")"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/Apple_HFS/ { print $NF; exit }')"
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
  echo "[package] unable to find mounted DMG path" >&2
  printf '%s\n' "$ATTACH_OUTPUT" >&2
  exit 1
fi

style_dmg_window() {
osascript <<OSA
tell application "Finder"
  tell disk "MacCode"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set sidebar width of container window to 0
    set bounds of container window to {120, 120, 920, 600}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set background picture of theViewOptions to file "background:background.png"
    set position of item "MacCode.app" of container window to {220, 240}
    set position of item "Applications" of container window to {580, 240}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
}
retry 3 style_dmg_window

sync
hdiutil detach "$MOUNT_DIR"
trap - EXIT

hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT"

codesign --force --sign "$SIGN_IDENTITY" "$OUTPUT"
codesign --verify --verbose=4 "$OUTPUT"

# ---------------------------------------------------------------------------
# Optional local notarization (Apple notary service + staple).
#
# Activate by setting:
#   RC2_NOTARIZE=1
#   RC2_NOTARIZE_PROFILE=<keychain-profile>   # created with:
#       xcrun notarytool store-credentials <profile> \
#           --apple-id <apple-id> \
#           --team-id  <team-id> \
#           --password <app-specific-password>
#
# The default path (RC2_NOTARIZE unset or empty) is completely unchanged.
# ---------------------------------------------------------------------------
if [[ "${RC2_NOTARIZE:-}" == "1" ]]; then
  NOTARIZE_PROFILE="${RC2_NOTARIZE_PROFILE:-}"
  if [[ -z "$NOTARIZE_PROFILE" ]]; then
    echo "[package] RC2_NOTARIZE=1 requires RC2_NOTARIZE_PROFILE to be set" >&2
    exit 1
  fi

  echo "[package] submitting $OUTPUT to Apple notary service (profile: $NOTARIZE_PROFILE)..."
  xcrun notarytool submit "$OUTPUT" \
    --keychain-profile "$NOTARIZE_PROFILE" \
    --wait

  echo "[package] stapling notarization ticket to $OUTPUT..."
  xcrun stapler staple "$OUTPUT"

  xcrun stapler validate "$OUTPUT"
  echo "[package] notarization + staple verified OK"
fi

rm -rf "$DMG_ROOT" "$DMG_BUILD_ROOT" "$RW_DMG"

echo "[package] dmg ready at $OUTPUT"
