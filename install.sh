#!/usr/bin/env bash
# One entry point, run on the laptop from this checkout. Asks a few questions, writes .env, sets up the
# server and checks the result. What it cannot do for you (sign-ins, DNS) it lists at the end.
#
#   ./install.sh           first install, or again to change answers (it keeps what .env already has)
#   ./install.sh update    pull this checkout, push it to the server, check
set -euo pipefail
cd "$(dirname "$0")"
. ./laptop/lib.sh
trap 'printf "\033[?25h" >&2' EXIT  # the menu hides the cursor; never leave it hidden

if [ "${1:-}" = update ]; then
  [ -f .env ] || die "no .env: run ./install.sh first"
  git pull --ff-only
  ./laptop/sync.sh
  ./doctor.sh
  exit
fi

say "1/5 what this laptop needs"
missing=
for t in ssh rsync jq git curl; do command -v $t >/dev/null || missing="$missing $t"; done
[ -z "$missing" ] || die "install first:$missing"
rsync_ok || die "rsync is too old (macOS ships openrsync): $(rsync_fix)"
[ -f ~/.ssh/id_ed25519 ] || {
  ask_yes "No ~/.ssh/id_ed25519. Make one now (no passphrase: the sync service has no ssh-agent)?" y || die "an ed25519 key is needed"
  ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519
}
command -v herdr >/dev/null || warn "herdr is not installed here: the server gets it anyway; install it (https://herdr.dev) to fork agents from this laptop"

say "2/5 settings (.env, readable only by you)"
[ -f .env ] || cp .env.example .env
chmod 600 .env
. ./.env
ask() {  # KEY "question" [secret] [check]: keeps the current value on Enter; asks again until check passes
  local cur=${!1:-} v
  while :; do
    if [ "${3:-}" = secret ]; then
      read -r -s -p "$2 [${cur:+keep current}]: " v; echo
    else
      read -r -p "$2 [${cur}]: " v
    fi
    v=${v:-$cur}
    [ -z "${4:-}" ] || "$4" "$v" || continue
    break
  done
  setenv "$1" "$v"; eval "$1=\$v"
}
flag() {  # KEY "question": 1 or 0
  local d=n; [ "${!1:-0}" = 1 ] && d=y
  if ask_yes "$2" $d; then setenv "$1" 1; eval "$1=1"; else setenv "$1" 0; eval "$1=0"; fi
}
# Checks for ask: print why and fail, so ask asks again.
is_alias() { case $1 in ''|*[!A-Za-z0-9._-]*) warn "  letters, digits, dot, dash or underscore only"; return 1 ;; esac; }
is_emails() {  # comma-separated; also catches keyboard escapes (Option+Q for @ on some layouts)
  local e rest=$1,
  [ -n "$1" ] || { warn "  at least one address"; return 1; }
  while [ -n "$rest" ]; do
    e=${rest%%,*}; rest=${rest#*,}; e=$(printf '%s' "$e" | tr -d ' ')
    printf '%s' "$e" | grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' \
      || { warn "  \"$e\" is not an email address"; return 1; }
  done
}
is_admin() {  # user@address, and this laptop's key logs in there
  case $1 in *@?*) ;; *) warn "  as user@address, e.g. ubuntu@203.0.113.7"; return 1 ;; esac
  case ${1#*@} in 203.0.113.*) warn "  that is the example address: use your server's"; return 1 ;; esac
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$1" true 2>/dev/null && return
  # Many VPSs start with a password: put the key there once, so every later step logs in without one.
  warn "  ~/.ssh/id_ed25519 does not log in to $1 yet; if it takes a password, enter it once to add the key"
  ssh-copy-id -i ~/.ssh/id_ed25519.pub -o ConnectTimeout=10 "$1" >/dev/null 2>&1 </dev/tty \
    && ssh -o BatchMode=yes -o ConnectTimeout=10 "$1" true 2>/dev/null && return
  warn "  could not log in to $1 over ssh: check the address and the account"
  return 1
}

choose where "Where will FEMME run?  (↑/↓, Enter)" \
  "A new AWS instance (AWS CLI signed in; costs money)" \
  "An Ubuntu 24.04 server you have (a VPS, a home server)" \
  "This machine (Linux only; stops when it sleeps)"
if [ "$where" = 3 ]; then
  [ "$(uname -s)" = Linux ] || die "this machine as the server needs Linux with systemd"
  setenv HOST localhost; HOST=localhost
else
  ask HOST "Short name for the server (ssh alias)" "" is_alias
fi
if [ "$where" = 2 ]; then
  [ -n "${ADMIN:-}" ] || [ -z "${IP:-}" ] || ADMIN=root@$IP
  ask ADMIN "An account on the server that can sudo, as user@address" "" is_admin
fi
if [ -z "${HERDR_VERSION:-}" ] && ! command -v herdr >/dev/null; then
  v=$(curl -fsSL https://api.github.com/repos/herdrdev/herdr/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')
  if [ -n "$v" ]; then setenv HERDR_VERSION "$v"; HERDR_VERSION=$v
  else ask HERDR_VERSION "herdr version for the server (see https://herdr.dev, e.g. 0.9.5)"; fi
fi
[ -n "${NTFY_TOPIC:-}" ] || setenv NTFY_TOPIC "femme-$(openssl rand -hex 16)"

if ask_yes "Use the board (web panel, issue queue, API for other agents)?" y; then
  [ -n "${BOARD_EMAIL:-}" ] || BOARD_EMAIL=$(git config user.email 2>/dev/null || true)
  ask BOARD_EMAIL "Email address(es) allowed to sign in, comma-separated" "" is_emails
  flag BOARD_PUBLIC "Must another machine reach the board over the internet (for example a chat bot calling the API)?"
  if [ "$BOARD_PUBLIC" = 1 ]; then
    ask BOARD_URL "Board address, https://<your domain>"
    case $BOARD_URL in https://*) ;; *) die "BOARD_URL must start with https:// when the board is public" ;; esac
    ask RESEND_API_KEY "Resend API key for sign-in emails (empty: links go to the server log)" secret
    [ -z "${RESEND_API_KEY:-}" ] || ask MAIL_FROM 'Sender, quoted, e.g. "FEMME <hello@example.com>"'
  else
    setenv BOARD_URL http://localhost:8787; BOARD_URL=http://localhost:8787
  fi
  flag ACCOUNT_ROTATION "Switch between several stored Claude accounts by usage? (Your provider's terms apply.)"
else
  setenv BOARD_URL ""; setenv BOARD_PUBLIC 0; setenv ACCOUNT_ROTATION 0
fi
flag AUTODEPLOY "Should the server update itself when main changes on GitHub? (Anyone who can merge can then run code on it.)"
[ "$where" = 3 ] || flag MOSH "A terminal on your phone too (Moshi or Blink, over mosh)?"
if [ "$where" = 1 ]; then
  if ask_yes "May agents on the server launch small AWS instances (AWS_ROLE=spawn)?" n; then setenv AWS_ROLE spawn; else setenv AWS_ROLE none; fi
fi
. ./.env

onoff() { [ "${1:-0}" = 1 ] && echo on || echo off; }
case $where in
  1) server="new AWS instance, $INSTANCE_TYPE in $REGION" ;;
  2) server=$ADMIN ;;
  3) server="this machine" ;;
esac
printf '\n\033[1mAbout to set up\033[0m\n' >&2
printf '  %-14s %s\n' server "$server" "ssh alias" "$HOST" herdr "${HERDR_VERSION:-same as this laptop}" \
  board "$( [ -n "${BOARD_URL:-}" ] && echo "$BOARD_URL, sign-in for $BOARD_EMAIL" || echo off)" \
  "auto-deploy" "$(onoff "${AUTODEPLOY:-}")" mosh "$(onoff "${MOSH:-}")" >&2
[ "$where" != 1 ] || printf '  %-14s %s\n' "AWS role" "${AWS_ROLE:-none}" >&2
ask_yes "Go ahead?" y || die "Nothing was changed on a server. Your answers are kept in .env: run ./install.sh again to change them."

LOG=${TMPDIR:-/tmp}/femme-install-$(date +%Y%m%d-%H%M%S).log
: > "$LOG"; chmod 600 "$LOG"
say "3/5 the server"
case $where in
  1)
    command -v aws >/dev/null || die "install the AWS CLI and sign in (aws configure, or aws login), then rerun"
    step "creating the AWS instance" ./laptop/provision.sh
    wait_boot() {
      for _ in $(seq 30); do ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$HOST" true 2>/dev/null && break; sleep 10; done
      ssh "$HOST" cloud-init status --wait
    }
    step "waiting for the first boot to finish" wait_boot
    ;;
  2)
    step "preparing $ADMIN (user, key-only ssh, swap, packages)" ./laptop/host-init.sh "$ADMIN"
    ;;
  3)
    ssh -o BatchMode=yes localhost true 2>/dev/null \
      || die "ssh localhost must work with your key: install openssh-server, then: cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys"
    ;;
esac

say "4/5 installing on $HOST"
step "herdr, the agents, the board and the services (a few minutes the first time)" ./laptop/sync.sh

say "5/5 checking"
./doctor.sh || true

cat <<EOF

What is left for you (FEMME never copies your credentials):
  1. Sign in on the server:  ssh $HOST
       claude                      then /login and follow the link
       gh auth login && gh auth setup-git
       codex login --device-auth   (only if you use Codex)
     Then, back here: ./install.sh update   (sets up the board's accounts window now that Claude is signed in)
EOF
[ -z "${BOARD_URL:-}" ] || if [ "${BOARD_PUBLIC:-0}" = 1 ]; then cat <<EOF
  2. Point a DNS A record for ${BOARD_URL#https://} at ${IP:-the server address} (DNS only, no proxy),
     open ports 80 and 443 if your provider has a firewall, then ./laptop/sync.sh once more for the certificate.
EOF
else cat <<EOF
  2. Open the board: ssh -N -L 8787:127.0.0.1:8787 $HOST, then http://localhost:8787.
     Without Resend, the sign-in link is in: ssh $HOST journalctl --user -u femme-board -n 20
EOF
fi
cat <<EOF
  3. This laptop (forking agents, drop box, its terminals on the board): ./laptop/laptop-setup.sh
  4. Optional: notifications on your phone, the ntfy app subscribed to the NTFY_TOPIC in .env; a terminal
     on the phone with MOSH=1 (both in docs/notifications.md).
     To hand FEMME tasks from a chat bot (e.g. Instinct on WhatsApp), see docs/api.md.
The full install log: $LOG
EOF
