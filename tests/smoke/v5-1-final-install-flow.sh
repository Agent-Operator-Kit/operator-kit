#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/operator-v5-1-install.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT
repo="$TMP_ROOT/code/app"
mkdir -p "$repo"
git -C "$repo" init -b main >/dev/null
git -C "$repo" config user.email smoke@example.com
git -C "$repo" config user.name Smoke
printf '# smoke\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -m init >/dev/null

bash "$KIT_ROOT/scripts/operator-bootstrap.sh" "$repo" >/dev/null
grep -q 'OPERATOR_KIT_VERSION="5.1"' "$repo/operator.config.env"
test -x "$repo/scripts/operator-graph.sh"
test -f "$repo/scripts/operator_local_graph.py"
test -x "$repo/scripts/operator-v5-1-migrate.sh"
for obsolete in operator-host.sh operator-proof-broker.sh operator-loop.sh operator-v5-provision.sh; do
  test ! -e "$repo/scripts/$obsolete"
done
test ! -e "$repo/schemas/operator-v5"
OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-status.sh" > "$TMP_ROOT/status.txt"
grep -q 'Operator Kit version: 5.1' "$TMP_ROOT/status.txt"
grep -q 'no credentials required' "$TMP_ROOT/status.txt"
printf 'operator v5.1 final install smoke ok\n'
