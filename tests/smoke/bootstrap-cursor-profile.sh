#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d /tmp/aok-cursor-smoke.XXXXXX)"
tmp_root="$(cd "$tmp_root" && pwd -P)"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/code/app"
git -C "$tmp_root/code/app" init -b main >/dev/null
git -C "$tmp_root/code/app" config user.email smoke@example.com
git -C "$tmp_root/code/app" config user.name "Smoke Test"
printf '# Cursor Smoke\n' > "$tmp_root/code/app/README.md"
git -C "$tmp_root/code/app" add README.md
git -C "$tmp_root/code/app" commit -m 'init' >/dev/null
mkdir -p "$tmp_root/code/app/.cursor/skills/product-manager"
printf '# Legacy Product Manager\n' > "$tmp_root/code/app/.cursor/skills/product-manager/SKILL.md"

bash "$KIT_ROOT/scripts/operator-bootstrap.sh" --profile cursor "$tmp_root/code/app"

cd "$tmp_root/code/app"
bash -n scripts/*.sh
grep -q 'operator|Cursor IDE|app|main|' operator.config.env
grep -q 'cursor|Cursor CLI|app-cursor|cursor/operator|cursor agent' operator.config.env
grep -q 'ui|Claude Code|app-ui|claude/ui|' operator.config.env
grep -q 'OPERATOR_KIT_VERSION="2"' operator.config.env
if grep -q 'Codex CLI' operator.config.env; then
  printf 'Cursor profile should not generate Codex CLI lanes.\n' >&2
  exit 1
fi

test -f ".cursor/rules/operator-workflow.mdc"
for cursor_skill in operator-workflow operator operator-planner operator-feedback design-agent incubation ux-auditor user-journey; do
  test -f ".cursor/skills/$cursor_skill/SKILL.md"
done
test ! -e ".cursor/skills/product-manager"
test -f ".cursor/environment.json.example"
test -f "scripts/operator-catalog.sh"
test -f "scripts/operator-system-map.sh"
test -f "scripts/operator-recommend-lanes.sh"
test -f "scripts/operator-plan-batch.sh"
bash scripts/operator-status.sh >/dev/null
bash scripts/operator-memory.sh status >/dev/null
bash scripts/operator-catalog.sh list roles | grep -q provider-integration
bash scripts/operator-recommend-lanes.sh >/dev/null
bash scripts/operator-plan-batch.sh >/dev/null

printf 'cursor profile smoke ok: %s\n' "$tmp_root"
