#!/usr/bin/env bash
# VALIDATOR DIRECTION. Scans to-codex/ for ready packages and has Codex review each
# one read-only, emitting a schema-forced verdict into to-claude/. Idempotent + atomic.
source "${AI_HANDOFF_ROOT:-$HOME/ai-handoff}/bin/lib.sh"
set -uo pipefail          # NOT -e: one bad package must not kill the batch
shopt -s nullglob

for pkg in "$TO_CODEX"/*/ ; do
  pkg="${pkg%/}"
  id="$(basename "$pkg")"
  [ -f "$pkg/READY" ] || continue          # not finished being written
  [ -f "$pkg/DONE" ]  && continue
  claim_pkg "$pkg" || continue   # atomic claim with lease (S9)
  if ledger_has "$id"; then touch "$pkg/DONE"; rm -rf -- "$pkg/CLAIMED"; continue; fi
  start_claim_heartbeat "$pkg"
  log "codex-pickup: claimed $id"

  if ! "$ROOT/bin/validate-manifest.py" "$pkg/manifest.json" claude; then
    hold_package "$pkg" "invalid-manifest" false
    continue
  fi

  kind="$(json_get "$pkg/manifest.json" kind artifact)"
  criteria="$(json_get "$pkg/manifest.json" criteria '')"
  target="$(json_get "$pkg/manifest.json" target '')"
  base="$(json_get "$pkg/manifest.json" base '')"

  workroot="$pkg"; scope="the files under ./payload"; wt=""; reviewed_sha_m=""
  if [ "$kind" = "repo-diff" ] && ! repo_review_identity_valid "$pkg"; then
    hold_package "$pkg" "invalid-repository-identity" false
    continue
  fi
  if [ "$kind" = "repo-diff" ]; then
    reviewed_sha_m="$(json_get "$pkg/manifest.json" reviewed_sha '')"
    base_sha_m="$(json_get "$pkg/manifest.json" base_sha '')"
    if [ -n "$reviewed_sha_m" ]; then
      wt="$(make_review_worktree "$target" "$reviewed_sha_m" "$id")"
    fi
    if [ -n "$wt" ]; then
      # Immutable review (S4): detached checkout at the pinned SHA, not the live tree.
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

Inspect thoroughly: correctness, edge cases, and whether the work genuinely meets the
criteria. In 'checked', name the specific files/functions you actually read; this is a
structured claim, while bridge-recorded evidence remains authoritative. Include executions
as an array (empty if you ran no commands). Return ONLY the
required JSON verdict."

  # Tier -> judge model (CODEX_MODEL blanket override beats the tier map)
  tier="$(json_get "$pkg/manifest.json" tier standard)"
  case "$tier" in
    light)  judge="${CODEX_MODEL_LIGHT:-codex-light}";;
    full)   judge="${CODEX_MODEL_FULL:-codex-full}";;
    *)      judge="${CODEX_MODEL_STANDARD:-codex-standard}";;
  esac
  [ -n "$CODEX_MODEL" ] && judge="$CODEX_MODEL"
  net_flag=(); [ "${CODEX_ALLOW_NET:-0}" = "1" ] && net_flag=(-c 'sandbox_workspace_write.network_access=true')

  "${BRIDGE_CODEX_BIN:-codex}" exec -s read-only --skip-git-repo-check -m "$judge" "${net_flag[@]}" \
    -C "$workroot" --color never \
    --output-schema "$SCHEMA" -o "$pkg/verdict.json" \
    "$prompt" > "$pkg/codex-events.log" 2>&1
  rc=$?

  verdict="error"
  if [ $rc -eq 0 ] && [ -s "$pkg/verdict.json" ] \
     && "$ROOT/bin/validate-verdict.py" "$pkg/verdict.json" "$pkg/manifest.json"; then
    verdict="$(json_get "$pkg/verdict.json" verdict error)"
  fi

  # ESCALATE-ON-FAIL: a sub-full-tier fail/needs-changes is re-judged once by the full-tier
  # model before it stands. Cheap greens stay cheap; the initial verdict is retained while
  # the escalated verdict stands. Both verdicts are kept; the disagreement is catch-log signal.
  escalated=""
  full_model="${CODEX_MODEL_FULL:-codex-full}"
  if [ "${ESCALATE_ON_FAIL:-0}" = "1" ] && [ "$judge" != "$full_model" ] \
     && { [ "$verdict" = "fail" ] || [ "$verdict" = "needs-changes" ]; }; then
    mv "$pkg/verdict.json" "$pkg/verdict-initial.json"
    "${BRIDGE_CODEX_BIN:-codex}" exec -s read-only --skip-git-repo-check -m "$full_model" "${net_flag[@]}" \
      -C "$workroot" --color never \
      --output-schema "$SCHEMA" -o "$pkg/verdict.json" \
      "$prompt" >> "$pkg/codex-events.log" 2>&1
    rc=$?
    if [ $rc -eq 0 ] && [ -s "$pkg/verdict.json" ] \
       && "$ROOT/bin/validate-verdict.py" "$pkg/verdict.json" "$pkg/manifest.json"; then
      v2="$(json_get "$pkg/verdict.json" verdict error)"
      escalated="escalated(${judge}:${verdict}->${full_model}:${v2})"
      verdict="$v2"
    else
      cp "$pkg/verdict-initial.json" "$pkg/verdict.json"   # escalation failed: initial stands
      escalated="escalated-error(kept ${judge}:${verdict})"
    fi
    log "codex-pickup: $id $escalated"
  fi

  # DEGRADED MODE: a quota/auth outage is not a review failure. Hold the package for an
  # owner decision (same-family review or wait) instead of emitting a fail verdict.
  if [ "$verdict" = "error" ] && looks_like_quota_outage "$pkg/codex-events.log"; then
    drop_review_worktree "$target" "$wt"
    hold_package "$pkg" "codex-quota-or-auth" true
    log "codex-pickup: HELD $id (codex unavailable - quota/auth); owner decision needed"
    {
      printf '## %s  HELD: `%s` - Codex unavailable (quota/auth)\n' "$(iso)" "$id"
      printf 'Owner call needed: same-family (Claude) degraded review, or wait for Codex to return.\n'
      printf 'Requeue when back: `~/ai-handoff/bin/requeue-held.sh`\n\n'
    } >> "$NOTICE"
    continue
  fi

  if [ "$verdict" = "error" ]; then
    drop_review_worktree "$target" "$wt"
    hold_package "$pkg" "codex-review-error" true
    log "codex-pickup: HELD $id (judge produced no valid verdict)"
    continue
  fi

  # VERDICT GATE: a pass cannot be finalised on failed or missing check evidence.
  if [ "$verdict" = "pass" ] && ! pass_backed_by_checks "$pkg"; then
    drop_review_worktree "$target" "$wt"
    hold_package "$pkg" "pass-gated-checks-not-green" true
    log "codex-pickup: HELD $id (pass REFUSED: declared checks did not all pass)"
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

  # MERGE-ON-PASS: the verdict is the push authority; the SHA pin guarantees what merges
  # is exactly what was judged. Fast-forward only; origin rejects anything else.
  merge_note=""
  mop="$(json_get "$pkg/manifest.json" merge_on_pass false)"
  if [ "$verdict" = "pass" ] && [ "$mop" = "true" ]; then
    {
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
          # best-effort local sync of <base>; never disturb a dirty or diverged tree
          cur="$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null)"
          if [ "$cur" = "$base" ] && [ -z "$(git -C "$target" status --porcelain)" ]; then
            git -C "$target" merge -q --ff-only "$reviewed_sha" 2>/dev/null || true
          elif [ "$cur" != "$base" ]; then
            git -C "$target" fetch -q . "$reviewed_sha:refs/heads/$base" 2>/dev/null || true
          fi
        else
          merge_note="merge-FAILED(push)"
        fi
      else
        merge_note="merge-BLOCKED(stale: branch moved since review)"
      fi
      log "codex-pickup: $id merge-on-pass -> $merge_note"
    }
  fi

  # Hand the verdict to the Claude side.
  out="$TO_CLAUDE/${id}-verdict"
  mkdir -p "$out"
  python3 - "$pkg" "$out" "$id" "$verdict" <<'PY'
import json, os, sys
src, out, sid, verdict = sys.argv[1:5]
def load(p, d):
    try: return json.load(open(p))
    except Exception: return d
man = load(os.path.join(src, "manifest.json"), {})
vj  = load(os.path.join(src, "verdict.json"),
           {"verdict": verdict, "summary": "Codex produced no valid verdict; see codex-events.log",
            "findings": [], "checked": ""})
json.dump({"source_id": sid, "source_manifest": man, "verdict": vj},
          open(os.path.join(out, "manifest.json"), "w"), indent=2)
PY
  cp -f "$pkg/verdict.json"         "$out/verdict.json"         2>/dev/null || true
  cp -f "$pkg/verdict-initial.json" "$out/verdict-initial.json" 2>/dev/null || true
  cp -f "$pkg/codex-events.log"     "$out/codex-events.log"     2>/dev/null || true
  touch "$out/READY"

  [ -n "$merge_note" ] && echo "$merge_note" > "$out/merge.txt"
  ledger_add "codex-review" "$id" "${verdict}[judge=$judge tier=$tier]${escalated:+ ${escalated}}${merge_note:+ ${merge_note}}"
  log "codex-pickup: $id -> $verdict (judge=$judge, rc=$rc)"
  touch "$pkg/DONE"
  stop_claim_heartbeat
  mv "$pkg" "$ARCHIVE/" 2>/dev/null || true
  release_finalisation
done
