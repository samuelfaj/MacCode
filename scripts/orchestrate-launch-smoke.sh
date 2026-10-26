#!/usr/bin/env bash
# Launch a packaged MacCode.app once and verify AppContext.init completes
# without aborting and the orchestrate reconcile logs no failure. Catches
# launch-abort regressions (EXC_BREAKPOINT class, e.g. the v2.0.85-v2.0.87
# Bundle.module crash) that structural file checks cannot see.
#
# NOTE: on the machine that built the binary, SPM .build fallback paths exist,
# so this smoke proves the launch invariant (never abort), not packaged-path
# resolution order — that is pinned by AgentRuntimeResourceBundleTests.
#
# Usage: orchestrate-launch-smoke.sh /path/to/MacCode.app
set -euo pipefail

APP="${1:?usage: orchestrate-launch-smoke.sh /path/to/MacCode.app}"
EXE_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist" 2>/dev/null || echo RemoteCode)"
EXE="$APP/Contents/MacOS/$EXE_NAME"
[ -x "$EXE" ] || { echo "[smoke] missing executable $EXE" >&2; exit 1; }

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rc2-launch-smoke.XXXXXX")"
LOG="$SMOKE_ROOT/app.log"
PID=""
cleanup() {
  if [ -n "$PID" ]; then
    pkill -TERM -P "$PID" 2>/dev/null || true
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT

RC2_APP_SUPPORT="$SMOKE_ROOT/app-support" \
  RC2_DB_PATH="$SMOKE_ROOT/app-support/RemoteCode.sqlite" \
  nohup "$EXE" > "$LOG" 2>&1 < /dev/null &
PID=$!

for _ in $(seq 1 45); do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "[smoke] FAIL: app exited during launch (launch-abort class)" >&2
    tail -40 "$LOG" >&2 || true
    exit 1
  fi
  # Post-AppContext.init marker: the direct HTTP server starts after init.
  if grep -q "Direct HTTP server listening" "$LOG" 2>/dev/null; then
    if grep -qi "orchestrate package reconcile failed" "$LOG"; then
      echo "[smoke] FAIL: orchestrate reconcile failed at launch" >&2
      grep -i "orchestrate" "$LOG" >&2 || true
      exit 1
    fi
    echo "[smoke] OK: AppContext.init completed (pid $PID), no orchestrate reconcile failure"
    exit 0
  fi
  sleep 1
done

echo "[smoke] FAIL: app did not finish init within 45s" >&2
tail -40 "$LOG" >&2 || true
exit 1
