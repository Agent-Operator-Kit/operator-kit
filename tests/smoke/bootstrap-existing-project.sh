#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d /tmp/aok-smoke.XXXXXX)"
tmp_root="$(cd "$tmp_root" && pwd -P)"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/code/app"
git -C "$tmp_root/code/app" init -b main >/dev/null
printf '# Smoke\n' > "$tmp_root/code/app/README.md"
git -C "$tmp_root/code/app" add README.md
git -C "$tmp_root/code/app" commit -m 'init' >/dev/null

bash "$KIT_ROOT/scripts/operator-bootstrap.sh" "$tmp_root/code/app"

cd "$tmp_root/code/app"
bash scripts/operator-status.sh >/dev/null
task_dir="$(bash scripts/operator-task.sh smoke-001 "Smoke Task")"

test "$task_dir" = "$tmp_root/operator/tasks/smoke-001"
test -d "$tmp_root/operator/tasks/smoke-001/tasks"
test -d "$tmp_root/operator/tasks/smoke-001/handoffs"
test -f "$tmp_root/operator/README.md"
test -f "$tmp_root/code/app/scripts/operator-update.sh"
test -f "$tmp_root/code/app/.claude/commands/operator-bootstrap.md"
test -f "$tmp_root/code/app/.claude/commands/operator-status.md"
test -f "$tmp_root/code/app/.claude/agents/operator-workflow.md"
test -f "$tmp_root/code/app/.cursor/rules/operator-workflow.mdc"
test -f "$tmp_root/code/app/.cursor/skills/operator-workflow/SKILL.md"
test -f "$tmp_root/code/app/.cursor/environment.json.example"
test ! -d "$tmp_root/code/app/operator"

printf 'smoke ok: %s\n' "$tmp_root"
