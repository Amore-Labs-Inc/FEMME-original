#!/usr/bin/env bash
# The drop box: the folder's files, newest first, and a place to drag files from the laptop to.
# A drop pastes the file's laptop path here as text. The copy runs through the laptop's own herdr
# (femme-link.service forwards its socket here): a workspace on the laptop, out of focus, runs
# rsync to this box and is closed once its shell is idle again. A path that already exists here
# (herdr copies a dropped image to /tmp/herdr-clipboard-images-<uid> and pastes that path) is
# moved or copied in. q closes the box.
#
# Usage: FEMME_DIR=<folder> files-pane.sh    This box, as the laptop's ssh knows it: $FEMME_HOST (agentbox)
set -u
dir=${FEMME_DIR:?FEMME_DIR: the folder to show}
cd "$dir" || exit 1
host=${FEMME_HOST:-agentbox}
herdr=${HERDR_BIN_PATH:-herdr}
st=$(mktemp -d)                      # one file per transfer: "run|ok|err <name>[: <why>]"
spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); tick=0

trap 'exit' HUP TERM
if [ -t 0 ]; then
  saved=$(stty -g)
  trap 'stty "$saved"; printf "\033[?7h\033[?25h\033[?1049l"; rm -rf "$st"' EXIT
  stty -echo -icanon min 1           # a drop has no newline: take bytes as they come, and quietly
  # Alternate screen: nothing the box draws reaches the scrollback. No auto-wrap: a line wider than
  # the pane is clipped, never scrolls.
  printf '\033[?1049h\033[?25l\033[?7l\033]0;Files · drop box\007'
else
  trap 'rm -rf "$st"' EXIT
fi

# A drop lands in the focused pane, so the box must be it: when it is not, the listing dims and the
# footer turns into a yellow "click here first" bar; focused, the footer is green.
focused() { [ -z "${HERDR_PANE_ID:-}" ] || "$herdr" pane list 2>/dev/null | jq -e --arg p "$HERDR_PANE_ID" '.result.panes[] | select(.pane_id == $p) | .focused' >/dev/null; }

render() {
  local rows cols n f state rest now dim=
  read -r rows cols < <(stty size 2>/dev/null || echo 24 80)
  n=$((rows - 4)); [ "$n" -gt 0 ] || n=1
  if focused; then f1='● drop a file from the laptop here'; f2=' · q closes'; c1=$'\033[1;32m'; c2=$'\033[2m'
  else dim=$'\033[2m'; f1=' click here first '; f2=' a drop lands in the focused pane'; c1=$'\033[30;43m'; c2=$'\033[33m'; fi
  foot=$f1$f2; foot=${foot:0:cols-1}   # a footer wider than the pane wraps and scrolls: one header line into scrollback per redraw
  foot=$c1${foot:0:${#f1}}$'\033[0m'$c2${foot:${#f1}}$'\033[0m'
  printf '\033[H\033[2J\033[1m%s\033[0m\n%s' "${dir/#$HOME/\~}" "$dim"
  # Newest first, so what just landed is the top line.
  find . -mindepth 1 -maxdepth 1 -printf '%T@\t%TH:%TM\t%s\t%y\t%P\n' | sort -rn | head -n "$n" \
    | awk -F'\t' -v w="$cols" '{ s = $3; u = " "; if (s >= 1024) { s /= 1024; u = "K" } if (s >= 1024) { s /= 1024; u = "M" } if (s >= 1024) { s /= 1024; u = "G" }
        printf "%s %4.0f%s %s%s\n", $2, s, u, substr($5, 1, w - 12), ($4 == "d" ? "/" : "") }'
  now=$(date +%s)
  for f in "$st"/*; do
    [ -e "$f" ] || continue
    read -r state rest < "$f"
    case $state in
      run) printf '%s %s\n' "${spin[tick % 10]}" "$rest" ;;
      ok)  if [ $((now - $(stat -c %Y "$f"))) -lt 5 ]; then printf '✓ %s\n' "$rest"; else rm -f "$f"; fi ;;
      err) if [ $((now - $(stat -c %Y "$f"))) -lt 8 ]; then printf '✗ %s\n' "$rest"; else rm -f "$f"; fi ;;
    esac
  done
  printf '\033[0m\033[%d;1H%s' "$rows" "$foot"
}

# The laptop's herdr, under timeout: a link that died with the lid shut (sshd drops it in ~45 s)
# must not hang the box. A laptop's socket is a real socket file; instinct.sock there is a symlink
# to a session on this box.
lap() { HERDR_SOCKET_PATH=$sock timeout 5 "$herdr" "$@"; }
laptop() {  # ponytail: the first laptop that answers; two linked laptops would need the path tried on each
  for sock in ~/.config/herdr/remote/*.sock; do
    [ -S "$sock" ] && [ ! -L "$sock" ] && lap workspace list >/dev/null 2>&1 && return 0
  done
  return 1
}
idle() {  # the pane's only foreground process is its shell (the test fork-remote.sh uses)
  lap pane process-info --pane "$1" 2>/dev/null | jq -e '.result.process_info
    | (.foreground_processes | length) == 1
      and (.foreground_processes[0].pid == .shell_pid
           or (.foreground_processes[0].name | test("^(zsh|bash|fish|sh|dash|ksh|nu)$")))' >/dev/null
}
q() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }   # one word for the laptop's shell, whichever it is

upload() {  # <laptop path>; prints why on failure
  local p=$1 name=${1##*/} out pane ws i
  laptop || { echo "laptop not linked (femme-link)"; return 1; }
  out=$(lap workspace create --label "upload: $name" --no-focus 2>&1) || { echo "laptop: ${out:0:80}"; return 1; }
  pane=$(jq -r '.result.root_pane.pane_id // empty' <<<"$out")
  [ -n "$pane" ] || { echo "laptop returned no pane"; return 1; }
  ws=${pane%%:*}
  for i in $(seq 30); do idle "$pane" && break; sleep 0.5; done
  # One line, typed and entered. -s: the remote path is not shell-expanded. --partial-dir: a cut
  # transfer never looks like the finished file, so "it is here" means done.
  lap pane run "$pane" "rsync -a -s --partial-dir=.rsync-partial $(q "$p") $(q "$host:$dir/")" >/dev/null 2>&1 \
    || { lap workspace close "$ws" >/dev/null 2>&1; echo "laptop did not take the command"; return 1; }
  sleep 1                              # ponytail: the shell needs a moment to pick the line up before idle means done
  for i in $(seq 1800); do idle "$pane" && break; sleep 1; done
  if [ -e "$dir/$name" ]; then lap workspace close "$ws" >/dev/null 2>&1; return 0; fi
  # Not here: the pane says why (rsync's or ssh's own line, else whatever came last).
  lap pane read "$pane" --source recent-unwrapped --lines 15 2>/dev/null | grep -v -e '^[[:space:]]*$' -e rsync-partial \
    | { grep -m1 -E 'rsync: |ssh: |denied|failed' || tail -n 1; } | cut -c1-120
  lap workspace close "$ws" >/dev/null 2>&1
  return 1
}

take() {  # one dropped path, in the background; its status line lives in $st
  local p=${1%/} name f why
  name=${p##*/}
  f=$(mktemp -p "$st"); printf 'run %s\n' "$name" > "$f"
  if [ -e "$p" ]; then                 # already on this box
    case $p in
      "$dir"/*) printf 'ok %s (already here)\n' "$name" > "$f"; return ;;
      /tmp/herdr-clipboard-images-*/*) mv -n "$p" "$dir/" ;;   # herdr's copy of a dropped image: consume it
      *) cp -a "$p" "$dir/" ;;         # a synced folder's file: moving it would delete it on the laptop too
    esac && printf 'ok %s\n' "$name" > "$f" || printf 'err %s: could not copy\n' "$name" > "$f"
    return
  fi
  why=$(upload "$p") && printf 'ok %s\n' "$name" > "$f" || printf 'err %s: %s\n' "$name" "$why" > "$f"
}

handle() {  # one pasted line
  local text=$1 paths p m1=$'\e[200~' m2=$'\e[201~'
  text=${text//"$m1"/}; text=${text//"$m2"/}
  # Emulators paste dropped paths shell-quoted ('a b.txt'), backslash-escaped (a\ b.txt) or as
  # file:// URLs (percent-encoded), several per drop. xargs undoes the quoting; a lone apostrophe
  # trips it, and then the whole line is one path.
  paths=$(printf '%s\n' "$text" | xargs -n1 printf '%s\n' 2>/dev/null) || paths=$text
  while IFS= read -r p; do
    p=${p#file://}; p=${p#localhost}
    case $p in *%*) p=$(printf '%b' "${p//%/\\x}") ;; esac   # ponytail: a literal backslash in a name is mangled
    case $p in /*) take "$p" </dev/null >/dev/null 2>&1 & ;; esac   # anything else is typed noise
  done <<<"$paths"
}

while :; do
  render; tick=$((tick + 1))
  t=1; [ -n "$(ls -A "$st")" ] && t=0.2    # a transfer in flight: the spinner turns
  line=
  IFS= read -r -t "$t" line
  [ -n "$line" ] || continue
  more=; IFS= read -r -t 0.1 more; line=$line$more   # a paste straddling the deadline: its tail too
  [ "$line" = q ] && exit 0
  handle "$line"
done
