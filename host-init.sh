#!/usr/bin/env bash
# Prepare an existing Ubuntu 24.04 server that provision.sh did not make (any VPS, a home server):
# what cloud-init.yaml does on AWS, over ssh. Your user (same name as here, so paths match), key-only
# SSH, mosh, 8 GB swap, linger; then a "Host $HOST" entry in ~/.ssh/config. Safe to rerun.
#
# Usage: ./host-init.sh <admin>@<server>    an account there that can sudo, e.g. root@203.0.113.7
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || cp .env.example .env
. ./.env
. ./lib.sh
admin=${1:?usage: ./host-init.sh <admin>@<server>}
server=${admin#*@}
pub=~/.ssh/id_ed25519.pub
[ -f "$pub" ] || die "no $pub: make one with ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519"

say "checking $server"
ssh -o ConnectTimeout=10 "$admin" 'grep -q "^VERSION_ID=\"24.04\"" /etc/os-release && case $(uname -m) in x86_64|aarch64) ;; *) exit 1 ;; esac' \
  || die "$server must run Ubuntu 24.04 on x86_64 or arm64 (aarch64)"

say "preparing $server for user $USER"
# The script goes over stdin; user, key and host name as arguments.
ssh "$admin" sudo bash -s -- "$USER" "$(cat "$pub")" "$HOST" <<'REMOTE'
set -euo pipefail
user=$1 key=$2 host=$3
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq mosh jq git rsync build-essential curl unzip >/dev/null
id "$user" >/dev/null 2>&1 || useradd -m -s /bin/bash "$user"
echo "$user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-femme && chmod 440 /etc/sudoers.d/90-femme
home=$(getent passwd "$user" | cut -d: -f6)
install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
touch "$home/.ssh/authorized_keys"
grep -qxF "$key" "$home/.ssh/authorized_keys" || echo "$key" >> "$home/.ssh/authorized_keys"
chown "$user:$user" "$home/.ssh/authorized_keys" && chmod 600 "$home/.ssh/authorized_keys"
if ! swapon --show | grep -q .; then
  fallocate -l 8G /swapfile && chmod 600 /swapfile && mkswap -q /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
loginctl enable-linger "$user"
[ "$(hostname)" = "$host" ] || hostnamectl set-hostname "$host"
# Key-only, no root: only after the user's key is in place, so this never locks you out.
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/10-femme.conf
sshd -t && systemctl reload ssh
REMOTE

ssh_config_block "$HOST" "$server" "$USER"
setenv IP "$server"
ssh -o BatchMode=yes "$HOST" true || die "could not log in as $USER@$server with your key; root login is now off, so use: ssh $USER@$server"
say "$HOST is ready. Next: ./sync.sh"
