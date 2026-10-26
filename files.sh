#!/bin/sh
# Open the drop box (files-pane.sh) to the right of the focused agent, on the agent's folder: the
# place to drag files from the laptop to. Runs where the workspace lives, so on the VPS for an
# agentbox workspace, from that side's copy of the plugin.
#
# Usage: files.sh [pane-id]
set -u

herdr=${HERDR_BIN_PATH:-herdr}
notify() { "$herdr" notification show "femme" --body "$1" --sound "${2:-none}" >/dev/null 2>&1; }
fail() { notify "$1" request; printf 'files: %s\n' "$1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required but not on PATH"

ctx=${HERDR_PLUGIN_CONTEXT_JSON:-}
target=${1:-}
[ -n "$target" ] || target=$(printf '%s' "$ctx" | jq -r '.focused_pane_id // empty' 2>/dev/null)
[ -n "$target" ] || target=${HERDR_PANE_ID:-}
[ -n "$target" ] || fail "no focused pane"

# The folder the pane's foreground process is in (the agent's), else the pane's own.
dir=$("$herdr" pane get "$target" 2>/dev/null | jq -r '.result.pane | .foreground_cwd // .cwd // empty')
[ -n "$dir" ] || dir=$(printf '%s' "$ctx" | jq -r '.focused_pane_cwd // .workspace_cwd // empty')
[ -d "$dir" ] || fail "no folder for $target"

# --focus: a drop is pasted into the focused pane, so the box must be it. The folder goes as an
# env var: a pane command starts in the plugin folder, and whether --cwd moves it is undocumented.
out=$("$herdr" plugin pane open --plugin femme --entrypoint files --placement split --direction right \
  --target-pane "$target" --env "FEMME_DIR=$dir" --focus 2>&1) || fail "could not open the drop box: $out"
new=$(printf '%s' "$out" | jq -r '[.. | objects | select(has("pane_id")) | .pane_id] | first // empty')
# The agent keeps 70 % of the width: the split is even, and --amount is a share of the whole.
[ -z "$new" ] || "$herdr" pane resize --pane "$new" --direction right --amount 0.2 >/dev/null 2>&1
