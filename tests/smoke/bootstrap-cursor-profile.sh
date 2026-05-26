#!/usr/bin/env bash
set -euo pipefail

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

bash "$KIT_ROOT/scripts/operator-bootstrap.sh" --profile cursor "$tmp_root/code/app"

cd "$tmp_root/code/app"
bash -n scripts/*.sh
grep -q 'operator|Cursor IDE|app|main|' operator.config.env
grep -q 'cursor|Cursor CLI|app-cursor|cursor/operator|cursor agent' operator.config.env
grep -q 'ui|Claude Code|app-ui|claude/ui|' operator.config.env
if grep -q 'Codex CLI' operator.config.env; then
  printf 'Cursor profile should not generate Codex CLI lanes.\n' >&2
  exit 1
fi

test -f ".cursor/rules/operator-workflow.mdc"
test -f ".cursor/skills/operator-workflow/SKILL.md"
test -f ".cursor/environment.json.example"
bash scripts/operator-status.sh >/dev/null
bash scripts/operator-memory.sh status >/dev/null

printf 'cursor profile smoke ok: %s\n' "$tmp_root"
