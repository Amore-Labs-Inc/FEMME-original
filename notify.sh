#!/usr/bin/env bash
# Push to ntfy when a herdr agent turns blocked or done.
# ponytail: polls the snapshot every 5s; switch to an event stream if herdr grows one.
set -u
. "$(dirname "$0")/.env"
herdr=$HOME/.local/bin/herdr
declare -A last
while sleep 5; do
  while IFS=$'\t' read -r pane status title; do
    prev=${last[$pane]:-}
    last[$pane]=$status
    [ -n "$prev" ] && [ "$prev" != "$status" ] || continue
    case $status in
      blocked) msg="needs you"; prio=5 ;;
      done) msg="finished"; prio=3 ;;
      *) continue ;;
    esac
    jq -nc --arg t "$NTFY_TOPIC" --arg title "$title" --arg m "$msg ($pane)" --argjson p $prio \
      '{topic:$t, title:$title, message:$m, priority:$p}' \
      | curl -fsS -m 10 -d @- https://ntfy.sh/ >/dev/null || echo "ntfy push failed for $pane" >&2
  done < <("$herdr" api snapshot 2>/dev/null | jq -r '.. | objects | select(has("agent_status"))
    | [.pane_id, .agent_status, (.terminal_title_stripped // .agent // "agent")] | @tsv')
done
