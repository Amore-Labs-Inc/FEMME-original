#!/usr/bin/env bash
# Laptop side, once (Arch/Omarchy): lets `pc` on the VPS run commands here, in a synced folder
# (README: Work on PC files from the VPS). sshd listens on 127.0.0.1 only; the VPS reaches it
# through the link this machine opens (femme-link.service), so nothing is exposed to the
# network. Safe to rerun.
set -euo pipefail
cd "$(dirname "$0")"
. ./.env

command -v mutagen >/dev/null && systemctl --user is-enabled -q mutagen \
  || { echo "pc-setup: install mutagen and enable mutagen.service first (README, Laptop)" >&2; exit 1; }

sudo pacman -S --needed --noconfirm openssh
grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config \
  || sudo sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
printf 'ListenAddress 127.0.0.1\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nAllowUsers %s\n' "$(id -un)" \
  | sudo tee /etc/ssh/sshd_config.d/femme.conf >/dev/null
sudo sshd -t
sudo systemctl enable --now sshd
sudo systemctl reload sshd

# The VPS's own key (bootstrap.sh makes it) may log in here.
key=$(ssh "$HOST" cat .ssh/id_ed25519.pub) || { echo "pc-setup: the VPS has no key yet: ./sync.sh first" >&2; exit 1; }
mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
grep -qxF "$key" ~/.ssh/authorized_keys || echo "$key" >> ~/.ssh/authorized_keys

# The link now also forwards this sshd; the VPS names "Host pc" after the linked laptop.
mkdir -p ~/.config/systemd/user
cp systemd/femme-link.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now femme-link
systemctl --user restart femme-link
ssh "$HOST" 'grep -q "^Host pc$" ~/.ssh/config 2>/dev/null' \
  || ssh "$HOST" "cd femme && HERDR_VERSION=$(herdr --version | cut -d' ' -f2) ./bootstrap.sh" >/dev/null

echo "pc-setup: checking from the VPS..."
for _ in 1 2 3 4 5 6; do
  ssh "$HOST" ssh -o BatchMode=yes pc true 2>/dev/null && { echo "pc-setup: ok, pc works on the VPS"; exit 0; }
  sleep 5
done
echo "pc-setup: the VPS could not reach this machine; there, try: ssh -v pc true" >&2
exit 1
