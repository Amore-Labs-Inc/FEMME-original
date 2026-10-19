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

# Claude's first-run flags, folder trust and the MCP servers that work headless.
# Merged into the VPS copy, so its own login (oauthAccount) stays.
jq --arg mcp "${CLAUDE_MCP:-context7 codegraph}" '{theme, hasCompletedOnboarding, lastOnboardingVersion,
    projects: (.projects // {} | map_values({hasTrustDialogAccepted})),
    mcpServers: (.mcpServers // {} | with_entries(select(.key as $k | $mcp | split(" ") | index($k))))}' ~/.claude.json \
  | ssh "$HOST" 'f=~/.claude.json; [ -s $f ] || echo {} > $f; jq -s ".[0] * .[1]" $f - > $f.tmp && mv $f.tmp $f'

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
