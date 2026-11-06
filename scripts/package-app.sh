#!/usr/bin/env bash
# Package the SwiftPM-built executable as a minimal local .app bundle.
# This is not a release artifact. Release DMGs must be Developer ID signed
# and notarized by scripts/package-dmg.sh (GitHub release workflow), which
# delegates all packaging to this script.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${RC2_CONFIG:-release}"
DIST="dist"
BUNDLE="MacCode.app"
BUNDLE_ID="${RC2_BUNDLE_ID:-io.remotecode.desktop}"
# Derive RC2_CHANNEL_VALUE from BUNDLE_ID so LSEnvironment is always consistent
# with the bundle id — stable=io.remotecode.desktop, canary=io.remotecode.desktop.canary,
# debug=io.remotecode.desktop.debug. RC2_CHANNEL env var always wins if set.
if [ -n "${RC2_CHANNEL:-}" ]; then
  RC2_CHANNEL_VALUE="$RC2_CHANNEL"
elif [ "$BUNDLE_ID" = "io.remotecode.desktop" ]; then
  RC2_CHANNEL_VALUE="stable"
elif [ "$BUNDLE_ID" = "io.remotecode.desktop.canary" ]; then
  RC2_CHANNEL_VALUE="canary"
else
  RC2_CHANNEL_VALUE="debug"
fi
VERSION="${RC2_VERSION:-2.0.37}"
SPARKLE_FEED_URL="${RC2_SPARKLE_FEED_URL:-https://github.com/samuelfaj/MacCode/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${RC2_SPARKLE_PUBLIC_ED_KEY:-}"

running_bundle_pids() {
  local exec_path="$1"
  [ -e "$exec_path" ] || return 0
  local abs_exec
  abs_exec="$(cd "$(dirname "$exec_path")" && pwd -P)/$(basename "$exec_path")"
  ps -axo pid=,command= \
    | awk -v executable="$abs_exec" -f scripts/exact-executable-pids.awk
}

wait_for_bundle_exit() {
  local exec_path="$1"
  local pids
  for _ in {1..20}; do
    pids="$(running_bundle_pids "$exec_path")"
    [ -z "$pids" ] && return 0
    sleep 0.25
  done
  return 1
}

# BEGIN codesign metadata summary parser
# Consume all metadata instead of piping printf into an early-exiting parser.
# Under pipefail, a large `codesign -dv` response otherwise makes printf fail
# with SIGPIPE after awk has found the first matching line.
codesign_metadata_summary() {
  local sign_meta="$1"
  local sign_team=""
  local sign_flags=""
  local line
  local flags

  while IFS= read -r line; do
    case "$line" in
      TeamIdentifier=*)
        if [ -z "$sign_team" ]; then
          sign_team="${line#TeamIdentifier=}"
        fi
        ;;
      *flags=*\(*\)*)
        if [ -z "$sign_flags" ]; then
          flags="${line#*\(}"
          sign_flags="${flags%%\)*}"
        fi
        ;;
    esac
  done <<< "$sign_meta"

  if [[ "$sign_flags" == *adhoc* ]] || [ -z "$sign_team" ] || [ "$sign_team" = "not set" ]; then
    printf '%s\n' 'codesign team=none class=adhoc (TCC grants will not survive rebuilds)'
  else
    printf 'codesign team=%s class=durable flags=%s\n' "$sign_team" "${sign_flags:-none}"
  fi
}
# END codesign metadata summary parser

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
if [ "${RC2_REQUIRE_SPARKLE_KEY:-0}" = "1" ] && [ -z "$SPARKLE_PUBLIC_ED_KEY" ]; then
  echo "[package] RC2_SPARKLE_PUBLIC_ED_KEY is required for release packaging" >&2
  exit 1
fi

# The owner-facing app at dist/MacCode.app must never be a debug build:
# SwiftUI diffing, JSONDecoder and AttributedString(markdown:) run 5-20x
# slower under -Onone, amplifying every transcript/streaming cost (perf audit
# X-00: the running app was a 216 MB debug binary). The isolated sandbox
# packages dist/RemoteCodeDebug.app, which may stay debug.
resolve_path_for_config_guard() {
  local dir
  dir="$(dirname "$1")"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$(basename "$1")"
}
if [ "$CONFIG" != "release" ] \
  && [ "$(resolve_path_for_config_guard "${RC2_PACKAGE_APP_OUTPUT:-$DIST/$BUNDLE}")" \
       = "$(resolve_path_for_config_guard "$DIST/$BUNDLE")" ]; then
  echo "[package] refusing to package a $CONFIG build into the stable app $DIST/$BUNDLE" >&2
  echo "[package] use RC2_CONFIG=release, or package a debug build to a different RC2_PACKAGE_APP_OUTPUT (the sandbox uses dist/RemoteCodeDebug.app)" >&2
  exit 1
fi

# This repo's git config skips LFS smudge, so checkouts can leave Vendor xcframework
# files as LFS pointer stubs. Materialize them from the local LFS store before building.
if command -v git-lfs >/dev/null 2>&1 \
  && git lfs ls-files -n 2>/dev/null | {
       while IFS= read -r p; do
         head -c 64 "$p" 2>/dev/null | grep -q "git-lfs.github.com/spec" && exit 0
       done
       exit 1
     }; then
  echo "[package] materializing LFS pointer files …"
  git lfs fetch
  git lfs checkout
fi

# Native build system, not Swift 6.4's default (swiftbuild).
SWIFT_BUILD_SYSTEM="${RC2_SWIFT_BUILD_SYSTEM:-native}"
BIN_DIR="$(swift build -c "$CONFIG" --build-system "$SWIFT_BUILD_SYSTEM" --show-bin-path)"
echo "[package] building $CONFIG …"
swift build -c "$CONFIG" --build-system "$SWIFT_BUILD_SYSTEM"

BIN="$BIN_DIR/RemoteCode"
SCHEDULED_TASK_AGENT="$BIN_DIR/RemoteCodeScheduledTaskAgent"
CLI="$BIN_DIR/rc2"
DISTILL_SERVICE="$BIN_DIR/RemoteCodeDistillService"
RUN_AS_USER_HELPER="$BIN_DIR/RemoteCodeRunAsUserHelper"
if [ ! -x "$BIN" ]; then echo "missing $BIN"; exit 1; fi
if [ ! -x "$SCHEDULED_TASK_AGENT" ]; then echo "missing $SCHEDULED_TASK_AGENT"; exit 1; fi
if [ ! -x "$CLI" ]; then echo "missing $CLI"; exit 1; fi
if [ ! -x "$DISTILL_SERVICE" ]; then echo "missing $DISTILL_SERVICE"; exit 1; fi
if [ ! -x "$RUN_AS_USER_HELPER" ]; then echo "missing $RUN_AS_USER_HELPER"; exit 1; fi
DATABASE_SCHEMA_VERSION="$("$BIN" --database-schema-version)"
if ! [[ "$DATABASE_SCHEMA_VERSION" =~ ^[0-9]+$ ]]; then
  echo "[package] invalid database schema version: $DATABASE_SCHEMA_VERSION" >&2
  exit 1
fi

APP_PATH="${RC2_PACKAGE_APP_OUTPUT:-$DIST/$BUNDLE}"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/RemoteCode"
RUNNING_PIDS="$(running_bundle_pids "$APP_EXECUTABLE")"
if [ -n "$RUNNING_PIDS" ]; then
  if [ "${RC2_REPLACE_RUNNING_APP:-0}" != "1" ]; then
    echo "[package] refusing to replace running $APP_PATH" >&2
    echo "[package] running pid(s): $(echo "$RUNNING_PIDS" | tr '\n' ' ')" >&2
    echo "[package] set RC2_REPLACE_RUNNING_APP=1 only when the caller intentionally relaunches the dev app" >&2
    exit 1
  fi
  echo "[package] stopping running $APP_PATH before replacing it"
  /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  if ! wait_for_bundle_exit "$APP_EXECUTABLE"; then
    RUNNING_PIDS="$(running_bundle_pids "$APP_EXECUTABLE")"
    for pid in $RUNNING_PIDS; do
      kill "$pid" 2>/dev/null || true
    done
  fi
  if ! wait_for_bundle_exit "$APP_EXECUTABLE"; then
    RUNNING_PIDS="$(running_bundle_pids "$APP_EXECUTABLE")"
    echo "[package] running pid(s) did not exit: $(echo "$RUNNING_PIDS" | tr '\n' ' ')" >&2
    exit 1
  fi
fi

APP_PARENT="$(dirname "$APP_PATH")"
APP_BASENAME="$(basename "$APP_PATH" .app)"
STAGING_ROOT="$APP_PARENT/.staging"
STAGING_APP="$STAGING_ROOT/${APP_BASENAME}-$$.app"
cleanup_staging() {
  rm -rf "$STAGING_APP"
}
trap cleanup_staging EXIT

rm -rf "$STAGING_APP"
mkdir -p "$STAGING_APP/Contents/MacOS"
mkdir -p "$STAGING_APP/Contents/Resources"
mkdir -p "$STAGING_APP/Contents/Frameworks"
mkdir -p "$STAGING_APP/Contents/Library/LaunchAgents"

cp "$BIN" "$STAGING_APP/Contents/MacOS/RemoteCode"
cp "$SCHEDULED_TASK_AGENT" "$STAGING_APP/Contents/Resources/RemoteCodeScheduledTaskAgent"
cp "$DISTILL_SERVICE" "$STAGING_APP/Contents/MacOS/RemoteCodeDistillService"
# Privileged trampoline for shared-helper agent execution. Not setuid in the
# bundle; install to /Library/PrivilegedHelperTools with root ownership for use.
cp "$RUN_AS_USER_HELPER" "$STAGING_APP/Contents/MacOS/RemoteCodeRunAsUserHelper"
cp "$CLI" "$STAGING_APP/Contents/MacOS/rc2"
# Canonical location only. Do NOT copy resource bundles to the .app root:
# codesign rejects that as "unsealed contents present in the bundle root".
# SPM's generated Bundle.module looks at the app root and fatalErrors — never
# call Bundle.module from app code; use AppShellResourceBundle /
# AgentRuntimeResourceBundle instead.
# Copy EVERY first-party resource bundle so a new resource-bearing target can
# never ship without its resources again (v2.0.85–v2.0.87 launch-crash class:
# RemoteCode_AgentRuntime.bundle was missing from this hand-maintained list).
for resource_bundle in "$BIN_DIR"/RemoteCode_*.bundle; do
  [ -d "$resource_bundle" ] || continue
  case "$(basename "$resource_bundle")" in
    *Tests.bundle) continue ;;
  esac
  cp -R "$resource_bundle" "$STAGING_APP/Contents/Resources/$(basename "$resource_bundle")"
done
if [ ! -d "$STAGING_APP/Contents/Resources/RemoteCode_AppShell.bundle" ]; then
  echo "missing $BIN_DIR/RemoteCode_AppShell.bundle" >&2
  exit 1
fi
if [ ! -d "$STAGING_APP/Contents/Resources/RemoteCode_AgentRuntime.bundle" ]; then
  echo "missing $BIN_DIR/RemoteCode_AgentRuntime.bundle" >&2
  exit 1
fi
# Claude Agent SDK Node bridge: must ship inside the .app. The adapter resolves
# this at runtime from Contents/Resources — never via compile-time #filePath
# (that baked CI runner paths into release builds and broke customers).
CLAUDE_SDK_BRIDGE="Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs"
if [ ! -f "$CLAUDE_SDK_BRIDGE" ]; then
  echo "missing $CLAUDE_SDK_BRIDGE" >&2
  exit 1
fi
cp "$CLAUDE_SDK_BRIDGE" "$STAGING_APP/Contents/Resources/ClaudeAgentSDKBridge.mjs"
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$STAGING_APP/Contents/Resources/AppIcon.icns"
fi
SPARKLE_FRAMEWORK="$(find "$BIN_DIR" -maxdepth 2 -name Sparkle.framework -type d | head -n 1 || true)"
if [ -n "$SPARKLE_FRAMEWORK" ]; then
  cp -R "$SPARKLE_FRAMEWORK" "$STAGING_APP/Contents/Frameworks/Sparkle.framework"
  if ! otool -l "$STAGING_APP/Contents/MacOS/RemoteCode" | grep -F "@executable_path/../Frameworks" >/dev/null; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$STAGING_APP/Contents/MacOS/RemoteCode"
  fi
fi

cat > "$STAGING_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>MacCode</string>
  <key>CFBundleExecutable</key><string>RemoteCode</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>MacCode</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>RC2DatabaseSchemaVersion</key><integer>${DATABASE_SCHEMA_VERSION}</integer>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.folder</string>
      </array>
    </dict>
  </array>
  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><false/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSNetworkVolumesUsageDescription</key>
  <string>MacCode needs access to project folders on network volumes so agents, terminals, and file tools can read and edit your code.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>MacCode needs access to project folders on removable volumes so agents, terminals, and file tools can read and edit your code.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>MacCode needs access to folders on your Desktop when you open them as workspaces.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>MacCode needs access to folders in Documents when you open them as workspaces.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>MacCode needs access to folders in Downloads when you open them as workspaces.</string>
  <key>LSEnvironment</key>
  <dict>
    <key>RC2_CHANNEL</key><string>${RC2_CHANNEL_VALUE}</string>
  </dict>
</dict>
</plist>
EOF

SCHEDULED_TASK_SERVICE="${BUNDLE_ID}.scheduled-tasks"
SCHEDULED_TASK_PLIST="$STAGING_APP/Contents/Library/LaunchAgents/${SCHEDULED_TASK_SERVICE}.plist"
cat > "$SCHEDULED_TASK_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${SCHEDULED_TASK_SERVICE}</string>
  <key>BundleProgram</key><string>Contents/Resources/RemoteCodeScheduledTaskAgent</string>
  <key>ProgramArguments</key>
  <array>
    <string>RemoteCodeScheduledTaskAgent</string>
    <string>--scheduled-task-agent</string>
  </array>
  <key>MachServices</key>
  <dict><key>${SCHEDULED_TASK_SERVICE}</key><true/></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key>
  <dict>
    <key>RC2_CHANNEL</key><string>${RC2_CHANNEL_VALUE}</string>
    <key>RC2_SCHEDULED_TASK_AGENT</key><string>1</string>
    <key>RC2_DISABLE_MANAGED_DISTILL_RECONCILE</key><string>1</string>
  </dict>
</dict>
</plist>
EOF
plutil -lint "$SCHEDULED_TASK_PLIST" >/dev/null

# PkgInfo must be exactly the 8 bytes "APPL????" with NO trailing newline; a
# heredoc/echo adds one (9 bytes), which some bundle validators reject (QA-mac :70).
printf 'APPL????' > "$STAGING_APP/Contents/PkgInfo"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$STAGING_APP" || true
fi

# Fail closed on resource layout before signing. Catches the Bundle.module /
# Contents/Resources launch-crash class (pet atlas missing from either path).
CHECK_APP_BUNDLE="$(cd "$(dirname "$0")" && pwd)/check-app-bundle.sh"
if [ ! -x "$CHECK_APP_BUNDLE" ]; then
  chmod +x "$CHECK_APP_BUNDLE" 2>/dev/null || true
fi
if [ ! -x "$CHECK_APP_BUNDLE" ]; then
  echo "missing executable $CHECK_APP_BUNDLE" >&2
  exit 1
fi
"$CHECK_APP_BUNDLE" "$STAGING_APP"

# Prefer a stable Apple Development identity so macOS TCC "Allow" grants for
# Network Volumes / Desktop / Documents / Downloads survive rebuilds.
# Ad-hoc (`-`) re-binds TCC to a new CDHash whenever the app payload changes.
# Resolution rules live in resolve-codesign-identity.sh (unit-tested):
#   - RC2_CODESIGN_IDENTITY set → use it (`-` forces ad-hoc)
#   - else unique "Apple Development: …" CN → auto-pick
#   - else ad-hoc with a loud warning
# Release DMGs re-sign with Developer ID in package-dmg.sh regardless.
CODESIGN_RESOLVER="$(cd "$(dirname "$0")" && pwd)/resolve-codesign-identity.sh"
if [ ! -x "$CODESIGN_RESOLVER" ]; then
  chmod +x "$CODESIGN_RESOLVER" 2>/dev/null || true
fi
CODESIGN_IDENTITY="$("$CODESIGN_RESOLVER")"
ENTITLEMENTS="$(cd "$(dirname "$0")/.." && pwd)/Sources/AppShell/RemoteCode.entitlements"
if [ ! -f "$ENTITLEMENTS" ]; then
  echo "[package] missing $ENTITLEMENTS" >&2
  exit 1
fi
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  echo "[package] WARNING: signing ad-hoc. Network volume / folder TCC prompts can return after every rebuild." >&2
  echo "[package] Fix: export RC2_CODESIGN_IDENTITY=\"Apple Development: Your Name (TEAMID)\"  # or install one unique Apple Development cert" >&2
  codesign --force --sign - --timestamp=none "$STAGING_APP/Contents/Resources/RemoteCodeScheduledTaskAgent"
  codesign --force --deep --sign - --timestamp=none "$STAGING_APP"
else
  echo "[package] signing with durable identity: $CODESIGN_IDENTITY" >&2
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp=none "$STAGING_APP/Contents/Resources/RemoteCodeScheduledTaskAgent"
  codesign --force --deep --sign "$CODESIGN_IDENTITY" --timestamp=none "$STAGING_APP"
fi
# Re-sign the outer app (no --deep) so entitlements attach
# without rewriting Sparkle/helper signatures.
codesign --force --sign "$CODESIGN_IDENTITY" --entitlements "$ENTITLEMENTS" --timestamp=none "$STAGING_APP"
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"
# Surface identity summary so a packaging log proves TCC durability class.
if command -v codesign >/dev/null 2>&1; then
  SIGN_META="$(codesign -dv --verbose=4 "$STAGING_APP" 2>&1 || true)"
  printf '[package] %s\n' "$(codesign_metadata_summary "$SIGN_META")" >&2
fi

rm -rf "$APP_PATH"
mkdir -p "$APP_PARENT"
mv "$STAGING_APP" "$APP_PATH"
trap - EXIT

echo "[package] bundle ready at $APP_PATH"
echo "[package] launch: open '$APP_PATH'  or  $APP_PATH/Contents/MacOS/RemoteCode"
echo "[package] release DMGs require Developer ID signing and notarization"
