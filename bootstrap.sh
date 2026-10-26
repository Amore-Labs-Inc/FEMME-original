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
# Every Claude here runs as `claude --dangerously-skip-permissions` (same mode, no dialog): nobody is
# at the keyboard to answer prompts. sync.sh copies the laptop's settings over this file first.
mkdir -p ~/.claude; f=~/.claude/settings.json; [ -s $f ] || echo {} > $f
jq '.permissions.defaultMode = "bypassPermissions" | .skipDangerousModePermissionPrompt = true' $f > $f.tmp && mv $f.tmp $f

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

# Linked laptops (systemd/femme-link.service) forward their herdr socket into ~/.config/herdr/remote
# for the board. sshd replaces a stale socket on reconnect and drops a dead link (lid shut) in ~45 s.
mkdir -p ~/.config/herdr/remote
# Instinct's terminals run in a herdr session of their own (systemd/herdr-instinct.service), so a
# laptop can list them as a machine tab of their own; the board lists them the same way as a
# laptop's, tagged instinct, through this link.
ln -sfn ~/.config/herdr/sessions/instinct/herdr.sock ~/.config/herdr/remote/instinct.sock
printf 'StreamLocalBindUnlink yes\nClientAliveInterval 15\nClientAliveCountMax 3\n' | sudo tee /etc/ssh/sshd_config.d/20-femme-link.conf >/dev/null
if sudo sshd -t; then sudo systemctl reload ssh; else sudo rm -f /etc/ssh/sshd_config.d/20-femme-link.conf; fi

# `pc` (pc.sh): agents here build and test on the laptop, in the same synced folder, over that
# same link (it also forwards the laptop's sshd as <hostname>.ssh; pc-setup.sh on the laptop).
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519 -C femme-vps
pc_host=${PC_HOST:-$(find ~/.config/herdr/remote -maxdepth 1 -type s -name '*.sock' -printf '%f\n' 2>/dev/null | sed 's/\.sock$//')}
case $pc_host in
  '') echo "NOTE: no linked laptop yet, so no 'Host pc': run pc-setup.sh on it (or set PC_HOST in .env)" >&2 ;;
  *$'\n'*) echo "WARN: several laptops are linked: set PC_HOST in .env to the one pc should use" >&2 ;;
  *) { [ -f ~/.ssh/config ] && sed '/^# femme pc start$/,/^# femme pc end$/d' ~/.ssh/config
       printf '# femme pc start\nHost pc\n  ProxyCommand nc -U %s/.config/herdr/remote/%s.ssh\n  User %s\n  IdentityFile ~/.ssh/id_ed25519\n  IdentitiesOnly yes\n  ControlMaster auto\n  ControlPath ~/.ssh/cm-pc\n  ControlPersist 10m\n  ServerAliveInterval 15\n  ServerAliveCountMax 2\n  ConnectTimeout 5\n  StrictHostKeyChecking accept-new\n# femme pc end\n' "$HOME" "$pc_host" "$(id -un)"
     } > ~/.ssh/config.new && mv ~/.ssh/config.new ~/.ssh/config && chmod 600 ~/.ssh/config ;;
esac
install -m755 pc.sh ~/.local/bin/pc
# The same rule for every agent: Claude reads ~/.claude/rules, Codex its global ~/.codex/AGENTS.md.
mkdir -p ~/.claude/rules && cp rules/pc.md ~/.claude/rules/femme-pc.md
{ [ -f ~/.codex/AGENTS.md ] && sed '/^<!-- femme pc start -->$/,/^<!-- femme pc end -->$/d' ~/.codex/AGENTS.md
  printf '<!-- femme pc start -->\n'; cat rules/pc.md; printf '<!-- femme pc end -->\n'
} > ~/.codex/AGENTS.new && mv ~/.codex/AGENTS.new ~/.codex/AGENTS.md

units="herdr-server herdr-instinct herdr-notify"
if [ -n "${BOARD_URL:-}" ]; then
  # Caddy terminates HTTPS for the board (automatic certificate for BOARD_URL's host).
  command -v caddy >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq caddy; }
  # encode: the browser terminal polls the screen several times a second; compressed it is ~5x smaller.
  # timeouts: the board takes one request at a time, so a client trickling a body may hold it 60 s, not forever.
  # max_size: a 20 MB upload, base64'd. Headers: HSTS; no Referer, the magic link's token is in its URL.
  sudo tee /etc/caddy/Caddyfile >/dev/null <<EOF
{
	servers {
		timeouts {
			read_header 10s
			read_body 60s
		}
	}
}
${BOARD_URL#https://} {
	encode zstd gzip
	request_body {
		max_size 30MB
	}
	header {
		Strict-Transport-Security "max-age=31536000"
		Referrer-Policy no-referrer
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
	}
	reverse_proxy 127.0.0.1:8787
}
EOF
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
# The plugin runs from this checkout (deploy.sh keeps it at main). sync.sh just copied the laptop's
# plugins.json over ours, which points femme at the laptop's checkout path: relink when it differs.
if [ "$(herdr plugin list --json 2>/dev/null | jq -r '.result.plugins[] | select(.plugin_id == "femme") | .plugin_root')" != "$PWD" ]; then
  herdr plugin unlink femme >/dev/null 2>&1 || true
  herdr plugin link "$PWD" >/dev/null || echo "WARN: could not link the femme plugin from $PWD" >&2
fi
systemctl --user restart herdr-notify ${BOARD_URL:+femme-board femme-worker femme-cswap}
herdr server reload-config >/dev/null 2>&1 || true
systemctl --user is-active $units
