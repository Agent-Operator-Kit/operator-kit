#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d /tmp/aok-channel-smoke.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

stable_project="$tmp_root/stable"
latest_project="$tmp_root/latest"
mkdir -p "$stable_project" "$latest_project"

bash "$KIT_ROOT/scripts/operator-sync.sh" \
  --source "$KIT_ROOT" \
  --channel stable \
  --target "$stable_project" \
  --bootstrap-if-missing \
  --skip-skills \
  --skip-checks \
  --no-fetch >/dev/null

stable_repo="$stable_project/code/app"
grep -q 'OPERATOR_KIT_VERSION="2"' "$stable_repo/operator.config.env"
test ! -f "$stable_repo/scripts/operator-feature.sh"

bash "$KIT_ROOT/scripts/operator-sync.sh" \
  --source "$KIT_ROOT" \
  --channel latest \
  --target "$latest_project" \
  --bootstrap-if-missing \
  --skip-skills \
  --skip-checks \
  --no-fetch >/dev/null

latest_repo="$latest_project/code/app"
grep -q 'OPERATOR_KIT_VERSION="4"' "$latest_repo/operator.config.env"
test -f "$latest_repo/scripts/operator-feature.sh"
test -f "$latest_project/operator/features/active.md"

printf 'version channel smoke ok: %s\n' "$tmp_root"
