#!/usr/bin/env bash
# One entry point, run on the laptop from this checkout. Asks a few questions, writes .env, sets up the
# server and checks the result. What it cannot do for you (sign-ins, DNS) it lists at the end.
#
#   ./install.sh           first install, or again to change answers (it keeps what .env already has)
#   ./install.sh update    pull this checkout, push it to the server, check
set -euo pipefail
cd "$(dirname "$0")"
. ./laptop/lib.sh

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
ask() {  # KEY "question" [secret]: keeps the current value on Enter
  local cur=${!1:-} v
  if [ "${3:-}" = secret ]; then
    read -r -s -p "$2 [${cur:+keep current}]: " v; echo
  else
    read -r -p "$2 [${cur}]: " v
  fi
  v=${v:-$cur}
  setenv "$1" "$v"; eval "$1=\$v"
}
flag() {  # KEY "question": 1 or 0
  local d=n; [ "${!1:-0}" = 1 ] && d=y
  if ask_yes "$2" $d; then setenv "$1" 1; eval "$1=1"; else setenv "$1" 0; eval "$1=0"; fi
}

echo "Where will FEMME run?"
echo "  1) a new AWS instance (needs the AWS CLI signed in; it costs money)"
echo "  2) an Ubuntu 24.04 server you already have (any VPS or a home server, reachable over ssh)"
echo "  3) this machine (Linux only; agents stop when it sleeps)"
read -r -p "1, 2 or 3: " where
case $where in 1|2|3) ;; *) die "pick 1, 2 or 3" ;; esac
if [ "$where" = 3 ]; then
  [ "$(uname -s)" = Linux ] || die "this machine as the server needs Linux with systemd"
  setenv HOST localhost; HOST=localhost
else
  ask HOST "Short name for the server (ssh alias)"
fi
[ -z "${HERDR_VERSION:-}" ] && ! command -v herdr >/dev/null && ask HERDR_VERSION "herdr version for the server (see https://herdr.dev, e.g. 0.9.0)"
[ -n "${NTFY_TOPIC:-}" ] || setenv NTFY_TOPIC "femme-$(openssl rand -hex 16)"

if ask_yes "Use the board (web panel, issue queue, API for other agents)?" y; then
  ask BOARD_EMAIL "Email address(es) allowed to sign in, comma-separated"
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
[ "$where" != 1 ] || flag_aws=1
if [ "${flag_aws:-}" = 1 ]; then
  if ask_yes "May agents on the server launch small AWS instances (AWS_ROLE=spawn)?" n; then setenv AWS_ROLE spawn; else setenv AWS_ROLE none; fi
fi
. ./.env

say "3/5 the server"
case $where in
  1)
    command -v aws >/dev/null || die "install the AWS CLI and sign in (aws configure, or aws login), then rerun"
    ./laptop/provision.sh
    say "waiting for the first boot to finish"
    for _ in $(seq 30); do ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$HOST" true 2>/dev/null && break; sleep 10; done
    ssh "$HOST" cloud-init status --wait >/dev/null
    ;;
  2)
    read -r -p "An account on the server that can sudo, as user@address (e.g. root@203.0.113.7): " admin
    ./laptop/host-init.sh "$admin"
    ;;
  3)
    ssh -o BatchMode=yes localhost true 2>/dev/null \
      || die "ssh localhost must work with your key: install openssh-server, then: cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys"
    ;;
esac

say "4/5 installing on $HOST (a few minutes the first time)"
./laptop/sync.sh

say "5/5 checking"
./doctor.sh || true

cat <<EOF

What is left for you (FEMME never copies your credentials):
  1. Sign in on the server:  ssh $HOST
       claude                      then /login and follow the link
       gh auth login && gh auth setup-git
       codex login --device-auth   (only if you use Codex)
     Then ./doctor.sh again.
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
  4. Optional: notifications on your phone, the ntfy app subscribed to the NTFY_TOPIC in .env (docs/notifications.md).
     To hand FEMME tasks from a chat bot (e.g. Instinct on WhatsApp), see docs/api.md.
EOF
