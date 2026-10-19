#!/bin/sh
# Keep <dir> in live two-way sync with the same path on the VPS (Mutagen, two-way-safe:
# a conflict pauses that file instead of overwriting either side). The first call seeds
# the VPS with rsync, which is faster for bulk, and never overwrites newer VPS files.
#
# Usage: sync-dir.sh <dir>     Host: $FEMME_HOST (default agentbox)
set -eu
host=${FEMME_HOST:-agentbox}
dir=$(cd "$1" && pwd)
case $dir in "$HOME"/?*) ;; *) echo "sync-dir: only folders inside $HOME" >&2; exit 1 ;; esac
name=femme-$(printf '%s' "$dir" | cksum | cut -d' ' -f1)
# Rebuildable, platform-specific dirs stay on their own side.
ignores="node_modules .venv venv __pycache__ target .cache .next"

if ! mutagen sync list "$name" >/dev/null 2>&1; then
  set --
  for i in $ignores; do set -- "$@" --exclude="$i"; done
  rsync -az --mkpath --update "$@" "$dir/" "$host:$dir/"
  set --
  for i in $ignores; do set -- "$@" -i "$i"; done
  mutagen sync create --name "$name" -m two-way-safe --symlink-mode posix-raw "$@" "$dir" "$host:$dir" >/dev/null
fi
mutagen sync flush "$name"
