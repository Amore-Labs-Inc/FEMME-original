#!/usr/bin/env bash
# Laptop side, once (Linux with systemd, or macOS): the server as a herdr machine, this checkout as
# the femme plugin with its two keys, and the background services: Mutagen (folder sync) and
# femme-link (this laptop's terminals on the board). Needs herdr; Mutagen is optional. Safe to rerun.
set -euo pipefail
cd "$(dirname "$0")"
. ./.env
. ./lib.sh
command -v herdr >/dev/null || die "laptop-setup: install herdr first (https://herdr.dev); without it, the board and the API still work"

say "herdr: $HOST as a machine, femme as a plugin"
herdr machine add "$HOST" --label "$HOST" --remote-session default >/dev/null 2>&1 || true
herdr plugin link "$PWD" >/dev/null 2>&1 || true
cfg=~/.config/herdr/config.toml
mkdir -p "${cfg%/*}"
grep -q 'femme.fork-remote' "$cfg" 2>/dev/null || cat >> "$cfg" <<'EOF'

# femme: fork the focused agent to the server; open the drop box beside a server agent
[[keys.command]]
key = "prefix+shift+v"
type = "plugin_action"
command = "femme.fork-remote"
description = "fork agent to VPS"

[[keys.command]]
key = "prefix+u"
type = "plugin_action"
command = "femme.files"
description = "drop box: files into the agent's folder"
EOF
herdr server reload-config >/dev/null 2>&1 || true

case $(uname -s) in
  Linux)
    command -v systemctl >/dev/null || die "laptop-setup: Linux without systemd is not supported"
    mkdir -p ~/.config/systemd/user
    units=femme-link
    if command -v mutagen >/dev/null; then units="mutagen $units"; else warn "no mutagen: forking agents and folder sync stay off"; fi
    for u in $units; do cp "systemd/$u.service" ~/.config/systemd/user/; done
    # The unit dials "agentbox": point it at your alias.
    sed -i "s/ agentbox\$/ $HOST/" ~/.config/systemd/user/femme-link.service
    systemctl --user daemon-reload
    systemctl --user enable --now $units
    ;;
  Darwin)
    # Mutagen keeps its own daemon in launchd.
    if command -v mutagen >/dev/null; then mutagen daemon register && mutagen daemon start || true
    else warn "no mutagen: forking agents and folder sync stay off"; fi
    # femme-link as a launchd agent: the same ssh as systemd/femme-link.service. The server maps /Users to
    # /home (bootstrap.sh), so this laptop's paths work there.
    name=$(hostname -s)
    plist=~/Library/LaunchAgents/dev.femme.link.plist
    mkdir -p ~/Library/LaunchAgents
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.femme.link</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ssh</string><string>-N</string>
    <string>-o</string><string>ControlMaster=no</string>
    <string>-o</string><string>ControlPath=none</string>
    <string>-o</string><string>ExitOnForwardFailure=yes</string>
    <string>-o</string><string>ServerAliveInterval=15</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>-R</string><string>$HOME/.config/herdr/remote/$name.sock:$HOME/.config/herdr/herdr.sock</string>
    <string>-R</string><string>$HOME/.config/herdr/remote/$name.ssh:127.0.0.1:22</string>
    <string>$HOST</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/femme-link.log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/dev.femme.link" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    [ -S ~/.config/herdr/herdr.sock ] || warn "no herdr socket at ~/.config/herdr/herdr.sock yet: start herdr; the link retries every 10 s"
    ;;
  *) die "laptop-setup: $(uname -s) is not supported" ;;
esac
say "laptop ready: in herdr, prefix+shift+v forks the focused agent to $HOST"
