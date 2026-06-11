#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d /tmp/aok-cursor-skills.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

export HOME="$tmp_root/home"
mkdir -p "$HOME"

cursor_home="$tmp_root/cursor-home"
codex_home="$tmp_root/codex-home"
dry_cursor_home="$tmp_root/dry-cursor-home"
sync_cursor_home="$tmp_root/sync-cursor-home"
skip_cursor_home="$tmp_root/skip-cursor-home"
skip_codex_home="$tmp_root/skip-codex-home"

skills=(operator operator-workflow operator-planner operator-feedback design-agent incubation ux-auditor user-journey)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

assert_file() {
  test -f "$1" || fail "Missing expected file: $1"
}

assert_no_path() {
  test ! -e "$1" || fail "Unexpected path exists: $1"
}

list_output="$tmp_root/list.txt"
bash "$KIT_ROOT/scripts/cursor-skills-install.sh" --source "$KIT_ROOT" --no-fetch --list > "$list_output"
for skill in "${skills[@]}"; do
  grep -qx "$skill" "$list_output" || fail "List output missing Cursor skill: $skill"
done

mkdir -p "$dry_cursor_home/skills/product-manager"
printf '# Legacy Product Manager\n' > "$dry_cursor_home/skills/product-manager/SKILL.md"
dry_output="$tmp_root/dry-run.txt"
bash "$KIT_ROOT/scripts/cursor-skills-install.sh" \
  --source "$KIT_ROOT" \
  --cursor-home "$dry_cursor_home" \
  --no-fetch \
  --dry-run > "$dry_output"
grep -q 'Mode: dry run' "$dry_output" || fail "Dry run did not report dry-run mode."
grep -q 'Would remove obsolete Cursor skill product-manager' "$dry_output" || fail "Dry run did not plan obsolete skill removal."
assert_file "$dry_cursor_home/skills/product-manager/SKILL.md"
assert_no_path "$dry_cursor_home/skills/operator"

bash "$KIT_ROOT/scripts/cursor-skills-install.sh" \
  --source "$KIT_ROOT" \
  --cursor-home "$cursor_home" \
  --no-fetch

for skill in "${skills[@]}"; do
  assert_file "$cursor_home/skills/$skill/SKILL.md"
done
assert_no_path "$cursor_home/skills-cursor"

mkdir -p "$cursor_home/skills/product-manager"
printf '# Legacy Product Manager\n' > "$cursor_home/skills/product-manager/SKILL.md"
printf '# stale\n' > "$cursor_home/skills/operator/SKILL.md"
bash "$KIT_ROOT/scripts/cursor-skills-install.sh" \
  --source "$KIT_ROOT" \
  --cursor-home "$cursor_home" \
  --no-fetch \
  --skill operator
assert_no_path "$cursor_home/skills/product-manager"
grep -q 'Manage Agent Operator Kit execution from Cursor' "$cursor_home/skills/operator/SKILL.md" || fail "Operator skill was not refreshed."

bash "$KIT_ROOT/scripts/operator-sync.sh" \
  --source "$KIT_ROOT" \
  --channel latest \
  --no-fetch \
  --skip-project \
  --codex-home "$codex_home" \
  --cursor-home "$sync_cursor_home" >/dev/null
assert_file "$sync_cursor_home/skills/operator/SKILL.md"
assert_file "$codex_home/skills/operator/SKILL.md"

bash "$KIT_ROOT/scripts/operator-sync.sh" \
  --source "$KIT_ROOT" \
  --channel latest \
  --no-fetch \
  --skip-project \
  --skip-skills \
  --codex-home "$skip_codex_home" \
  --cursor-home "$skip_cursor_home" >/dev/null
assert_no_path "$skip_cursor_home"
assert_no_path "$skip_codex_home"

printf 'cursor skills install smoke ok: %s\n' "$tmp_root"
