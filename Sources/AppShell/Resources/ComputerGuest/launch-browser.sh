#!/bin/bash
set -eu
# --no-sandbox is required inside this unprivileged guest only.
# Do not copy this flag onto the host Chromium.
# CDP stays on the guest loopback (port 9222 is never published) so the
# in-guest Playwright MCP drives this same visible browser and its logins.
# The GPU runs inside the browser process: when the Docker VM runs low on
# memory the kernel kills a separate GPU process, and after three such kills
# Chromium aborts ("GPU process isn't usable") and loses every tab.
# --restore-last-session reopens the tabs after a crash or restart; with the
# RestoreOnStartup policy from the Dockerfile, session cookies persist too.
exec chromium \
    --user-data-dir="${HOME}/.browser-profiles/chromium" \
    --no-first-run \
    --no-default-browser-check \
    --disable-gpu \
    --in-process-gpu \
    --disable-dev-shm-usage \
    --restore-last-session \
    --hide-crash-restore-bubble \
    --no-sandbox \
    --remote-debugging-port=9222 \
    --remote-debugging-address=127.0.0.1
