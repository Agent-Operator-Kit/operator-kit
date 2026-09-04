#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d /tmp/aok-e2e-sticky.XXXXXX)"
tmp_root="$(cd "$tmp_root" && pwd -P)"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/code/app"
git -C "$tmp_root/code/app" init -b main >/dev/null
git -C "$tmp_root/code/app" config user.email e2e@example.com
git -C "$tmp_root/code/app" config user.name "E2E Test"
printf '# E2E\n' > "$tmp_root/code/app/README.md"
git -C "$tmp_root/code/app" add README.md
git -C "$tmp_root/code/app" commit -m 'init' >/dev/null

bash "$KIT_ROOT/scripts/operator-bootstrap.sh" --profile cursor "$tmp_root/code/app" >/dev/null

cd "$tmp_root/code/app"

# Feature session bind suggestion
bash scripts/operator-feature.sh start e2e-feature "E2E feature" >/dev/null
bash scripts/operator-feature.sh set-status FS-0001 active >/dev/null
open_out="$(bash scripts/operator-feature.sh open --tool cursor)"
if ! printf '%s' "$open_out" | grep -Fq 'Suggested bind'; then
  printf 'expected feature open to suggest bind for single active feature\n' >&2
  exit 1
fi

# Sync refresh + adapter health
bash "$KIT_ROOT/scripts/operator-sync.sh" \
  --source "$KIT_ROOT" \
  --channel latest \
  --target "$tmp_root/code/app" \
  --skip-skills \
  --refresh-cursor-adapter \
  --no-fetch >/dev/null

bash scripts/operator-adapter-check.sh >/dev/null
bash scripts/operator-context.sh >/dev/null

# Roadmap blocked visibility
bash scripts/operator-roadmap.sh add "Human gate" \
  --id RM-9100 --status blocked --approval-gate box-chg >/dev/null
summary_out="$(bash scripts/operator-summary.sh)"
if ! printf '%s' "$summary_out" | grep -Fq 'RM-9100'; then
  printf 'expected summary to list blocked roadmap item\n' >&2
  exit 1
fi

# Worker manifest
bash scripts/operator-workers.sh register e2e-task bg-worker --kind multitask >/dev/null
if bash scripts/operator-workers.sh register e2e-task bg-worker --kind multitask >/dev/null 2>&1; then
  printf 'expected duplicate worker registration to fail\n' >&2
  exit 1
fi

# Upgrade path runs adapter check
bash "$KIT_ROOT/scripts/operator-upgrade.sh" \
  --source "$KIT_ROOT" \
  --channel latest \
  --target "$tmp_root/code/app" \
  --skip-skills \
  --refresh-cursor-adapter \
  --skip-checks \
  --no-fetch >/dev/null

grep -q 'operatorKitAdapter:' .cursor/rules/operator-workflow.mdc
grep -q 'Cockpit vs worker lanes' .cursor/skills/operator/SKILL.md
grep -q 'Cursor Plan mode' .cursor/skills/operator-planner/SKILL.md

printf 'e2e ok: cursor sticky operator flow (%s)\n' "$tmp_root"
