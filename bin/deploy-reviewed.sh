#!/usr/bin/env bash
# Deploy an exact, reviewed Git commit into the live bridge without touching queues or logs.
set -euo pipefail

repo="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
root="${AI_HANDOFF_ROOT:-$HOME/ai-handoff}"
expected="${1:?usage: deploy-reviewed.sh REVIEWED_COMMIT}"
head="$(git -C "$repo" rev-parse HEAD)"
[ "$head" = "$(git -C "$repo" rev-parse "$expected^{commit}")" ] || {
  echo "refusing deployment: HEAD is not the reviewed commit" >&2; exit 1;
}
[ -z "$(git -C "$repo" status --porcelain)" ] || {
  echo "refusing deployment: source repository is dirty" >&2; exit 1;
}

stamp="$(date +%Y%m%dT%H%M%S)"
backup="$root/backups/deploy-$stamp-pre-${head:0:12}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
git -C "$repo" archive "$head" | tar -x -C "$stage"
mkdir -p "$backup" "$root/bin" "$root/tests"
for path in README.md CONTRACT.md verdict.schema.json bin tests; do
  [ ! -e "$root/$path" ] || cp -a -- "$root/$path" "$backup/"
done
rsync -a --delete -- "$stage/bin/" "$root/bin/"
rsync -a --delete -- "$stage/tests/" "$root/tests/"
cp -a -- "$stage/README.md" "$stage/CONTRACT.md" "$stage/verdict.schema.json" "$root/"
printf '%s\n' "$head" > "$root/DEPLOYED_COMMIT"
printf 'deployed %s; backup %s\n' "$head" "$backup"
