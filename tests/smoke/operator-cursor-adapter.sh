#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d /tmp/aok-cursor-adapter-smoke.XXXXXX)"
tmp_root="$(cd "$tmp_root" && pwd -P)"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/code/app"
git -C "$tmp_root/code/app" init -b main >/dev/null
git -C "$tmp_root/code/app" config user.email smoke@example.com
git -C "$tmp_root/code/app" config user.name "Smoke Test"
printf '# Adapter Smoke\n' > "$tmp_root/code/app/README.md"
git -C "$tmp_root/code/app" add README.md
git -C "$tmp_root/code/app" commit -m 'init' >/dev/null

bash "$KIT_ROOT/scripts/operator-bootstrap.sh" --profile cursor "$tmp_root/code/app"

cd "$tmp_root/code/app"
bash scripts/operator-context.sh >/dev/null
bash scripts/operator-adapter-check.sh >/dev/null
bash scripts/operator-roadmap.sh blocked >/dev/null

# Simulate stale gitignore bug
printf 'operator/\n' >> .gitignore
if bash scripts/operator-adapter-check.sh >/dev/null 2>&1; then
  printf 'adapter-check should fail when operator/ gitignore is present\n' >&2
  exit 1
fi

bash "$KIT_ROOT/scripts/operator-sync.sh" \
  --source "$KIT_ROOT" \
  --channel latest \
  --target "$tmp_root/code/app" \
  --skip-skills \
  --refresh-cursor-adapter \
  --no-fetch >/dev/null

grep -q 'Sticky Operator mode' .cursor/rules/operator-workflow.mdc
test -f .cursor/commands/operator.md

printf 'operator cursor adapter smoke ok: %s\n' "$tmp_root"
