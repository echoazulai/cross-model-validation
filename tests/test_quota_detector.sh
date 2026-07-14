#!/usr/bin/env bash
# looks_like_quota_outage: tail-scoped provider-outage detector (2026-07-13 fix).
# Must catch a real outage error at the tail and IGNORE the word "quota" quoted
# mid-stream (the false positive that mis-held a package under review).
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export AI_HANDOFF_ROOT="$(mktemp -d)"
mkdir -p "$AI_HANDOFF_ROOT/logs"
# shellcheck source=/dev/null
source "$DIR/bin/lib.sh"

tmp="$(mktemp -d)"
fail=0
expect() {  # <desc> <want-rc> <file>
  looks_like_quota_outage "$3"; local got=$?
  if [ "$got" -ne "$2" ]; then echo "FAIL: $1 (want rc=$2 got rc=$got)"; fail=1; else echo "ok: $1"; fi
}

printf 'reasoning line\nERROR: Selected model is at capacity. Please try a different model.\ntokens used\n' > "$tmp/capacity.log"
expect "real 'at capacity' at tail -> outage" 0 "$tmp/capacity.log"

# The word quota appears only on line 1; 60 lines of clean reasoning push it out
# of the tail window, and the tail is a clean success.
{ printf 'The reviewed script greps for quota and rate-limit tokens.\n'
  for i in $(seq 1 60); do echo "normal reasoning line $i"; done
  printf 'verdict written\ntokens used\n'; } > "$tmp/quoted.log"
expect "mid-stream quoted 'quota' -> NOT an outage" 1 "$tmp/quoted.log"

printf 'ok\n429 Too Many Requests\n' > "$tmp/rl.log"
expect "429 at tail -> outage" 0 "$tmp/rl.log"

printf 'review complete\ntokens used\n' > "$tmp/ok.log"
expect "clean success -> NOT an outage" 1 "$tmp/ok.log"

expect "missing log file -> NOT an outage" 1 "$tmp/does-not-exist.log"

rm -rf "$tmp" "$AI_HANDOFF_ROOT"
if [ "$fail" -eq 0 ]; then echo "ALL-QUOTA-TESTS-PASSED"; else exit 1; fi
