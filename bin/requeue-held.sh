#!/usr/bin/env bash
# Requeue packages held during a Codex outage (quota/auth). Run when Codex is back.
# Also used for retroactive cross-model review of anything degraded-passed meanwhile:
# re-drop those diffs and let the returning judge look at what it missed.
source "${AI_HANDOFF_ROOT:-$HOME/ai-handoff}/bin/lib.sh"
set -uo pipefail
shopt -s nullglob

n=0
redrop=0
for pkg in "$ROOT"/held/*/ ; do
  pkg="${pkg%/}"
  held="$pkg/HELD.json"
  if [ "$(json_get "$held" retryable false)" != "true" ]; then
    reason="$(json_get "$held" reason unknown)"
    action="$(json_get "$held" action redrop-required)"
    [ "$action" = "redrop-required" ] && redrop=$((redrop+1))
    log "requeue-held: $(basename "$pkg") retained reason=$reason action=$action"
    continue
  fi
  direction="$(json_get "$held" direction '')"
  case "$direction" in
    to-codex) destination="$TO_CODEX" ;;
    to-claude) destination="$TO_CLAUDE" ;;
    *) log "requeue-held: $(basename "$pkg") retained (invalid direction)"; continue ;;
  esac
  if [ -e "$destination/$(basename "$pkg")" ]; then
    log "requeue-held: $(basename "$pkg") retained (destination collision)"
    continue
  fi
  rm -rf -- "$pkg/CLAIMED"
  rm -f "$pkg/DONE"
  mv "$pkg" "$destination/" && n=$((n+1)) && log "requeue-held: $(basename "$pkg") requeued to $(basename "$destination")"
done
echo "requeued: $n package(s)"
[ "$redrop" -eq 0 ] || echo "re-drop required: $redrop package(s); their manifests cannot be repaired by requeue"
