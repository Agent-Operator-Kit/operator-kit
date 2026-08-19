#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d /tmp/operator-v5-2-update.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

repo="$tmp_root/code/app"
mkdir -p "$repo"
git -C "$repo" init -b main >/dev/null
git -C "$repo" config user.email smoke@example.com
git -C "$repo" config user.name Smoke
printf '# V5.2 update smoke\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -m init >/dev/null

# Start from a complete local-graph project and simulate its V5.1 marker.
bash "$KIT_ROOT/scripts/operator-bootstrap.sh" "$repo" >/dev/null
sed -i '' "s/OPERATOR_KIT_VERSION=\"5.2\"/OPERATOR_KIT_VERSION='5.1'/" \
  "$repo/operator.config.env"
rm -rf "$tmp_root/operator/model-selection"

bash "$KIT_ROOT/scripts/operator-update.sh" \
  --source "$KIT_ROOT" \
  --target "$repo" \
  --channel latest \
  --no-fetch > "$tmp_root/update.txt"

grep -q "OPERATOR_KIT_VERSION='5.2'" "$repo/operator.config.env"
grep -q '5.1 -> 5.2 (backward-compatible update)' "$tmp_root/update.txt"
test -f "$tmp_root/operator/model-selection/README.md"
test -f "$tmp_root/operator/model-selection/catalog.example.json"
test -f "$tmp_root/operator/model-selection/policy.example.json"
test ! -e "$tmp_root/operator/model-selection/catalog.json"
test ! -e "$tmp_root/operator/model-selection/policy.json"

OPERATOR_CONFIG="$repo/operator.config.env" \
  bash "$repo/scripts/operator-model-select.sh" setup-guide > "$tmp_root/guide.txt"
grep -q 'Models: provider/model IDs' "$tmp_root/guide.txt"
grep -q 'Evidence by task class' "$tmp_root/guide.txt"
grep -q 'User guidance' "$tmp_root/guide.txt"
grep -q 'will still not apply a model' "$tmp_root/guide.txt"

OPERATOR_CONFIG="$repo/operator.config.env" \
  bash "$repo/scripts/operator-status.sh" > "$tmp_root/status.txt"
grep -q 'Operator Kit version: 5.2' "$tmp_root/status.txt"
grep -q 'local advisory' "$tmp_root/status.txt"

printf 'operator v5.2 compatible update smoke ok\n'
