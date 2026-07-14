#!/usr/bin/env bash
# CLAUDE DIRECTION. Scans to-claude/ for Codex verdicts and surfaces them so the
# interactive session sees validated work without being told. Default = notify-only
# (append to NOTICE + an optional notify file). Optional auto-triage via CLAUDE_AUTOPICK=1.
source "${AI_HANDOFF_ROOT:-$HOME/ai-handoff}/bin/lib.sh"
set -uo pipefail
shopt -s nullglob

NOTIFY_INBOX="${BRIDGE_NOTIFY_INBOX:-}"

# Extract the first JSON object from mixed stdout and check the verdict shape.
extract_verdict() {  # <raw-file> <out-json> <manifest> -> exit 0 if valid
  python3 - "$1" "$2" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
start = raw.find('{')
obj = None
while start != -1:
    dec = json.JSONDecoder()
    try:
        obj, _ = dec.raw_decode(raw[start:]); break
    except Exception:
        start = raw.find('{', start + 1)
ok = (isinstance(obj, dict)
      and obj.get('verdict') in ('pass', 'needs-changes', 'fail')
      and isinstance(obj.get('summary'), str)
      and isinstance(obj.get('findings'), list)
      and isinstance(obj.get('checked'), str))
if ok:
    json.dump(obj, open(sys.argv[2], 'w'), indent=2)
sys.exit(0 if ok else 1)
PY
  "$ROOT/bin/validate-verdict.py" "$2" "$3"
}

run_claude_review() {  # <model> <workroot> <prompt> <out-json> <raw-log> <manifest> -> sets REVIEW_VERDICT
  REVIEW_VERDICT="error"
  # prompt goes via stdin: --allowedTools is variadic and would swallow a positional arg
  ( cd "$2" && printf '%s' "$3" | "${BRIDGE_CLAUDE_BIN:-claude}" -p --model "$1" \
      --allowedTools "Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*),Bash(git branch:*),Bash(ls:*)" \
      ) > "$5" 2>&1
  if extract_verdict "$5" "$4" "$6"; then
    REVIEW_VERDICT="$(json_get "$4" verdict error)"
  fi
}

for pkg in "$TO_CLAUDE"/*/ ; do
  pkg="${pkg%/}"
  id="$(basename "$pkg")"
  [ -f "$pkg/READY" ] || continue
  [ -f "$pkg/DONE" ]  && continue
  claim_pkg "$pkg" || continue
  if ledger_has "notify:$id" || ledger_has "$id"; then touch "$pkg/DONE"; rm -rf -- "$pkg/CLAIMED"; continue; fi
  start_claim_heartbeat "$pkg"

  # ---- REVIEW-REQUEST path: Codex (or owner) authored work; Claude judges ----
  kind="$(json_get "$pkg/manifest.json" kind '')"
  if [ "$kind" = "artifact" ] || [ "$kind" = "repo-diff" ]; then
    if ! "$ROOT/bin/validate-manifest.py" "$pkg/manifest.json" codex; then
      hold_package "$pkg" "invalid-manifest" false
      continue
    fi
    criteria="$(json_get "$pkg/manifest.json" criteria '')"
    target="$(json_get "$pkg/manifest.json" target '')"
    base="$(json_get "$pkg/manifest.json" base '')"
    tier="$(json_get "$pkg/manifest.json" tier standard)"
    case "$tier" in
      light) judge="${CLAUDE_MODEL_LIGHT:-haiku}";;
      full)  judge="${CLAUDE_MODEL_FULL:-opus}";;
      *)     judge="${CLAUDE_MODEL_STANDARD:-sonnet}";;
    esac
    workroot="$pkg"; scope="the files under ./payload"; wt=""; reviewed_sha_m=""
    if [ "$kind" = "repo-diff" ] && ! repo_review_identity_valid "$pkg"; then
      hold_package "$pkg" "invalid-repository-identity" false
      continue
    fi
    if [ "$kind" = "repo-diff" ]; then
      reviewed_sha_m="$(json_get "$pkg/manifest.json" reviewed_sha '')"
      base_sha_m="$(json_get "$pkg/manifest.json" base_sha '')"
      [ -n "$reviewed_sha_m" ] && wt="$(make_review_worktree "$target" "$reviewed_sha_m" "$id")"
      if [ -n "$wt" ]; then
        workroot="$wt"
        scope="the changes ${base_sha_m:-$base}..${reviewed_sha_m} in this repository. You are in a detached checkout AT the reviewed commit; inspect the diff with: git diff ${base_sha_m:-$base} HEAD"
      else
        hold_package "$pkg" "immutable-checkout-failed" true
        continue
      fi
    fi
    if ! run_package_checks "$pkg" "$kind" "$target" "$reviewed_sha_m" "$id"; then
      drop_review_worktree "$target" "$wt"
      hold_package "$pkg" "payload-or-check-runner-failed" false
      continue
    fi
    if [ "$kind" = "repo-diff" ]; then
      identity_instruction="Include reviewed_identity exactly as: {\"kind\":\"repo-diff\",\"base_sha\":\"$(json_get "$pkg/manifest.json" base_sha '')\",\"reviewed_sha\":\"$reviewed_sha_m\",\"payload_sha256\":null}."
    else
      identity_instruction="Include reviewed_identity exactly as: {\"kind\":\"artifact\",\"base_sha\":null,\"reviewed_sha\":null,\"payload_sha256\":\"$(json_get "$pkg/manifest.json" payload_sha256 '')\"}."
    fi
    prompt="You are an INDEPENDENT validator and skeptic reviewing another agent's work.
Do NOT trust any summary or claim you are given; verify against the ACTUAL code/tree.
Review ${scope}.

Acceptance criteria / task context:
${criteria}

Authoritative bridge-recorded deterministic check evidence is at:
${pkg}/check-results.json
Inspect that file. Judge execution claims are not a substitute for it.
${identity_instruction}

Inspect thoroughly: correctness, edge cases, whether tests genuinely prove their claims
(not tautologies), and whether the work meets the criteria. Reply with ONLY a JSON object,
no prose, no code fences: {\"verdict\": \"pass\"|\"needs-changes\"|\"fail\", \"summary\": str,
\"findings\": [{\"severity\": \"high\"|\"medium\"|\"low\", \"location\": str, \"detail\": str}],
\"checked\": str naming the specific files/functions you actually read,
\"executions\": [{\"command\": str, \"exit_code\": int|null, \"evidence\": str}],
\"reviewed_identity\": object exactly as instructed above}. The checked field
is a structured claim, while bridge-recorded evidence remains authoritative."

    run_claude_review "$judge" "$workroot" "$prompt" "$pkg/verdict.json" "$pkg/claude-review.log" "$pkg/manifest.json"
    verdict="$REVIEW_VERDICT"
    [ "$verdict" = "error" ] && run_claude_review "$judge" "$workroot" "$prompt (REMINDER: output ONLY the JSON object)" "$pkg/verdict.json" "$pkg/claude-review.log" "$pkg/manifest.json" && verdict="$REVIEW_VERDICT"

    # escalate a sub-full fail once, mirroring the Codex lane
    escalated=""
    full_model="${CLAUDE_MODEL_FULL:-opus}"
    if [ "${ESCALATE_ON_FAIL:-0}" = "1" ] && [ "$judge" != "$full_model" ] \
       && { [ "$verdict" = "fail" ] || [ "$verdict" = "needs-changes" ]; }; then
      mv "$pkg/verdict.json" "$pkg/verdict-initial.json"
      run_claude_review "$full_model" "$workroot" "$prompt" "$pkg/verdict.json" "$pkg/claude-review-escalated.log" "$pkg/manifest.json"
      if [ "$REVIEW_VERDICT" != "error" ]; then
        escalated="escalated(${judge}:${verdict}->${full_model}:${REVIEW_VERDICT})"; verdict="$REVIEW_VERDICT"
      else
        cp "$pkg/verdict-initial.json" "$pkg/verdict.json"; escalated="escalated-error(kept ${judge}:${verdict})"
      fi
    fi

    # DEGRADED MODE: a quota/auth/session outage is not a review failure. Hold the
    # package for an owner decision (wait or same-family review) instead of misfiling
    # it as a content verdict error. Mirrors the Codex lane's degraded handling.
    if [ "$verdict" = "error" ] && looks_like_quota_outage "$pkg/claude-review.log"; then
      drop_review_worktree "$target" "$wt"
      hold_package "$pkg" "claude-quota-or-auth" true
      log "claude-pickup: HELD $id (claude unavailable - quota/auth/session); owner decision needed"
      {
        printf '## %s  HELD: `%s` - Claude unavailable (quota/auth/session)\n' "$(iso)" "$id"
        printf 'Owner call needed: wait for the Claude limit to reset, or a same-family (Codex) degraded review.\n'
        printf 'Requeue when back: `~/ai-handoff/bin/requeue-held.sh`\n\n'
      } >> "$NOTICE"
      continue
    fi

    if [ "$verdict" = "error" ]; then
      drop_review_worktree "$target" "$wt"
      hold_package "$pkg" "claude-review-error" true
      log "claude-pickup: HELD $id (judge produced no valid verdict)"
      continue
    fi

    # VERDICT GATE: a pass cannot be finalised on failed or missing check evidence.
    if [ "$verdict" = "pass" ] && ! pass_backed_by_checks "$pkg"; then
      drop_review_worktree "$target" "$wt"
      hold_package "$pkg" "pass-gated-checks-not-green" true
      log "claude-pickup: HELD $id (pass REFUSED: declared checks did not all pass)"
      {
        printf '## %s  HELD: `%s` - pass refused (bridge checks not all green)\n' "$(iso)" "$id"
        printf 'The judge returned pass but check-results.json is not all_passed. The verdict is not\n'
        printf 'trustworthy on this evidence. Fix the checks (or the code) and requeue, or review by hand.\n\n'
      } >> "$NOTICE"
      continue
    fi

    drop_review_worktree "$target" "$wt"

    acquire_finalisation "$id"
    final_rc=$?
    if [ "$final_rc" -ne 0 ]; then
      stop_claim_heartbeat
      touch "$pkg/DONE"
      mv "$pkg" "$ARCHIVE/${id}.duplicate.$(ts).$$" 2>/dev/null || true
      continue
    fi

    # merge-on-pass: identical mechanics to the Codex lane
    merge_note=""
    mop="$(json_get "$pkg/manifest.json" merge_on_pass false)"
    if [ "$verdict" = "pass" ] && [ "$mop" = "true" ]; then
      branch="$(json_get "$pkg/manifest.json" branch '')"
      reviewed_sha="$(json_get "$pkg/manifest.json" reviewed_sha '')"
      sha_now="$(git -C "$target" rev-parse "refs/heads/$branch" 2>/dev/null || true)"
      if [ "$tier" = "full" ]; then
        merge_note="merge-BLOCKED(Full tier requires owner acceptance)"
      elif ! manifest_has_checks "$pkg" || ! checks_all_passed "$pkg"; then
        merge_note="merge-BLOCKED(required bridge checks missing or failed)"
      elif verdict_has_high_findings "$pkg/verdict.json"; then
        merge_note="merge-BLOCKED(unresolved high-severity finding)"
      elif [ -n "$reviewed_sha" ] && [ "$sha_now" = "$reviewed_sha" ]; then
        if git -C "$target" push -q origin "$reviewed_sha:refs/heads/$base" 2>>"$LOGS/bridge.log"; then
          merge_note="merged:$base@${reviewed_sha:0:9}"
          cur="$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null)"
          if [ "$cur" = "$base" ] && [ -z "$(git -C "$target" status --porcelain)" ]; then
            git -C "$target" merge -q --ff-only "$reviewed_sha" 2>/dev/null || true
          elif [ "$cur" != "$base" ]; then
            git -C "$target" fetch -q . "$reviewed_sha:refs/heads/$base" 2>/dev/null || true
          fi
        else merge_note="merge-FAILED(push)"; fi
      else merge_note="merge-BLOCKED(stale: branch moved since review)"; fi
    fi

    summary="$(json_get "$pkg/verdict.json" summary '')"
    {
      printf '## %s  claude-reviewed: `%s`  verdict: **%s**%s\n' "$(iso)" "$id" "$verdict" "${merge_note:+  ($merge_note)}"
      [ -n "$summary" ] && printf '%s\n' "$summary"
      printf 'Package: `%s`\n\n' "$ARCHIVE/$(basename "$pkg")"
    } >> "$NOTICE"
    [ -f "$NOTIFY_INBOX" ] && printf -- '- [codex-bridge %s] Claude reviewed `%s` -> **%s**%s: %s\n' \
      "$(date +%Y-%m-%d)" "$id" "$verdict" "${merge_note:+ ($merge_note)}" "$summary" >> "$NOTIFY_INBOX" 2>/dev/null || true
    ledger_add "claude-review" "$id" "${verdict}[judge=claude:$judge tier=$tier]${escalated:+ ${escalated}}${merge_note:+ ${merge_note}}"
    log "claude-pickup(review): $id -> $verdict (judge=$judge)"
    touch "$pkg/DONE"
    stop_claim_heartbeat
    mv "$pkg" "$ARCHIVE/" 2>/dev/null || true
    release_finalisation
    continue
  fi

  # ---- VERDICT-NOTIFICATION path (existing) ----
  if ! "$ROOT/bin/validate-notification.py" "$pkg/manifest.json"; then
    hold_package "$pkg" "invalid-verdict-notification" false
    continue
  fi
  verdict="$(json_get "$pkg/manifest.json" verdict.verdict '?')"
  summary="$(json_get "$pkg/manifest.json" verdict.summary '')"
  source_id="$(json_get "$pkg/manifest.json" source_id '')"

  acquire_finalisation "notify:$id"
  final_rc=$?
  if [ "$final_rc" -ne 0 ]; then
    stop_claim_heartbeat
    touch "$pkg/DONE"
    mv "$pkg" "$ARCHIVE/${id}.duplicate.$(ts).$$" 2>/dev/null || true
    continue
  fi

  # 1) Human/next-session visible notice.
  {
    printf '## %s  validated: `%s`  verdict: **%s**\n' "$(iso)" "$source_id" "$verdict"
    [ -n "$summary" ] && printf '%s\n' "$summary"
    printf 'Package: `%s`\n\n' "$ARCHIVE/$(basename "$pkg")"
  } >> "$NOTICE"

  # 2) Drop a line into the optional notify file, if one is configured.
  if [ -f "$NOTIFY_INBOX" ]; then
    printf -- '- [codex-bridge %s] validated `%s` -> **%s**: %s (pkg: %s)\n' \
      "$(date +%Y-%m-%d)" "$source_id" "$verdict" "$summary" "$ARCHIVE/$(basename "$pkg")" >> "$NOTIFY_INBOX" 2>/dev/null || true
  fi

  ledger_add "notify" "notify:$id" "$verdict"
  log "claude-pickup(notify): $id verdict=$verdict"

  # 3) OPT-IN auto-triage (experimental). Reads the verdict and writes a next-step note.
  #    Does NOT modify repositories.
  if [ "$CLAUDE_AUTOPICK" = "1" ]; then
    claude -p "Codex validated work in $pkg (verdict: $verdict). Read manifest.json and verdict.json there plus the original task, then write a concise pickup-triage note to $pkg/claude-triage.md saying what to do next. Do not modify any repository." \
      > "$pkg/claude-triage.log" 2>&1 || true
  fi

  touch "$pkg/DONE"
  stop_claim_heartbeat
  mv "$pkg" "$ARCHIVE/" 2>/dev/null || true
  release_finalisation
done
