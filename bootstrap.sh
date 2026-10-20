#!/usr/bin/env bash
# Runs on the VPS (sync.sh copies this repo to ~/femme first). Safe to rerun.
set -euo pipefail
cd "$(dirname "$0")"
. ./.env
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

units="herdr-server herdr-notify"
if [ -n "${BOARD_URL:-}" ]; then
  # Caddy terminates HTTPS for the board (automatic certificate for BOARD_URL's host).
  command -v caddy >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq caddy; }
  # encode: the browser terminal polls the screen several times a second; compressed it is ~5x smaller.
  printf '%s {\n\tencode zstd gzip\n\treverse_proxy 127.0.0.1:8787\n}\n' "${BOARD_URL#https://}" | sudo tee /etc/caddy/Caddyfile >/dev/null
  sudo systemctl reload-or-restart caddy
  # Built here, not on the laptop, so a merge to main can deploy itself (deploy.sh).
  [ -x ~/.cargo/bin/cargo ] || curl -fsSL https://sh.rustup.rs | sh -s -- -y -q --profile minimal --no-modify-path
  ~/.cargo/bin/cargo build -q --release --manifest-path board/Cargo.toml
  # Copy then rename: the running binary can't be written over.
  cp board/target/release/femme-board ~/.local/bin/femme-board.new
  mv ~/.local/bin/femme-board.new ~/.local/bin/femme-board
  # cswap: the board's accounts window and femme-cswap's auto-rotation. Its own venv, pinned.
  ~/.local/share/cswap/bin/cswap --version >/dev/null 2>&1 \
    || { python3 -m venv --clear ~/.local/share/cswap && ~/.local/share/cswap/bin/pip install -q claude-swap==0.27.2; }
  ln -sf ~/.local/share/cswap/bin/cswap ~/.local/bin/cswap
  # The box's own login becomes account 1 (fails harmlessly before the first /login).
  cswap list --json | jq -e '.accounts | length > 0' >/dev/null || cswap add || echo "WARN: cswap add failed; log in with claude, then rerun" >&2
  # AWS CLI v2 for the board's AWS sign-in (`aws login --remote`). User-local, no sudo.
  aws --version >/dev/null 2>&1 || { t=$(mktemp -d) && curl -fsSL -o "$t/aws.zip" "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" \
    && unzip -q "$t/aws.zip" -d "$t" && "$t/aws/install" -i ~/.local/share/aws-cli -b ~/.local/bin --update >/dev/null && rm -rf "$t"; }
  units="$units femme-board femme-worker femme-cswap"
fi

mkdir -p ~/.config/systemd/user
for u in $units; do cp "systemd/$u.service" ~/.config/systemd/user/; done
# Only the timer is started here: deploy.sh runs this script, and starting its own service would wait on itself.
[ -z "${BOARD_URL:-}" ] || { cp systemd/femme-deploy.service systemd/femme-deploy.timer ~/.config/systemd/user/; units="$units femme-deploy.timer"; }
systemctl --user daemon-reload
systemctl --user enable --now $units
systemctl --user restart herdr-notify ${BOARD_URL:+femme-board femme-worker femme-cswap}
herdr server reload-config >/dev/null 2>&1 || true
systemctl --user is-active $units
