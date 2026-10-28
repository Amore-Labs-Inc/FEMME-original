#!/usr/bin/env bash
# Rotates Claude accounts on the Fable weekly limit (femme-fable-cap.service). cswap's own engine
# (femme-cswap.service) rotates on the 5-hour window at $CAP and has one threshold, so this loop
# handles the Fable weekly at $FABLE_CAP: an account past it is held out of rotation (cswap disable),
# which keeps the engine from landing on it, and the box moves to the account with the most left,
# Fable counted. A held account comes back when its week resets. Only accounts held here are re-enabled.
set -u
cd "$(dirname "$0")"
. ./.env
FABLE_CAP=${FABLE_CAP:-96}
held=$HOME/.local/state/femme/fable-held  # account numbers this loop disabled, one per line
mkdir -p "${held%/*}"; touch "$held"
log() { echo "$(date -u +%FT%TZ) $*"; }

while :; do
  move=
  while IFS=$'\t' read -r n active disabled pct; do
    [ -n "$n" ] || continue
    if [ "$pct" -ge "$FABLE_CAP" ]; then
      [ "$active" = true ] && move=1
      [ "$disabled" = true ] || { cswap disable "$n" >/dev/null && echo "$n" >> "$held" && log "account $n held: Fable weekly at $pct%"; }
    elif [ "$disabled" = true ] && grep -qx "$n" "$held"; then
      cswap enable "$n" >/dev/null && sed -i "/^$n\$/d" "$held" && log "account $n back: Fable weekly at $pct%"
    fi
  done < <(cswap list --json 2>/dev/null | jq -r '.accounts[] | [.number, .active, .disabled // false,
    ((.usage.scoped // []) | map(select(.name == "Fable")) | .[0].pct // 0 | floor)] | @tsv')
  [ -z "$move" ] || log "$(cswap switch --strategy best --model Fable 2>&1 | tail -n 1)"
  sleep 60
done
