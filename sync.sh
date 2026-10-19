#!/usr/bin/env bash
# Laptop -> VPS: this repo, agent + herdr config. Safe to rerun.
# Project folders sync on demand, when you fork into them (sync-dir.sh).
# Never copies credentials: log in on the VPS once (see README).
set -euo pipefail
cd "$(dirname "$0")"
. ./.env
r() { rsync -az --mkpath "$@"; }

r --delete --exclude=board/target ./ "$HOST:femme/"
if [ -n "${BOARD_URL:-}" ]; then  # built here: the binary needs glibc 2.34, the VPS has 2.39
  cargo build -q --release --manifest-path board/Cargo.toml
  r board/target/release/femme-board "$HOST:.local/bin/"
fi

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
