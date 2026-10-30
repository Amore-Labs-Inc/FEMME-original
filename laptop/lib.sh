# shellcheck shell=bash
# Shared by the laptop-side scripts (sourced, not run). Bash 3.2 safe: macOS ships it.

say() { printf '\033[1m%s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# Portable (GNU and BSD/macOS): rewrite .env with KEY=value replaced or appended.
setenv() {
  [ -f .env ] || touch .env
  awk -v k="$1" -v v="$2" 'BEGIN{FS=OFS="="} $1==k{print k "=" v; f=1; next} {print} END{if(!f) print k "=" v}' .env > .env.tmp \
    && mv .env.tmp .env && chmod 600 .env
}

# ~/.ssh/config "Host <alias>" for the server, between markers so uninstall.sh can take it out again.
# Usage: ssh_config_block <alias> <hostname or ip> <user>
ssh_config_block() {
  mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/config && chmod 600 ~/.ssh/config
  grep -q "^Host $1\$" ~/.ssh/config && return 0
  cat >> ~/.ssh/config <<EOF
# femme $1 start
Host $1
    HostName $2
    User $3
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
# femme $1 end
EOF
}

# y/n question; $2 is the default (y or n).
ask_yes() {
  local a
  read -r -p "$1 [$( [ "$2" = y ] && echo Y/n || echo y/N )] " a
  a=${a:-$2}
  case $a in [Yy]*) return 0 ;; *) return 1 ;; esac
}
