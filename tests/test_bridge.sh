#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export AI_HANDOFF_ROOT="$TEST_ROOT/bridge"
mkdir -p "$AI_HANDOFF_ROOT"/{to-codex,to-claude,archive,logs,held}
touch "$AI_HANDOFF_ROOT/ledger.log" "$AI_HANDOFF_ROOT/NOTICE-validated-work.md"
cp "$REPO_ROOT/verdict.schema.json" "$AI_HANDOFF_ROOT/verdict.schema.json"
cp -r "$REPO_ROOT/bin" "$AI_HANDOFF_ROOT/"
cat > "$TEST_ROOT/fake-bwrap" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
workroot=""
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = "--bind" ] && [ "${args[$((i+2))]}" = "/work" ]; then
    workroot="${args[$((i+1))]}"
  fi
done
[ -n "$workroot" ]
cd "$workroot"
exec bash -lc "${args[-1]}"
SH
chmod +x "$TEST_ROOT/fake-bwrap"
export BRIDGE_BWRAP="${BRIDGE_BWRAP:-$TEST_ROOT/fake-bwrap}"

# shellcheck source=../bin/lib.sh
source "$AI_HANDOFF_ROOT/bin/lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail() { "$@" >/dev/null 2>&1 && fail "command unexpectedly passed: $*" || true; }

test_claim_recovery() {
  local pkg="$TEST_ROOT/lease-pkg"
  mkdir -p "$pkg/CLAIMED"
  printf 'dead-worker\n' > "$pkg/CLAIMED/worker"
  touch -d '46 minutes ago' "$pkg/CLAIMED" "$pkg/CLAIMED/worker"
  claim_pkg "$pkg" || fail "expired claim was not reclaimed"
  [ -s "$pkg/CLAIMED/worker" ] || fail "new worker record missing"
}

test_drop_validation_and_identity() {
  local repo="$TEST_ROOT/repo"
  git init -q -b main "$repo"
  git -C "$repo" config user.name Test
  git -C "$repo" config user.email test@example.invalid
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m base
  git -C "$repo" switch -q -c codex/test
  printf 'change\n' >> "$repo/file.txt"
  git -C "$repo" commit -qam change
  printf 'sidecar\n' > "$repo/generated.tmp"

  expect_fail "$AI_HANDOFF_ROOT/bin/drop-for-claude.sh" '../escape' --payload "$repo/file.txt"
  expect_fail "$AI_HANDOFF_ROOT/bin/drop-for-claude.sh" bad-kind --kind nonsense --payload "$repo/file.txt"
  expect_fail "$AI_HANDOFF_ROOT/bin/drop-for-claude.sh" no-base --kind repo-diff --target "$repo"
  expect_fail "$AI_HANDOFF_ROOT/bin/drop-for-claude.sh" full-auto --kind repo-diff --target "$repo" --base main --tier full --merge-on-pass
  expect_fail "$AI_HANDOFF_ROOT/bin/drop-for-claude.sh" artifact-auto --kind artifact --merge-on-pass --payload "$repo/file.txt"

  local pkg
  pkg="$($AI_HANDOFF_ROOT/bin/drop-for-claude.sh identity --kind repo-diff --target "$repo" --base main --tier standard --criteria test)"
  python3 - "$pkg/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["base_sha"]
assert m["reviewed_sha"]
assert m["branch"] == "codex/test"
assert m["untracked_files"] == ["generated.tmp"]
PY

  local base_commit sha_pkg
  base_commit="$(git -C "$repo" rev-parse main)"
  sha_pkg="$($AI_HANDOFF_ROOT/bin/drop-for-claude.sh sha-base --kind repo-diff --target "$repo" --base "$base_commit" --tier standard --criteria test)"
  [ "$(json_get "$sha_pkg/manifest.json" base_sha '')" = "$base_commit" ] || fail "full-SHA base did not resolve to exactly one commit SHA"
  expect_fail "$AI_HANDOFF_ROOT/bin/drop-for-codex.sh" multiline-base --kind repo-diff --target "$repo" --base $'main\nmain' --criteria test

  printf 'dirty\n' >> "$repo/file.txt"
  local before after
  before="$(find "$AI_HANDOFF_ROOT/to-claude" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  expect_fail "$AI_HANDOFF_ROOT/bin/drop-for-claude.sh" dirty --kind repo-diff --target "$repo" --base main
  after="$(find "$AI_HANDOFF_ROOT/to-claude" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  [ "$before" = "$after" ] || fail "failed drop left an incomplete queue directory"
}

test_fail_closed_payload_copy() {
  local before after
  before="$(find "$AI_HANDOFF_ROOT/to-codex" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  expect_fail "$AI_HANDOFF_ROOT/bin/drop-for-codex.sh" missing --payload "$TEST_ROOT/does-not-exist"
  after="$(find "$AI_HANDOFF_ROOT/to-codex" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  [ "$before" = "$after" ] || fail "copy failure left an incomplete queue directory"
}

test_artifact_payload_hash() {
  local payload="$TEST_ROOT/payload"
  mkdir -p "$payload/empty"
  printf 'alpha\n' > "$payload/a.txt"
  ln -s a.txt "$payload/link"
  local pkg first_hash second_hash
  pkg="$($AI_HANDOFF_ROOT/bin/drop-for-codex.sh hash-test --kind artifact --criteria hash --payload "$payload")"
  first_hash="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["payload_sha256"])' "$pkg/manifest.json")"
  [ -n "$first_hash" ] || fail "payload hash missing"
  python3 - "$pkg/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
types = {entry["path"]: entry["type"] for entry in m["payload_files"]}
assert types["payload/a.txt"] == "file"
assert types["payload/empty"] == "directory"
assert types["payload/link"] == "symlink"
PY
  "$AI_HANDOFF_ROOT/bin/hash-payload.py" "$pkg/manifest.json" "$pkg/payload"
  second_hash="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["payload_sha256"])' "$pkg/manifest.json")"
  [ "$first_hash" = "$second_hash" ] || fail "payload hash is not deterministic"
}

test_hash_failure_blocks_ready() {
  local payload="$TEST_ROOT/unsupported-payload"
  mkdir -p "$payload"
  mkfifo "$payload/pipe"
  local before after
  before="$(find "$AI_HANDOFF_ROOT/to-codex" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  expect_fail "$AI_HANDOFF_ROOT/bin/drop-for-codex.sh" fifo --kind artifact --criteria hash --payload "$payload"
  after="$(find "$AI_HANDOFF_ROOT/to-codex" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  [ "$before" = "$after" ] || fail "hash failure published or retained a package"
}

test_immutable_worktree_helpers() {
  local repo="$TEST_ROOT/worktree-repo" wt
  git init -q -b main "$repo"
  git -C "$repo" config user.name Test
  git -C "$repo" config user.email test@example.invalid
  printf 'content\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m base
  mkdir -p "$WORKTREES/stale-id"
  printf 'stale\n' > "$WORKTREES/stale-id/junk"
  wt="$(make_review_worktree "$repo" "$(git -C "$repo" rev-parse HEAD)" stale-id)"
  [ -n "$wt" ] && [ ! -e "$wt/junk" ] || fail "stale worktree was not safely recreated"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$repo" rev-parse HEAD)" ] || fail "worktree identity mismatch"
  drop_review_worktree "$repo" "$wt"
  git -C "$repo" worktree add --detach -q "$WORKTREES/registered-id" HEAD
  wt="$(make_review_worktree "$repo" "$(git -C "$repo" rev-parse HEAD)" registered-id)"
  [ -n "$wt" ] || fail "registered stale worktree was not recovered"
  drop_review_worktree "$repo" "$wt"
  [ -z "$(make_review_worktree "$repo" deadbeef invalid-id)" ] || fail "invalid SHA unexpectedly created a worktree"
  ! grep -q 'live-tree fallback' "$REPO_ROOT/bin/codex-pickup.sh" "$REPO_ROOT/bin/claude-pickup.sh" || fail "live-tree fallback remains"
}

test_direction_aware_requeue() {
  local codex_pkg="$AI_HANDOFF_ROOT/held/codex-authored"
  local claude_pkg="$AI_HANDOFF_ROOT/held/claude-authored"
  mkdir -p "$codex_pkg/CLAIMED" "$claude_pkg/CLAIMED"
  printf worker > "$codex_pkg/CLAIMED/worker"
  printf worker > "$claude_pkg/CLAIMED/worker"
  printf '{"created_by":"codex"}\n' > "$codex_pkg/manifest.json"
  printf '{"created_by":"claude"}\n' > "$claude_pkg/manifest.json"
  printf '{"retryable":true,"direction":"to-claude"}\n' > "$codex_pkg/HELD.json"
  printf '{"retryable":true,"direction":"to-codex"}\n' > "$claude_pkg/HELD.json"
  "$AI_HANDOFF_ROOT/bin/requeue-held.sh" >/dev/null
  [ -d "$AI_HANDOFF_ROOT/to-claude/codex-authored" ] || fail "Codex-authored package requeued to wrong lane"
  [ -d "$AI_HANDOFF_ROOT/to-codex/claude-authored" ] || fail "Claude-authored package requeued to wrong lane"
  [ ! -e "$AI_HANDOFF_ROOT/to-claude/codex-authored/CLAIMED" ] || fail "Codex package retained stale claim"
  [ ! -e "$AI_HANDOFF_ROOT/to-codex/claude-authored/CLAIMED" ] || fail "Claude package retained stale claim"
}

test_held_fail_closed_and_collision() {
  local permanent="$AI_HANDOFF_ROOT/held/permanent"
  local malformed="$AI_HANDOFF_ROOT/held/malformed"
  local collision="$AI_HANDOFF_ROOT/held/collision"
  mkdir -p "$permanent" "$malformed" "$collision" "$AI_HANDOFF_ROOT/to-codex/collision"
  printf '{"retryable":false,"direction":"to-codex"}\n' > "$permanent/HELD.json"
  printf '{"retryable":true,"direction":"sideways"}\n' > "$malformed/HELD.json"
  printf '{"retryable":true,"direction":"to-codex"}\n' > "$collision/HELD.json"
  local output
  output="$($AI_HANDOFF_ROOT/bin/requeue-held.sh)"
  [ -d "$permanent" ] || fail "non-retryable package was requeued"
  [ -d "$malformed" ] || fail "malformed held direction was requeued"
  [ -d "$collision" ] || fail "held package overwrote a queue collision"
  printf '%s' "$output" | grep -q 're-drop required: 1 package' || fail "requeue did not tell the operator that a fresh drop is required"
}

test_manifest_and_verdict_validation() {
  local manifest="$TEST_ROOT/manifest.json" verdict="$TEST_ROOT/verdict.json"
  cat > "$manifest" <<'JSON'
{"id":"x","kind":"repo-diff","target":"/tmp/repo","base":"main","branch":"codex/x","criteria":"test","created_by":"codex","tier":"standard","merge_on_pass":false,"reviewed_sha":"deadbeef","base_sha":"deadbeef","untracked_at_drop":false,"untracked_files":[],"checks":[]}
JSON
  expect_fail "$AI_HANDOFF_ROOT/bin/validate-manifest.py" "$manifest" codex
  cat > "$manifest" <<'JSON'
{"id":"x","kind":"repo-diff","target":"/tmp/repo","base":"main","branch":"codex/x","criteria":"test","created_by":"codex","tier":"standard","merge_on_pass":false,"reviewed_sha":"1111111111111111111111111111111111111111","base_sha":"2222222222222222222222222222222222222222","untracked_at_drop":false,"untracked_files":[],"checks":[]}
JSON
  cat > "$verdict" <<'JSON'
{"verdict":"pass","summary":"ok","findings":[],"checked":"files","executions":[],"reviewed_identity":{"kind":"repo-diff","base_sha":"2222222222222222222222222222222222222222","reviewed_sha":"3333333333333333333333333333333333333333","payload_sha256":null}}
JSON
  expect_fail "$AI_HANDOFF_ROOT/bin/validate-verdict.py" "$verdict" "$manifest"
  python3 - "$verdict" <<'PY'
import json, sys
p=sys.argv[1]; o=json.load(open(p)); o["reviewed_identity"]["reviewed_sha"]="1"*40; o["invented"]=True
json.dump(o, open(p,"w"))
PY
  expect_fail "$AI_HANDOFF_ROOT/bin/validate-verdict.py" "$verdict" "$manifest"
  python3 - "$verdict" <<'PY'
import json, sys
p=sys.argv[1]; o=json.load(open(p)); o.pop("invented")
json.dump(o, open(p,"w"))
PY
  "$AI_HANDOFF_ROOT/bin/validate-verdict.py" "$verdict" "$manifest" || fail "valid strict repo verdict rejected"
}

test_response_schema_strictness() {
  local broken="$TEST_ROOT/broken-schema.json"
  "$AI_HANDOFF_ROOT/bin/validate-response-schema.py" "$AI_HANDOFF_ROOT/verdict.schema.json" || fail "Codex response schema is not strict-compatible"
  python3 - "$AI_HANDOFF_ROOT/verdict.schema.json" "$broken" <<'PY'
import json, sys
o=json.load(open(sys.argv[1]))
o["properties"]["reviewed_identity"]["required"]=["kind"]
json.dump(o, open(sys.argv[2], "w"))
PY
  expect_fail "$AI_HANDOFF_ROOT/bin/validate-response-schema.py" "$broken"
}

test_declared_checks_and_payload_mutation() {
  local payload="$TEST_ROOT/check-payload" pkg
  mkdir -p "$payload"
  printf 'alpha\n' > "$payload/value.txt"
  pkg="$($AI_HANDOFF_ROOT/bin/drop-for-codex.sh check-pass --check 'test -f payload/check-payload/value.txt' --check 'printf evidence' --payload "$payload")"
  run_package_checks "$pkg" artifact '' '' check-pass || fail "check runner failed"
  checks_all_passed "$pkg" || fail "passing declared checks were not recorded as passing"
  python3 - "$pkg/check-results.json" <<'PY'
import json, pathlib, sys
o=json.load(open(sys.argv[1])); assert len(o["results"]) == 2
assert o["results"][1]["stdout"] == "evidence"
assert len(o["results"][1]["log_sha256"]) == 64
assert (pathlib.Path(sys.argv[1]).parent / o["results"][1]["log_path"]).is_file()
PY
  printf 'mutated\n' > "$pkg/payload/check-payload/value.txt"
  expect_fail "$AI_HANDOFF_ROOT/bin/verify-payload.py" "$pkg/manifest.json" "$pkg/payload"

  pkg="$($AI_HANDOFF_ROOT/bin/drop-for-codex.sh check-fail --check 'exit 7' --payload "$payload")"
  run_package_checks "$pkg" artifact '' '' check-fail || fail "runner transport failed for a failing check"
  ! checks_all_passed "$pkg" || fail "failing check was recorded as passing"
}

test_real_sandbox_has_no_external_route() {
  [ "$(basename "$BRIDGE_BWRAP")" = "bwrap" ] || return 0
  local payload="$TEST_ROOT/network-payload" pkg
  mkdir -p "$payload"
  printf 'network test\n' > "$payload/input.txt"
  pkg="$($AI_HANDOFF_ROOT/bin/drop-for-codex.sh network-isolation --check "awk 'NR > 1 { exit 1 }' /proc/net/route" --payload "$payload")"
  run_package_checks "$pkg" artifact '' '' network-isolation || fail "network-isolation runner failed"
  checks_all_passed "$pkg" || fail "real Bubblewrap sandbox retained an external network route"
}

test_finalisation_lock() {
  acquire_finalisation lock-test || fail "first finalisation lock failed"
  ledger_add test lock-test complete
  release_finalisation
  set +e
  acquire_finalisation lock-test
  local rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "completed package was not rejected by finalisation gate"
}

test_notification_validation() {
  local note="$TEST_ROOT/notification.json"
  printf '%s\n' '{"source_id":"source","source_manifest":{},"verdict":{"verdict":"pass","summary":"ok"}}' > "$note"
  "$AI_HANDOFF_ROOT/bin/validate-notification.py" "$note" || fail "valid notification rejected"
  printf '%s\n' '{"source_id":"source","source_manifest":{},"verdict":{"verdict":"perhaps","summary":"ok"}}' > "$note"
  expect_fail "$AI_HANDOFF_ROOT/bin/validate-notification.py" "$note"
}

test_invalid_judge_output_is_retryable_not_notified() {
  local error_root="$TEST_ROOT/error-bridge" payload="$TEST_ROOT/error-payload" pkg
  mkdir -p "$error_root"/{to-codex,to-claude,archive,logs,held} "$payload"
  touch "$error_root/ledger.log" "$error_root/NOTICE-validated-work.md"
  cp "$REPO_ROOT/verdict.schema.json" "$error_root/verdict.schema.json"
  cp -r "$REPO_ROOT/bin" "$error_root/"
  printf 'review me\n' > "$payload/input.txt"
  pkg="$(AI_HANDOFF_ROOT="$error_root" "$error_root/bin/drop-for-codex.sh" invalid-codex --criteria test --payload "$payload")"
  BRIDGE_CODEX_BIN=/bin/false AI_HANDOFF_ROOT="$error_root" "$error_root/bin/codex-pickup.sh" >/dev/null 2>&1
  [ "$(json_get "$error_root/held/$(basename "$pkg")/HELD.json" retryable false)" = "true" ] || fail "Codex runtime error was not held retryably"
  [ "$(json_get "$error_root/held/$(basename "$pkg")/HELD.json" action '')" = "retry" ] || fail "retryable hold action is missing"
  [ -z "$(find "$error_root/to-claude" -mindepth 1 -maxdepth 1 -type d -print -quit)" ] || fail "Codex runtime error emitted a notification"

  pkg="$(AI_HANDOFF_ROOT="$error_root" "$error_root/bin/drop-for-claude.sh" invalid-claude --criteria test --payload "$payload")"
  BRIDGE_CLAUDE_BIN=/bin/false AI_HANDOFF_ROOT="$error_root" "$error_root/bin/claude-pickup.sh" >/dev/null 2>&1
  [ "$(json_get "$error_root/held/$(basename "$pkg")/HELD.json" retryable false)" = "true" ] || fail "Claude runtime error was not held retryably"
}

test_reviewed_deployer() {
  local live="$TEST_ROOT/deployed-live" head
  git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  mkdir -p "$live/to-codex"
  printf 'queue data\n' > "$live/to-codex/preserved"
  AI_HANDOFF_ROOT="$live" "$REPO_ROOT/bin/deploy-reviewed.sh" "$head" >/dev/null
  [ "$(cat "$live/DEPLOYED_COMMIT")" = "$head" ] || fail "deployer recorded the wrong commit"
  [ -x "$live/bin/poll.sh" ] || fail "deployer omitted operational scripts"
  [ -f "$live/to-codex/preserved" ] || fail "deployer touched runtime queue data"
  expect_fail env AI_HANDOFF_ROOT="$live" "$REPO_ROOT/bin/deploy-reviewed.sh" HEAD~1
}

test_invalid_repo_identity() {
  local pkg="$TEST_ROOT/invalid-repo-package"
  mkdir -p "$pkg"
  printf '{"kind":"repo-diff","target":"","reviewed_sha":"","base_sha":""}\n' > "$pkg/manifest.json"
  ! repo_review_identity_valid "$pkg" || fail "invalid repository identity accepted"
}

test_claim_recovery
test_drop_validation_and_identity
test_fail_closed_payload_copy
test_artifact_payload_hash
test_hash_failure_blocks_ready
test_immutable_worktree_helpers
test_direction_aware_requeue
test_held_fail_closed_and_collision
test_manifest_and_verdict_validation
test_response_schema_strictness
test_declared_checks_and_payload_mutation
test_real_sandbox_has_no_external_route
test_finalisation_lock
test_notification_validation
test_invalid_judge_output_is_retryable_not_notified
test_reviewed_deployer
test_invalid_repo_identity
printf 'PASS: bridge trust-boundary tests\n'
