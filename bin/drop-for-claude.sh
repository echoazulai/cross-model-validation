#!/usr/bin/env bash
# Mirror of drop-for-codex.sh: create a work package for CLAUDE to validate.
# Codex sessions (or the owner) call this after authoring work.
#
# Usage:
#   drop-for-claude.sh <slug> [--kind artifact|repo-diff] [--target DIR] [--base REF]
#                      [--tier light|standard|full] [--merge-on-pass]
#                      [--criteria "text" | --criteria-file FILE] [--payload PATH ...]
#
# Same protocol as the Codex lane: SHA pinned at drop, READY written last, verdicts
# schema-forced, merge-on-pass fast-forwards the judged SHA only.
source "${AI_HANDOFF_ROOT:-$HOME/ai-handoff}/bin/lib.sh"
set -uo pipefail

slug="${1:?slug required}"; shift || true
kind="artifact"; target=""; base=""; criteria=""; payload=(); checks=(); check_deps=(); check_timeout=300; merge_on_pass="false"; tier="standard"
case "$slug" in *[!A-Za-z0-9._-]*|'') echo "bad slug: use letters, digits, dot, underscore, or hyphen" >&2; exit 1;; esac
while [ $# -gt 0 ]; do
  case "$1" in
    --kind)          kind="$2"; shift 2;;
    --tier)          tier="$2"; shift 2;;
    --target)        target="$2"; shift 2;;
    --base)          base="$2"; shift 2;;
    --merge-on-pass) merge_on_pass="true"; shift;;
    --criteria)      criteria="$2"; shift 2;;
    --criteria-file) criteria="$(cat "$2")"; shift 2;;
    --check)         checks+=("$2"); shift 2;;
    --check-dep)     check_deps+=("$2"); shift 2;;   # ro host path the sandbox exposes (e.g. a venv)
    --check-timeout) check_timeout="$2"; shift 2;;
    --payload)       shift; payload+=("$@"); break;;
    *)               echo "unknown argument: $1" >&2; exit 1;;
  esac
done
for dep in "${check_deps[@]:-}"; do
  [ -z "$dep" ] && continue
  case "$dep" in /) echo "bad --check-dep: '/' is not allowed" >&2; exit 1;;
                 /*) ;; *) echo "bad --check-dep: must be an absolute path: $dep" >&2; exit 1;; esac
  case "$dep" in *..*) echo "bad --check-dep: no '..' allowed: $dep" >&2; exit 1;; esac
done
if [ -z "$criteria" ] && [ ! -t 0 ]; then criteria="$(cat)"; fi
case "$tier" in light|standard|full) ;; *) echo "bad --tier: $tier" >&2; exit 1;; esac
case "$kind" in artifact|repo-diff) ;; *) echo "bad kind: $kind" >&2; exit 1;; esac
[ "$kind" != "artifact" ] || [ "$merge_on_pass" != "true" ] || { echo "artifact cannot use merge-on-pass" >&2; exit 1; }
case "$check_timeout" in ''|*[!0-9]*) echo "bad --check-timeout" >&2; exit 1;; esac
[ "$check_timeout" -ge 1 ] && [ "$check_timeout" -le 3600 ] || { echo "--check-timeout must be 1..3600 seconds" >&2; exit 1; }

id="req-$(ts)-$$-${slug}"
dir="$TO_CLAUDE/$id"
mkdir "$dir" || { echo "package id collision: $dir" >&2; exit 1; }
complete=0
trap '[ "$complete" -eq 1 ] || rm -rf -- "$dir"' EXIT
mkdir "$dir/payload"
for p in "${payload[@]:-}"; do
  if [ -n "$p" ]; then
    cp -r "$p" "$dir/payload/" || { echo "payload copy FAILED: $p - aborting submission" >&2; rm -rf "$dir"; exit 1; }
  fi
done

branch=""; reviewed_sha=""; base_sha=""; untracked_note=""
if [ "$kind" = "repo-diff" ]; then
  [ -n "$target" ] && git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || { echo "repo-diff needs a Git --target" >&2; exit 1; }
  [ -n "$base" ] || { echo "repo-diff needs --base" >&2; exit 1; }
  # S2 authoring discipline: tracked modifications mean the commit does not contain the
  # work being claimed - refuse. Untracked files are permitted but recorded.
  if [ -n "$(git -C "$target" status --porcelain | grep -v '^??')" ]; then
    echo "refused: $target has uncommitted tracked changes - commit before dropping" >&2; exit 1
  fi
  untracked_note="$(git -C "$target" status --porcelain | grep -c '^??' || true)"
  branch="$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  reviewed_sha="$(git -C "$target" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$base" ] && base_sha="$(git -C "$target" rev-parse --verify --end-of-options "${base}^{commit}" 2>/dev/null || true)"
  [ -n "$reviewed_sha" ] && [ -n "$base_sha" ] && [ "$branch" != "HEAD" ] || { echo "repo-diff needs resolvable branch HEAD and base" >&2; exit 1; }
  if [ "$merge_on_pass" = "true" ] && [ "$tier" = "full" ]; then echo "Full-tier work requires owner acceptance; merge-on-pass refused" >&2; exit 1; fi
fi

python3 - "$dir/manifest.json" "$id" "$kind" "$target" "$base" "$criteria" "$merge_on_pass" "$branch" "$reviewed_sha" "$tier" "$base_sha" "$untracked_note" <<'PY'
import json, sys
p, id_, kind, target, base, criteria, mop, branch, sha, tier, base_sha, untracked = sys.argv[1:13]
json.dump({"id": id_, "kind": kind, "target": target, "base": base,
           "criteria": criteria, "created_by": "codex", "tier": tier,
           "merge_on_pass": mop == "true", "branch": branch, "reviewed_sha": sha,
           "base_sha": base_sha, "untracked_at_drop": untracked},
          open(p, "w"), indent=2)
PY

python3 - "$dir/manifest.json" "$check_timeout" "${checks[@]}" <<'PY'
import json, sys
p, timeout, *commands = sys.argv[1:]
obj = json.load(open(p))
obj["checks"] = [{"command": command, "timeout_seconds": int(timeout)} for command in commands]
with open(p, "w") as f:
    json.dump(obj, f, indent=2)
PY

if [ "${#check_deps[@]}" -gt 0 ]; then
python3 - "$dir/manifest.json" "${check_deps[@]}" <<'PY'
import json, sys
p, *deps = sys.argv[1:]
obj = json.load(open(p))
obj["check_deps"] = deps
with open(p, "w") as f:
    json.dump(obj, f, indent=2)
PY
fi

if [ "$kind" = "repo-diff" ]; then
  python3 - "$dir/manifest.json" "$target" <<'PY'
import json, subprocess, sys
p, target = sys.argv[1:3]
raw = subprocess.check_output(["git", "-C", target, "ls-files", "--others", "--exclude-standard", "-z"])
obj = json.load(open(p))
obj["untracked_files"] = [x.decode("utf-8", "surrogateescape") for x in raw.split(b"\0") if x]
with open(p, "w") as f:
    json.dump(obj, f, indent=2)
PY
fi

if [ "$kind" = "artifact" ]; then
  if ! "$ROOT/bin/hash-payload.py" "$dir/manifest.json" "$dir/payload"; then
    echo "payload hashing FAILED - aborting submission" >&2
    exit 1
  fi
fi

touch "$dir/READY"
complete=1
trap - EXIT
log "drop-for-claude: created $id (kind=$kind tier=$tier)"
echo "$dir"
