#!/usr/bin/env bash
# Cron entrypoint: run both directions once. Cheap when idle (no LLM call unless a
# package is waiting). Wired to cron every 2 minutes.
BIN="${AI_HANDOFF_ROOT:-$HOME/ai-handoff}/bin"
ROOT="${AI_HANDOFF_ROOT:-$HOME/ai-handoff}"
mkdir -p "$ROOT/locks"
exec 9>"$ROOT/locks/poll.lock"
flock -n 9 || exit 0
"$BIN/codex-pickup.sh" & codex_pid=$!
"$BIN/claude-pickup.sh" & claude_pid=$!
wait "$codex_pid"; codex_rc=$?
wait "$claude_pid"; claude_rc=$?
exit $((codex_rc || claude_rc))
