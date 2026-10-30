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

# The copy scripts need rsync 3.2.3 or newer (--mkpath, --ignore-missing-args). macOS ships
# openrsync, which has neither: brew install rsync puts a current one first on PATH.
rsync_ok() {
  local v; v=$(rsync --version 2>/dev/null | sed -n 's/^rsync  *version v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | head -n 1)
  [ -n "$v" ] && [ "$(printf '%s\n3.2.3\n' "$v" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = 3.2.3 ]
}
rsync_fix() { case $(uname -s) in Darwin) echo "brew install rsync, then open a new terminal" ;; *) echo "install rsync 3.2.3 or newer with your package manager" ;; esac; }

# y/n question; $2 is the default (y or n).
ask_yes() {
  local a
  read -r -p "$1 [$( [ "$2" = y ] && echo Y/n || echo y/N )] " a
  a=${a:-$2}
  case $a in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# Pick one of several options with the arrow keys (or j/k, or its number) and Enter.
# Usage: choose VAR "question" "option 1" "option 2" ...   VAR gets the number picked, from 1.
# Without a terminal (piped answers) it reads the number instead.
choose() {
  local var=$1 q=$2 cur=1 key rest i n; shift 2; n=$#
  printf '%s\n' "$q" >&2
  if [ ! -t 0 ] || [ ! -t 2 ]; then
    i=0; for o in "$@"; do i=$((i + 1)); printf '  %d) %s\n' $i "$o" >&2; done
    read -r -p "1-$n: " cur
    case $cur in ''|*[!0-9]*) die "pick a number from 1 to $n" ;; esac
    [ "$cur" -ge 1 ] && [ "$cur" -le $n ] || die "pick a number from 1 to $n"
    eval "$var=\$cur"; return
  fi
  # One screen line per option, or redrawing in place drifts: cut what the terminal is too narrow for.
  local w; w=$(( $(tput cols 2>/dev/null || echo 80) - 6 ))
  printf '\033[?25l' >&2
  while :; do
    i=0
    for o in "$@"; do
      i=$((i + 1))
      [ ${#o} -le $w ] || o="${o:0:$((w - 1))}…"
      if [ $i = "$cur" ]; then printf '\r\033[K  \033[36m❯ %s\033[0m\n' "$o" >&2; else printf '\r\033[K    \033[2m%s\033[0m\n' "$o" >&2; fi
    done
    IFS= read -rsn1 key
    case $key in
      $'\x1b') read -rsn2 rest; case $rest in '[A') key=k ;; '[B') key=j ;; esac ;;
    esac
    case $key in
      k) [ "$cur" -gt 1 ] && cur=$((cur - 1)) ;;
      j) [ "$cur" -lt $n ] && cur=$((cur + 1)) ;;
      [1-9]) [ "$key" -le $n ] && cur=$key ;;
      '') break ;;
    esac
    printf '\033[%dA' $n >&2
  done
  printf '\033[?25h' >&2
  eval "$var=\$cur"
}

# Run a long step quietly: its output goes to $LOG, a spinner and the time show meanwhile, and a
# failure prints the end of the log. Usage: step "what it does" command args...
step() {
  local msg=$1 pid t0=$SECONDS i=0 s='|/-\'; shift
  printf '\n== %s\n' "$msg" >> "$LOG"
  "$@" >> "$LOG" 2>&1 < /dev/null &
  pid=$!
  if [ -t 2 ]; then
    while kill -0 $pid 2>/dev/null; do
      printf '\r\033[K  %s %s \033[2m%ds\033[0m' "${s:$((i % 4)):1}" "$msg" $((SECONDS - t0)) >&2
      i=$((i + 1)); sleep 1
    done
  fi
  if wait $pid; then
    printf '\r\033[K  \033[32m✓\033[0m %s \033[2m%ds\033[0m\n' "$msg" $((SECONDS - t0)) >&2
  else
    printf '\r\033[K  \033[31m✗\033[0m %s\n' "$msg" >&2
    tail -n 30 "$LOG" >&2
    die "That step failed; the whole log is in $LOG"
  fi
}
