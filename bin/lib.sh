#!/usr/bin/env bash
# Shared config + helpers for the Claude<->Codex handoff bridge.
# Sourced by every bridge script. Sets a cron-safe PATH (cron has almost no env).

# Resolve node/codex/claude on PATH regardless of nvm version bumps.
NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | tail -1 || true)"
export PATH="${NODE_BIN:+$NODE_BIN:}$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

ROOT="${AI_HANDOFF_ROOT:-$HOME/ai-handoff}"
TO_CODEX="$ROOT/to-codex"
TO_CLAUDE="$ROOT/to-claude"
ARCHIVE="$ROOT/archive"
LOGS="$ROOT/logs"
LEDGER="$ROOT/ledger.log"
SCHEMA="$ROOT/verdict.schema.json"
NOTICE="$ROOT/NOTICE-validated-work.md"

[ -f "$ROOT/config.env" ] && source "$ROOT/config.env"
CODEX_MODEL="${CODEX_MODEL:-}"
CLAUDE_AUTOPICK="${CLAUDE_AUTOPICK:-0}"

ts()  { date +%Y%m%dT%H%M%S; }
iso() { date -Is; }
log() { printf '%s  %s\n' "$(iso)" "$*" >> "$LOGS/bridge.log"; }

# Degraded-mode detector: does a judge event log show a provider outage
# (quota/auth/session/capacity) rather than a real review failure? Scoped to the
# TAIL of the log, because a provider error is emitted last, right before the
# process exits. Grepping the whole stream false-positived when a judge quoted
# THIS script's own quota-handling lines while reviewing bridge code (2026-07-13);
# and the real 'model is at capacity' string was not even in the old pattern.
# Both lanes share this so the term set (Codex + Claude) stays in one place.
QUOTA_OUTAGE_RE='rate.?limit|quota|usage.?limit|session limit|too many requests|429|401 Unauthorized|Overloaded|at capacity|service unavailable|503|no (Codex|Claude) credentials'
looks_like_quota_outage() {  # <judge-log-file>
  [ -f "$1" ] || return 1
  tail -n 40 "$1" 2>/dev/null | grep -qiE "$QUOTA_OUTAGE_RE"
}

# Idempotency: a package id is finalised at most once across overlapping workers.
ledger_has() { grep -qF "	$1	" "$LEDGER" 2>/dev/null; }
ledger_add() { printf '%s\t%s\t%s\t%s\n' "$(iso)" "$1" "$2" "$3" >> "$LEDGER"; }  # direction, id, result

FINAL_FD=""
acquire_finalisation() {  # <package-id>; returns 2 when already completed
  mkdir -p "$ROOT/locks"
  exec {FINAL_FD}>"$ROOT/locks/finalise-$1.lock"
  flock -n "$FINAL_FD" || return 1
  if ledger_has "$1"; then
    flock -u "$FINAL_FD"
    exec {FINAL_FD}>&-
    FINAL_FD=""
    return 2
  fi
}
release_finalisation() {
  [ -n "$FINAL_FD" ] || return 0
  flock -u "$FINAL_FD"
  exec {FINAL_FD}>&-
  FINAL_FD=""
}

# Small JSON field reader: json_get <file> <dotted.key> [default]
json_get() {
  python3 - "$1" "$2" "${3:-}" <<'PY' 2>/dev/null
import json, sys
f, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    obj = json.load(open(f))
except Exception:
    print(default); sys.exit(0)
for part in key.split('.'):
    if isinstance(obj, dict) and part in obj:
        obj = obj[part]
    else:
        print(default); sys.exit(0)
print(obj if isinstance(obj, str) else json.dumps(obj))
PY
}

WORKTREES="$ROOT/tmp-worktrees"

# Atomic claim with a 45-minute lease: a dead worker's claim is reclaimable, so a
# package can never be wedged forever (proposal S9).
claim_pkg() {  # <pkg-dir>
  local claim_fd
  exec {claim_fd}>"$1/.claim.lock"
  flock -n "$claim_fd" || return 1
  if [ -d "$1/CLAIMED" ] && [ ! -f "$1/DONE" ] && [ -z "$(find "$1/CLAIMED" -maxdepth 0 -mmin -45 2>/dev/null)" ]; then
    rm -rf -- "$1/CLAIMED" 2>/dev/null && log "claim lease expired - reclaimed $(basename "$1")"
  fi
  if mkdir "$1/CLAIMED" 2>/dev/null; then
    printf '%s\n' "$(hostname):$$:$(iso)" > "$1/CLAIMED/worker"
    flock -u "$claim_fd"; exec {claim_fd}>&-
    return 0
  fi
  flock -u "$claim_fd"; exec {claim_fd}>&-
  return 1
}

CLAIM_HEARTBEAT_PID=""
start_claim_heartbeat() {  # <pkg-dir>
  local owner=$$
  ( while [ -d "$1/CLAIMED" ] && kill -0 "$owner" 2>/dev/null; do
      touch "$1/CLAIMED"
      sleep 60
    done ) &
  CLAIM_HEARTBEAT_PID=$!
}
stop_claim_heartbeat() {
  [ -n "$CLAIM_HEARTBEAT_PID" ] || return 0
  kill "$CLAIM_HEARTBEAT_PID" 2>/dev/null || true
  wait "$CLAIM_HEARTBEAT_PID" 2>/dev/null || true
  CLAIM_HEARTBEAT_PID=""
}

# Immutable review checkout (proposal S4): judge sees the pinned SHA, never the
# author's live working tree.
make_review_worktree() {  # <target-repo> <sha> <id> -> echoes worktree path (empty on failure)
  mkdir -p "$WORKTREES"
  local wt="$WORKTREES/$3"
  git -C "$1" worktree remove --force "$wt" 2>/dev/null || true
  rm -rf -- "$wt"
  git -C "$1" worktree prune --expire now 2>/dev/null || true
  if git -C "$1" worktree add --detach -q "$wt" "$2" 2>>"$LOGS/bridge.log"; then echo "$wt"; fi
}
drop_review_worktree() {  # <target-repo> <worktree-path>
  [ -n "$2" ] && git -C "$1" worktree remove --force "$2" 2>/dev/null || true
}

repo_review_identity_valid() {  # <pkg-dir>
  local target reviewed base_sha
  target="$(json_get "$1/manifest.json" target '')"
  reviewed="$(json_get "$1/manifest.json" reviewed_sha '')"
  base_sha="$(json_get "$1/manifest.json" base_sha '')"
  [ -n "$target" ] && [ -n "$reviewed" ] && [ -n "$base_sha" ] \
    && git -C "$target" cat-file -e "$reviewed^{commit}" 2>/dev/null \
    && git -C "$target" cat-file -e "$base_sha^{commit}" 2>/dev/null
}

checks_all_passed() {  # <pkg-dir>
  python3 - "$1/check-results.json" <<'PY' 2>/dev/null
import json, sys
try:
    obj = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if obj.get("all_passed") is True else 1)
PY
}

# VERDICT GATE. Bridge-recorded check evidence is authoritative, not the judge's
# prose. A "pass" must not be finalised when the package declared deterministic
# checks that did not all pass (or whose results are missing/unreadable). Content
# verdicts of fail/needs-changes are unaffected; a package that declared no checks
# stays judge-only as before. Returns 0 if a pass may stand, non-zero if it must be
# gated. See memory bridge-verdict-not-gated-on-checks.
pass_backed_by_checks() {  # <pkg-dir>
  manifest_has_checks "$1" || return 0   # no declared checks -> nothing to contradict
  checks_all_passed "$1"                 # declared checks must be all green
}

manifest_has_checks() {  # <pkg-dir>
  python3 - "$1/manifest.json" <<'PY' 2>/dev/null
import json, sys
try:
    checks = json.load(open(sys.argv[1])).get("checks")
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if isinstance(checks, list) and len(checks) > 0 else 1)
PY
}

verdict_has_high_findings() {  # <verdict-json>
  python3 - "$1" <<'PY' 2>/dev/null
import json, sys
try:
    findings = json.load(open(sys.argv[1])).get("findings", [])
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if any(x.get("severity") == "high" for x in findings if isinstance(x, dict)) else 1)
PY
}

run_package_checks() {  # <pkg> <kind> <target> <reviewed-sha> <id>
  local pkg="$1" kind="$2" target="$3" reviewed="$4" id="$5"
  local checkroot="" check_wt=""
  if [ "$kind" = "artifact" ]; then
    "$ROOT/bin/verify-payload.py" "$pkg/manifest.json" "$pkg/payload" || return 1
    checkroot="$ROOT/tmp-checks/$id"
    rm -rf -- "$checkroot"
    mkdir -p "$checkroot"
    cp -a -- "$pkg/payload" "$checkroot/payload" || return 1
    cp -a -- "$pkg/manifest.json" "$checkroot/manifest.json" || return 1
  else
    check_wt="$(make_review_worktree "$target" "$reviewed" "${id}-checks")"
    [ -n "$check_wt" ] || return 1
    checkroot="$check_wt"
  fi
  "$ROOT/bin/run-checks.py" "$pkg/manifest.json" "$checkroot" "$pkg"
  local rc=$?
  if [ -n "$check_wt" ]; then
    drop_review_worktree "$target" "$check_wt"
  else
    rm -rf -- "$checkroot"
  fi
  return "$rc"
}

hold_package() {  # <pkg> <reason> <retryable:true|false>
  local pkg="$1" reason="$2" retryable="$3" id created_by direction dest action
  stop_claim_heartbeat
  id="$(basename "$pkg")"
  created_by="$(json_get "$pkg/manifest.json" created_by '')"
  direction="to-codex"
  [ "$created_by" = "codex" ] && direction="to-claude"
  action="retry"
  [ "$retryable" = "true" ] || action="redrop-required"
  python3 - "$pkg/HELD.json" "$reason" "$retryable" "$direction" "$action" <<'PY'
import json, sys
from datetime import datetime
p, reason, retryable, direction, action = sys.argv[1:6]
json.dump({"reason": reason, "retryable": retryable == "true", "direction": direction,
           "action": action, "held_at": datetime.now().astimezone().isoformat()},
          open(p, "w"), indent=2)
PY
  rm -rf -- "$pkg/CLAIMED"
  mkdir -p "$ROOT/held"
  dest="$ROOT/held/$id"
  if [ -e "$dest" ]; then
    dest="$ROOT/held/${id}.duplicate.$(ts).$$"
  fi
  mv "$pkg" "$dest"
  log "held: $id reason=$reason retryable=$retryable direction=$direction dest=$(basename "$dest")"
}
