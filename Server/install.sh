#!/usr/bin/env bash
# Installs the XTermX node on a Linux server, as your own user (no root needed except to
# install Docker or enable lingering), and starts it with systemd.
#
#   git clone git@github.com:cassel/xtermx-core.git && cd xtermx-core && ./Server/install.sh
#
# Options (environment):
#   XTERMX_ADDRESSES="100.64.0.7 example.com"   addresses to put in the QR, best first
#   XTERMX_FLAGS="--allow-agent-panes"          extra flags for `xtermx serve`
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
package="$repo/Packages/XTermXKit"
bin_dir="$HOME/.local/bin"
unit_dir="$HOME/.config/systemd/user"
mkdir -p "$bin_dir" "$unit_dir"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# 1. Build: natively when Swift 6.2+ is installed, otherwise inside the official Swift image.
if command -v swift >/dev/null 2>&1 && swift --version 2>/dev/null | grep -qE 'Swift version 6\.([2-9]|[1-9][0-9])'; then
    say "Building with $(swift --version 2>/dev/null | head -1)"
    (cd "$package" && swift build -c release --product xtermx --static-swift-stdlib)
    cp "$package/.build/release/xtermx" "$bin_dir/xtermx"
elif command -v docker >/dev/null 2>&1; then
    say "Building inside the swift:6.3-noble Docker image (first run downloads it)"
    docker run --rm -v "$package":/src:ro -v xtermx-build:/build -v "$bin_dir":/out swift:6.3-noble bash -c '
        set -e; mkdir -p /work && cd /src && tar --exclude=./.build -cf - . | (cd /work && tar xf -)
        cd /work && swift build -c release --product xtermx --static-swift-stdlib --scratch-path /build
        cp /build/release/xtermx /out/xtermx && chown '"$(id -u):$(id -g)"' /out/xtermx'
else
    echo "Install Swift 6.2+ (https://swift.org/install) or Docker, then run this again." >&2
    exit 1
fi
chmod 755 "$bin_dir/xtermx"
if ! "$bin_dir/xtermx" --version >/dev/null 2>&1; then
    echo "xtermx needs libcurl and libstdc++: sudo apt-get install -y libcurl4t64 (or libcurl4) libstdc++6" >&2
    exit 1
fi
say "Installed $bin_dir/xtermx ($("$bin_dir/xtermx" --version))"

# 2. Service: runs as you, so agents in its terminals use your home, keys and logins.
addresses=""
for a in ${XTERMX_ADDRESSES:-}; do addresses="$addresses --address $a"; done
sed -e "s|@BIN@|$bin_dir/xtermx|" -e "s|@ARGS@|${addresses} ${XTERMX_FLAGS:-}|" \
    "$repo/Server/xtermx.service" > "$unit_dir/xtermx.service"

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user daemon-reload
    systemctl --user enable --now xtermx.service
    # Keep it running after you log out.
    if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q yes; then
        say "Enabling lingering so XTermX keeps running when you log out (sudo)"
        sudo loginctl enable-linger "$USER" || echo "Could not enable lingering; XTermX stops when you log out."
    fi
    say "XTermX is running: systemctl --user status xtermx"
else
    say "No systemd user session here. Start it yourself: $bin_dir/xtermx serve${addresses}"
fi

# 3. Pairing code.
say "Pair your iPhone (scan) or another machine (xtermx add '…' / Mac › Machines › Add machine):"
# shellcheck disable=SC2086
"$bin_dir/xtermx" pair $addresses
cat <<'EOF'

Network: with Tailscale on this server, nothing has to be opened to the internet.
To use a public address instead, allow TCP 47820 (and 47821 for the Apple Watch) in the firewall.
EOF
