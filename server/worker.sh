#!/usr/bin/env bash
# Works the board queue on the VPS: each issue gets its own clone, branch femme/issue-N and a
# visible herdr workspace running Claude. At most $PARALLEL at once. When Claude's 5-hour window
# passes $CAP percent, running agents are interrupted and wait for the reset, so the rest of the
# window stays yours; after the reset they continue where they stopped.
set -u
cd "$(dirname "$0")/.."  # the checkout root: .env and every path below are relative to it
. ./.env
CAP=${CAP:-60}
PARALLEL=${PARALLEL:-2}
WORK=$HOME/femme-work
STATE=$HOME/.local/state/femme
B=http://127.0.0.1:8787
TOKEN=$(cat "$STATE/worker.token")

api() { curl -fsS -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }
patch() { api -X PATCH -d "$2" "$B/api/issues/$1" >/dev/null || echo "could not update issue $1" >&2; }
note() { jq -nc --arg s "$1" --arg n "$2" '{status:$s, note:$n}'; }
log() { echo "$(date -u +%FT%TZ) $*"; }

# Session (5-hour) window as {percent, resets_at}. /usage is a local command: no model turn.
usage() {
  (cd /tmp && claude -p /usage --output-format stream-json --verbose --no-session-persistence 2>/dev/null) \
    | jq -c 'select(.type=="assistant") | .usage_report.rate_limits.limits[]? | select(.kind=="session") | {percent, resets_at}' \
    | head -n 1
}

agent_status() { herdr agent get "femme-$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; }

close_workspace() {
  ws=$(herdr agent get "femme-$1" 2>/dev/null | jq -r '.result.agent.workspace_id // empty')
  [ -n "$ws" ] && herdr workspace close "$ws" >/dev/null 2>&1
}

pr_for() { gh pr list --repo "$1" --head "femme/issue-$2" --state all --json url -q '.[0].url' 2>/dev/null; }

start() {  # id repo title body
  id=$1 repo=$2 dir=$WORK/${2#*/}-$1
  log "starting #$id ($repo)"
  close_workspace "$id"  # a retry replaces the old attempt
  if [ ! -d "$dir/.git" ]; then
    gh repo clone "$repo" "$dir" -- --quiet 2>/dev/null || { patch "$id" "$(note failed "could not clone $repo")"; return; }
  fi
  git -C "$dir" checkout -q -B "femme/issue-$id" 2>/dev/null
  pane=$(herdr workspace create --cwd "$dir" --label "#$id ${3:0:40}" --no-focus | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$pane" ] || { patch "$id" "$(note failed "herdr could not open a workspace")"; return; }
  for _ in $(seq 30); do  # wait for the pane's shell, like forkr
    herdr pane process-info --pane "$pane" 2>/dev/null \
      | jq -e '.result.process_info | (.foreground_processes | length) == 1' >/dev/null && break
    sleep 0.5
  done
  herdr agent start "femme-$id" --kind claude --pane "$pane" --timeout 60000 >/dev/null 2>&1
  herdr agent prompt "femme-$id" "You are working on FEMME board issue #$id for $repo, cloned here on branch femme/issue-$id.

Title: $3

Details:
${4:-(none)}

Do it end to end: implement, run the project's checks and tests, commit, push the branch (git push -u origin femme/issue-$id), then open a PR with gh pr create whose body starts with \"FEMME issue #$id\" and says what changed and how you verified it. If you are blocked on a decision only the owner can make, say so plainly and stop." >/dev/null 2>&1 \
    || { patch "$id" "$(note failed "Claude did not take the prompt; open the workspace to see why")"; return; }
  patch "$id" "$(jq -nc --arg p "$pane" '{status:"working", pane:$p, note:""}')"
}

write_meta() {  # state usage_json
  [ -s "$STATE/repos" ] && [ -z "$(find "$STATE/repos" -mmin +60)" ] \
    || for owner in "" $(gh api user/orgs --jq '.[].login' 2>/dev/null); do  # yours, then every org you're in
         gh repo list $owner --limit 300 --json nameWithOwner -q '.[].nameWithOwner' 2>/dev/null
       done > "$STATE/repos"
  jq -nc --arg s "$1" --argjson u "${2:-null}" --argjson cap "$CAP" --rawfile r "$STATE/repos" \
    '{state:$s, usage:$u, cap:$cap, repos:($r | split("\n") | map(select(. != ""))), updated:now}' > "$STATE/meta.tmp" \
    && mv "$STATE/meta.tmp" "$STATE/meta.json"
}

mkdir -p "$WORK"
last_usage=null
while sleep 60; do
  issues=$(api "$B/api/issues") || { log "board is down"; continue; }
  if [ "$(jq '[.[] | select(.status=="open" or .status=="working" or .status=="waiting" or .status=="paused")] | length' <<<"$issues")" = 0 ]; then
    write_meta "idle: queue is empty" "$last_usage"
    continue
  fi

  u=$(usage)
  [ -n "$u" ] && last_usage=$u
  pct=$(jq -r '.percent // 0 | floor' <<<"${u:-null}")
  over=$(( pct >= CAP ))

  # Active issues: opened a PR, went over budget, stopped to ask you, or got your reply.
  while IFS=$'\t' read -r id repo status; do
    [ -n "$id" ] || continue
    st=$(agent_status "$id")
    pr=$(pr_for "$repo" "$id")
    if [ -n "$pr" ] && [ "$st" != working ]; then
      log "#$id opened $pr"
      patch "$id" "$(jq -nc --arg u "$pr" '{status:"pr", pr_url:$u, note:""}')"
    elif [ -z "$st" ]; then
      patch "$id" "$(note failed "its workspace was closed")"
    elif [ "$st" = working ] && [ "$over" = 1 ]; then
      log "#$id paused at $pct%"
      herdr agent send-keys "femme-$id" esc >/dev/null 2>&1
      patch "$id" "$(note paused "paused at $pct% of the 5-hour window, continues after it resets")"
    elif [ "$st" = working ] && [ "$status" = waiting ]; then
      patch "$id" "$(note working "")"
    elif [ "$st" = blocked ] && [ "$status" = working ]; then
      patch "$id" "$(note waiting "Claude is asking for your approval: open Chat")"
    elif { [ "$st" = done ] || [ "$st" = idle ]; } && [ "$status" = working ]; then
      patch "$id" "$(note waiting "Claude stopped without a PR: read its last message in Chat")"
    fi
  done < <(jq -r '.[] | select(.status=="working" or .status=="waiting") | [.id, .repo, .status] | @tsv' <<<"$issues")

  if [ "$over" = 1 ]; then
    write_meta "paused until the window resets ($pct% used)" "${u:-null}"
    continue
  fi

  # Under budget: wake paused agents first, then start queued issues.
  issues=$(api "$B/api/issues") || continue
  while read -r id; do
    [ -n "$id" ] || continue
    if [ -n "$(agent_status "$id")" ]; then
      log "#$id continuing"
      herdr agent prompt "femme-$id" "The usage window has reset. Continue where you left off." >/dev/null 2>&1
      patch "$id" "$(note working "")"
    else
      patch "$id" "$(note open "")"
    fi
  done < <(jq -r '.[] | select(.status=="paused") | .id' <<<"$issues")

  issues=$(api "$B/api/issues") || continue
  running=$(jq '[.[] | select(.status=="working")] | length' <<<"$issues")
  for id in $(jq -r '[.[] | select(.status=="open")] | sort_by(.id)[].id' <<<"$issues"); do
    [ "$running" -lt "$PARALLEL" ] || break
    i=$(jq -c --argjson n "$id" '.[] | select(.id==$n)' <<<"$issues")
    start "$id" "$(jq -r .repo <<<"$i")" "$(jq -r .title <<<"$i")" "$(jq -r '.body // ""' <<<"$i")"
    running=$((running + 1))
  done

  # Issues marked done on the board: close their workspaces.
  for id in $(jq -r '.[] | select(.status=="done") | .id' <<<"$issues"); do
    [ -n "$(agent_status "$id")" ] && close_workspace "$id"
  done

  write_meta "working ($pct% used, pause at $CAP%)" "${u:-null}"
done
