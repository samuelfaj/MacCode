#!/bin/bash
set -eu
if [ "${REMOTECODE_CONTEXT_NETWORK_POLICY:-}" = "private-egress-v1" ]; then
    marker=/run/remotecode-context-network-ready
    ready=0
    for _ in $(seq 1 30); do
        if [ -f "$marker" ]; then
            ready=1
            break
        fi
        sleep 1
    done
    if [ "$ready" -ne 1 ]; then
        printf '%s\n' 'context network policy gate timed out' >&2
        exit 1
    fi
fi
export DISPLAY="${DISPLAY:-:1}"
export HOME="${HOME:-/home/remotecode}"
: "${REMOTECODE_VIEWER_TOKEN:?RemoteCode viewer token is required}"
mkdir -p "$HOME/.browser-profiles/chromium" /tmp/fluxbox
# The profile lives on the persisted home bind. A recreated container has a new
# hostname, so Chromium reads the previous container's lock as "in use on another
# computer" and never opens. Removing the lock is safe only because no other
# container runs on this home: rebuild and workspace remounts stop the old
# container before the new one starts.
rm -f "$HOME/.browser-profiles/chromium/SingletonLock" \
    "$HOME/.browser-profiles/chromium/SingletonSocket" \
    "$HOME/.browser-profiles/chromium/SingletonCookie"
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 || true

Xvfb :1 -screen 0 1280x800x24 -ac +extension RANDR >/tmp/xvfb.log 2>&1 &
xvfb_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if xdpyinfo -display :1 >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done
xdpyinfo -display :1 >/dev/null

fluxbox -display :1 -log /tmp/fluxbox.log >/tmp/fluxbox.out 2>&1 &
# The browser restarts on its own. It must never be a `wait -n` job: a
# Chromium crash or OOM kill would end the container and SIGKILL the agent
# running inside it (Distill exit 137).
if ! command -v chromium >/dev/null 2>&1; then xterm -display :1 & fi
# A hung browser never exits, so the loop also restarts one whose DevTools
# endpoint stops answering for three checks in a row.
(
    while true; do
        /opt/remotecode-computer/launch-browser.sh &
        browser=$!
        sleep 30
        misses=0
        while kill -0 "$browser" 2>/dev/null; do
            if curl -fsS -m 5 -o /dev/null http://127.0.0.1:9222/json/version; then
                misses=0
            else
                misses=$((misses + 1))
            fi
            if [ "$misses" -ge 3 ]; then
                kill -KILL "$browser" 2>/dev/null || true
            fi
            sleep 10
        done
        wait "$browser" 2>/dev/null || true
        sleep 2
    done
) &

# Guest VNC stays loopback. The WebSocket proxy admits only the per-Bot token;
# Docker NAT additionally publishes 6080 on 127.0.0.1 of the host.
# Shorter poll and update delays than the 20 ms defaults: smoother viewer.
x11vnc -display :1 -rfbport 5900 -localhost -forever -shared -nopw -wait 10 -defer 10 \
    >/tmp/x11vnc.log 2>&1 &
vnc_pid=$!

printf '%s: 127.0.0.1:5900\n' "$REMOTECODE_VIEWER_TOKEN" > /tmp/remotecode-viewer-tokens
chmod 0600 /tmp/remotecode-viewer-tokens
websockify --web /usr/share/novnc \
    --token-plugin TokenFile \
    --token-source /tmp/remotecode-viewer-tokens \
    0.0.0.0:6080 \
    >/tmp/websockify.log 2>&1 &
proxy_pid=$!

# Only the display, VNC and viewer proxy end the container.
while kill -0 "$xvfb_pid" 2>/dev/null && kill -0 "$vnc_pid" 2>/dev/null && kill -0 "$proxy_pid" 2>/dev/null; do
    sleep 2
done
exit 1
