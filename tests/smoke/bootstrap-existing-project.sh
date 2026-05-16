#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d /tmp/aok-smoke.XXXXXX)"
tmp_root="$(cd "$tmp_root" && pwd -P)"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/code/app"
git -C "$tmp_root/code/app" init -b main >/dev/null
git -C "$tmp_root/code/app" config user.email smoke@example.com
git -C "$tmp_root/code/app" config user.name "Smoke Test"
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
test -f "$tmp_root/operator/tasks/smoke-001/memory.md"
test -f "$tmp_root/operator/memory/project.md"
test -d "$tmp_root/operator/memory/episodes"
test -f "$tmp_root/operator/README.md"
test -f "$tmp_root/code/app/scripts/operator-memory.sh"
test -f "$tmp_root/code/app/scripts/operator-update.sh"
test -f "$tmp_root/code/app/.claude/commands/operator-bootstrap.md"
test -f "$tmp_root/code/app/.claude/commands/operator-status.md"
test -f "$tmp_root/code/app/.claude/agents/operator-workflow.md"
test -f "$tmp_root/code/app/.cursor/rules/operator-workflow.mdc"
test -f "$tmp_root/code/app/.cursor/skills/operator-workflow/SKILL.md"
test -f "$tmp_root/code/app/.cursor/environment.json.example"
test ! -d "$tmp_root/code/app/operator"

cat > "$task_dir/tasks/backend.md" <<'EOF'
## Task

Validate bootstrap memory.

## Handoff Requirements

Report memory candidates.
EOF

bash scripts/operator-memory.sh promote project "Use disposable smoke data." >/dev/null
bash scripts/operator-memory.sh promote task smoke-001 "Backend owns the bootstrap memory smoke." >/dev/null
bash scripts/operator-memory.sh pack backend smoke-001 --task-file "$task_dir/tasks/backend.md" > "$tmp_root/context-pack.md"
grep -q 'Use disposable smoke data' "$tmp_root/context-pack.md"
grep -q 'Backend owns the bootstrap memory smoke' "$tmp_root/context-pack.md"

cat > "$task_dir/handoffs/backend-capture-test.md" <<'EOF'
# backend Capture

## Handoff

Status: completed
Validation: passed

## Memory Candidates

- Durable decision: keep bootstrap memory outside the repo.
EOF

bash scripts/operator-memory.sh ingest backend smoke-001 "$task_dir/handoffs/backend-capture-test.md" >/dev/null
bash scripts/operator-memory.sh search "disposable smoke" >/dev/null
test "$(find "$tmp_root/operator/memory/episodes" -type f -name '*.md' | wc -l | tr -d ' ')" = "1"

printf 'smoke ok: %s\n' "$tmp_root"
