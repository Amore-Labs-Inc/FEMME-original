#!/usr/bin/env bash
# A minimal FEMME API client: what a chat bot does, from a shell. Needs curl and jq.
#
#   export FEMME_URL=http://localhost:8787     # or your public https:// board
#   export FEMME_KEY=...                       # made on the board: accounts (⋯) → API keys
#
#   ./api-client.sh send <name> "<task>" [owner/repo]   send a task; the first one opens the session and needs the repo
#   ./api-client.sh wait <name>                          wait until Claude stops, then print the report
#   ./api-client.sh push <name> ["note"]                 the owner said yes: commit and push the changes
#   ./api-client.sh discard <name> ["note"]              the owner said no: throw the changes away
#   ./api-client.sh close <name>                         close the session
#
# A whole task: send → wait → show the report to the owner → push or discard.
set -euo pipefail
: "${FEMME_URL:?set FEMME_URL}" "${FEMME_KEY:?set FEMME_KEY}"
api() {  # method path [json body]
  curl -sS --fail-with-body -X "$1" -H "Authorization: Bearer $FEMME_KEY" -H 'Content-Type: application/json' \
    ${3:+-d "$3"} "$FEMME_URL$2"
}
cmd=${1:-} name=${2:-}
[ -n "$name" ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

case $cmd in
  send)
    body=$(jq -nc --arg t "${3:?task text}" --arg r "${4:-}" '{text: $t} + (if $r == "" then {} else {repo: $r} end)')
    api POST "/api/agents/$name" "$body" | jq -r '"sent; status: " + .status'
    ;;
  wait)
    while :; do
      s=$(api GET "/api/agents/$name")
      case $(jq -r .status <<<"$s") in
        working) sleep 15 ;;
        blocked) echo "Claude is waiting for an answer; its screen:"; jq -r .screen <<<"$s"; exit 3 ;;
        *) jq -r '.message // empty' <<<"$s"; echo; jq -r '.report // "(no report yet)"' <<<"$s"; exit 0 ;;
      esac
    done
    ;;
  push|discard)
    api POST "/api/agents/$name/$cmd" "$(jq -nc --arg t "${3:-}" 'if $t == "" then {} else {text: $t} end')" | jq -r '.message // "ok"'
    ;;
  close)
    api DELETE "/api/agents/$name" >/dev/null && echo closed
    ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
