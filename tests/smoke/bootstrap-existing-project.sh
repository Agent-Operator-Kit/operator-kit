#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

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
mkdir -p "$tmp_root/code/app/.cursor/skills/product-manager"
printf '# Legacy Product Manager\n' > "$tmp_root/code/app/.cursor/skills/product-manager/SKILL.md"

bash "$KIT_ROOT/scripts/operator-bootstrap.sh" "$tmp_root/code/app"

cd "$tmp_root/code/app"
bash scripts/operator-status.sh >/dev/null
task_dir="$(bash scripts/operator-task.sh smoke-001 "Smoke Task")"

test "$task_dir" = "$tmp_root/operator/tasks/smoke-001"
test -d "$tmp_root/operator/tasks/smoke-001/tasks"
test -d "$tmp_root/operator/tasks/smoke-001/handoffs"
test -d "$tmp_root/operator/tasks/smoke-001/work"
test -f "$tmp_root/operator/tasks/smoke-001/memory.md"
test -f "$tmp_root/operator/memory/project.md"
test -d "$tmp_root/operator/memory/episodes"
test -d "$tmp_root/operator/features"
test -f "$tmp_root/operator/features/README.md"
test -f "$tmp_root/operator/features/active.md"
test -f "$tmp_root/operator/README.md"
test -f "$tmp_root/code/app/scripts/operator-memory.sh"
test -f "$tmp_root/code/app/scripts/operator-feature.sh"
test -f "$tmp_root/code/app/scripts/operator-conflicts.sh"
test -f "$tmp_root/code/app/scripts/operator-sync.sh"
test -f "$tmp_root/code/app/scripts/operator-update.sh"
test -f "$tmp_root/code/app/scripts/operator-upgrade.sh"
test -f "$tmp_root/code/app/scripts/operator-catalog.sh"
test -f "$tmp_root/code/app/scripts/operator-system-map.sh"
test -f "$tmp_root/code/app/scripts/operator-recommend-lanes.sh"
test -f "$tmp_root/code/app/scripts/operator-plan-batch.sh"
grep -q 'OPERATOR_KIT_VERSION="4"' "$tmp_root/code/app/operator.config.env"
test -f "$tmp_root/code/app/.claude/commands/operator-bootstrap.md"
test -f "$tmp_root/code/app/.claude/commands/operator-status.md"
test -f "$tmp_root/code/app/.claude/agents/operator-workflow.md"
test -f "$tmp_root/code/app/.cursor/rules/operator-workflow.mdc"
for cursor_skill in operator-workflow operator operator-planner operator-feedback design-agent incubation ux-auditor user-journey; do
  test -f "$tmp_root/code/app/.cursor/skills/$cursor_skill/SKILL.md"
done
test ! -e "$tmp_root/code/app/.cursor/skills/product-manager"
test -f "$tmp_root/code/app/.cursor/environment.json.example"
test ! -d "$tmp_root/code/app/operator"
test -f "$tmp_root/operator/catalog/README.md"
test -f "$tmp_root/operator/catalog/roles/provider-integration.md"
test -f "$tmp_root/operator/catalog/patterns/provider-integration.md"
test -f "$tmp_root/operator/system-map.md"
bash scripts/operator-catalog.sh list roles | grep -q provider-integration
bash scripts/operator-recommend-lanes.sh >/dev/null
bash scripts/operator-plan-batch.sh >/dev/null
bash scripts/operator-feature.sh active >/dev/null
bash scripts/operator-conflicts.sh summary >/dev/null

feature_a="$(bash scripts/operator-feature.sh start training-zones "Training Zones" --roadmap RM-0002)"
feature_b="$(bash scripts/operator-feature.sh start onboarding "Onboarding" --status design)"
test -f "$feature_a/status.json"
test -f "$feature_b/status.json"
bash scripts/operator-feature.sh bind FS-0001 --tool codex --chat smoke-a --mode feature >/dev/null
bash scripts/operator-feature.sh claim FS-0001 \
  --files apps/mobile/src/training-zones/** \
  --surfaces mobile.feature.training-zones \
  --contracts training-zones \
  --resources simulator-agent-1 \
  --roles mobile-ui \
  --level hard >/dev/null
bash scripts/operator-feature.sh claim FS-0002 \
  --files apps/mobile/src/onboarding/** \
  --surfaces mobile.feature.onboarding \
  --resources simulator-agent-2 \
  --roles mobile-ui \
  --level soft >/dev/null
bash scripts/operator-feature.sh spawn-lane FS-0001 mobile-ui --tool claude --resources simulator-agent-1 >/dev/null
bash scripts/operator-conflicts.sh check FS-0001 | grep -q 'mobile-ui (duplicable'
bash scripts/operator-feature.sh claim FS-0002 --contracts training-zones >/dev/null
bash scripts/operator-conflicts.sh check FS-0001 | grep -q 'contracts: `training-zones`'
bash scripts/operator-feature.sh close FS-0002 --reason "smoke complete" >/dev/null
bash scripts/operator-feature.sh cleanup --dry-run | grep -q FS-0002

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

bash scripts/operator-roadmap.sh add "Provider import" \
  --id RM-0001 \
  --status shipped \
  --owner-lane backend \
  --required-roles provider-integration \
  --contracts provider-api >/dev/null
bash scripts/operator-roadmap.sh add "Mobile polish" \
  --id RM-0002 \
  --status ready \
  --depends-on RM-0001 \
  --owner-lane ui \
  --required-roles mobile-app \
  --contracts mobile-home >/dev/null
bash scripts/operator-plan-batch.sh | grep -q 'RM-0002'

mkdir -p "$tmp_root/code/app/.cursor/skills/product-manager"
printf '# Legacy Product Manager\n' > "$tmp_root/code/app/.cursor/skills/product-manager/SKILL.md"
bash "$KIT_ROOT/scripts/operator-update.sh" \
  --source "$KIT_ROOT" \
  --channel latest \
  --target "$tmp_root/code/app" \
  --no-fetch >/dev/null
test ! -e "$tmp_root/code/app/.cursor/skills/product-manager"

sync_output="$(bash "$tmp_root/code/app/scripts/operator-sync.sh" \
  --source "$KIT_ROOT" \
  --channel latest \
  --target "$tmp_root/code/app" \
  --skip-skills \
  --skip-checks \
  --no-fetch 2>&1)"
if printf '%s\n' "$sync_output" | grep -q 'unexpected EOF'; then
  printf '%s\n' "$sync_output" >&2
  exit 1
fi

codex_home="$tmp_root/codex-home"
mkdir -p "$codex_home/skills/product-manager"
printf '# Legacy Product Manager\n' > "$codex_home/skills/product-manager/SKILL.md"
bash "$KIT_ROOT/scripts/codex-skills-install.sh" \
  --source "$KIT_ROOT" \
  --codex-home "$codex_home" \
  --no-fetch >/dev/null
test ! -e "$codex_home/skills/product-manager"
test -f "$codex_home/skills/operator-planner/SKILL.md"

bash "$KIT_ROOT/scripts/operator-upgrade.sh" \
  --source "$KIT_ROOT" \
  --projects-root "$tmp_root" \
  --skip-skills \
  --dry-run \
  --no-fetch \
  --skip-checks >/dev/null

printf 'smoke ok: %s\n' "$tmp_root"
