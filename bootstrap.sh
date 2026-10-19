#!/usr/bin/env bash
# Runs on the VPS (sync.sh copies this repo to ~/femme first). Safe to rerun.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

# Toolchains + claude/codex/pi/gh from the synced ~/.config/mise/config.toml
command -v mise >/dev/null || curl -fsSL https://mise.run | sh
grep -q 'mise activate' ~/.bashrc || echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
mise install -y || echo "WARN: some mise tools failed, see above" >&2

command -v opencode >/dev/null || [ -x ~/.opencode/bin/opencode ] || curl -fsSL https://opencode.ai/install | bash
command -v codegraph >/dev/null || curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh
# ponytail: whiteboard is a desktop app; the synced Claude hooks call it, so no-op it here.
[ -e ~/.local/bin/whiteboard ] || printf '#!/bin/sh\nexit 0\n' > ~/.local/bin/whiteboard && chmod +x ~/.local/bin/whiteboard

# Same herdr version as the laptop: the laptop's client talks to this server.
want=${HERDR_VERSION:?pass HERDR_VERSION}
mkdir -p ~/.local/bin
[ "$(herdr --version 2>/dev/null)" = "herdr $want" ] || {
  curl -fsSL -o ~/.local/bin/herdr "https://github.com/herdrdev/herdr/releases/download/v$want/herdr-linux-x86_64"
  chmod +x ~/.local/bin/herdr
}
# Non-interactive ssh/mosh (`mosh agentbox -- herdr`) has no ~/.local/bin on PATH.
sudo ln -sf ~/.local/bin/herdr /usr/local/bin/herdr
# Integrations need each agent's config dir, which only appears after its first run.
mkdir -p ~/.codex ~/.pi/agent ~/.config/opencode
for a in claude codex pi opencode; do herdr integration install "$a" || echo "WARN: $a integration failed" >&2; done

grep -q '^\[experimental\]' ~/.config/herdr/config.toml 2>/dev/null \
  || printf '\n[experimental]\n# single-user box: keep screen history across reboots\npane_history = true\n' >> ~/.config/herdr/config.toml

mkdir -p ~/.config/systemd/user
cp systemd/*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now herdr-server herdr-notify
systemctl --user restart herdr-notify
herdr server reload-config >/dev/null 2>&1 || true
systemctl --user is-active herdr-server herdr-notify
