#!/usr/bin/env bash
# Laptop -> VPS: this repo, agent + herdr config, repos and their .env files. Safe to rerun.
# Never copies credentials: log in on the VPS once (see README).
set -euo pipefail
cd "$(dirname "$0")"
. ./.env
REPOS=${REPOS:-$HOME/Documents/Web_Apps}
r() { rsync -az --mkpath "$@"; }

r --delete ./ "$HOST:femme/"

cd ~
r -R --ignore-missing-args \
  .claude/{CLAUDE.md,RTK.md,rules,skills,agents,hooks,settings.json,keybindings.json,plugins} \
  .config/herdr/{config.toml,plugins,plugins.json} .config/mise/config.toml \
  .local/bin/rtk \
  "$HOST:"

ssh "$HOST" "HERDR_VERSION=$(herdr --version | cut -d' ' -f2) ~/femme/bootstrap.sh"

# Clone needs `gh auth login` on the VPS first; until then private repos are skipped.
for d in "$REPOS"/*/; do
  d=${d%/}
  url=$(git -C "$d" remote get-url origin 2>/dev/null) || continue
  if ssh "$HOST" "[ -d $(printf %q "$d/.git") ] || git clone -q $(printf %q "$url") $(printf %q "$d")"; then
    r -m --exclude=node_modules --exclude=.git --include='*/' --include='.env*' --exclude='*' "$d/" "$HOST:$d/"
  else
    echo "skip $d (clone failed: run gh auth login on $HOST)" >&2
  fi
done
