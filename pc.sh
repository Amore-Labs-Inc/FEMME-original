#!/usr/bin/env bash
# VPS side, installed as ~/.local/bin/pc by bootstrap.sh. Runs a command on the laptop, in this
# same folder, through the laptop's own link: femme-link.service forwards its sshd here as
# ~/.config/herdr/remote/<host>.ssh and ~/.ssh/config "Host pc" dials that socket. The folder's
# sync is flushed before (the laptop builds what was just edited here) and after (results come
# back). Only this waits for the laptop; editing never does.
#
#   pc make -j8           several args: passed as they are
#   pc 'make && ./run'    one arg: a shell line
#   pc                    a shell on the laptop, in this folder
set -u
sock=$(ssh -G pc 2>/dev/null | sed -n 's/^proxycommand nc -U //p')
[ -n "$sock" ] || { echo "pc: no 'Host pc' in ~/.ssh/config: link the laptop (pc-setup.sh) or set PC_HOST in ~/femme/.env, then rerun bootstrap.sh" >&2; exit 255; }
# sshd leaves the socket file behind when the link dies; only a live one accepts a connection.
nc -zU "$sock" 2>/dev/null || { echo "pc: laptop not linked (femme-link down or lid shut)" >&2; exit 255; }

# Each line runs in the laptop's login shell (its own toolchain), from this folder. The mise shims
# are added in case that shell only puts them on PATH when interactive.
esc() { printf '%s' "${1//\'/\'\\\'\'}"; }
here="export PATH=\$HOME/.local/bin:\$HOME/.local/share/mise/shims:\$PATH; cd $(printf '%q' "$PWD") || exit 97"
# The session is the one sync-dir.sh made for this folder or an ancestor (named after the root).
sync='command -v mutagen >/dev/null || exit 98; n() { printf femme-%s "$(printf %s "$1" | cksum | cut -d" " -f1)"; }
d=$PWD; until mutagen sync list "$(n "$d")" >/dev/null 2>&1; do d=${d%/*}; [ -n "$d" ] || exit 97; done; mutagen sync flush "$(n "$d")" || exit 98'
flush() { [ -n "${PC_NOFLUSH:-}" ] || timeout 60 ssh -o BatchMode=yes pc "exec \$SHELL -lc '$(esc "$here; $sync")'"; }
explain() {
  case $1 in
    97) echo "pc: $PWD is not shared from the laptop; there, run: sh sync-dir.sh $PWD (from the FEMME checkout)" >&2 ;;
    98) echo "pc: mutagen on the laptop failed or is missing: is mutagen.service running there? (PC_NOFLUSH=1 skips the flush)" >&2 ;;
    124) echo "pc: the laptop is not answering" >&2 ;;
    255) echo "pc: the link is up but the laptop's sshd did not answer: stale link after sleep (try again in a minute), or pc-setup.sh was never run there" >&2 ;;
  esac
}

flush; rc=$?
# A master connection left from before the laptop slept hangs: drop it and try once more.
[ $rc -ne 124 ] || { timeout 5 ssh -O exit pc 2>/dev/null; rm -f "$(ssh -G pc | sed -n 's/^controlpath //p')"; flush; rc=$?; }
[ $rc -eq 0 ] || { explain $rc; exit $rc; }

case $# in 0) line='exec $SHELL -l' ;; 1) line=$1 ;; *) line=$(printf '%q ' "$@") ;; esac
tty=(); [ -t 0 ] && tty=(-t)
ssh "${tty[@]}" pc "exec \$SHELL -lc '$(esc "$here; $line")'"; rc=$?
[ $rc -ne 255 ] || explain 255
flush >/dev/null 2>&1 || echo "pc: warning: the sync did not flush after the command; the laptop's results may arrive late" >&2
exit $rc
