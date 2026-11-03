FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/remotecode \
    DISPLAY=:1 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        xvfb \
        fluxbox \
        x11vnc \
        novnc \
        websockify \
        chromium \
        imagemagick \
        xdotool \
        x11-utils \
        xterm \
        ca-certificates \
        curl \
        xz-utils \
        python3 \
        git \
        procps \
        iptables \
        conntrack \
        wmctrl \
        x11-apps \
    && rm -rf /var/lib/apt/lists/*

# Playwright needs Node >= 20; bookworm ships 18. Pinned official build,
# checked against the SHA-256 published in nodejs.org/dist/v24.21.0/SHASUMS256.txt.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
        arm64) node_arch=arm64; node_sha=6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2 ;; \
        amd64) node_arch=x64; node_sha=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6 ;; \
        *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    tarball="node-v24.21.0-linux-${node_arch}.tar.xz"; \
    curl -fsSLo "/tmp/${tarball}" "https://nodejs.org/dist/v24.21.0/${tarball}"; \
    echo "${node_sha}  /tmp/${tarball}" | sha256sum -c -; \
    tar -xJf "/tmp/${tarball}" -C /usr/local --strip-components=1 --no-same-owner \
        --exclude='*.md' --exclude=LICENSE; \
    rm "/tmp/${tarball}"; \
    node --version

# Pinned. The in-guest agent attaches it to the visible Chromium over CDP
# (launch-browser.sh), so logins made in the viewer are the bot's session.
RUN npm install -g @playwright/mcp@0.0.83 && npm cache clean --force

# Recommended (not mandatory) policies: continue where the user left off, which
# also keeps session cookies across browser restarts, and Memory Saver, which
# frees background tabs instead of letting the guest run out of memory.
RUN mkdir -p /etc/chromium/policies/recommended \
    && printf '%s\n' '{"RestoreOnStartup": 1, "HighEfficiencyModeEnabled": true}' > /etc/chromium/policies/recommended/remotecode.json

RUN useradd --create-home --home-dir /home/remotecode --shell /bin/bash remotecode \
    && mkdir -p /opt/remotecode-computer

COPY start.sh /opt/remotecode-computer/start.sh
COPY context-network.sh /usr/local/bin/rc-context-network
COPY embed.html /opt/remotecode-computer/embed.html
COPY launch-browser.sh /opt/remotecode-computer/launch-browser.sh
RUN chown root:root /usr/local/bin/rc-context-network \
    && chmod 0755 /usr/local/bin/rc-context-network \
    && chmod 0755 /opt/remotecode-computer/start.sh /opt/remotecode-computer/launch-browser.sh

USER remotecode
WORKDIR /home/remotecode
EXPOSE 6080
CMD ["/opt/remotecode-computer/start.sh"]
