#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIGRATE="$KIT_ROOT/scripts/operator-plugin-migrate.sh"
SYNC="$KIT_ROOT/scripts/operator-sync.sh"

tmp_root="$(mktemp -d /tmp/aok-v3-final-install.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

copy_skill() {
  local skill="$1"
  local codex_home="$2"
  local dest="$codex_home/skills/$skill"
  mkdir -p "$dest"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude='.DS_Store' "$KIT_ROOT/skills/codex/$skill/" "$dest/"
  else
    rm -rf "$dest"
    mkdir -p "$dest"
    (cd "$KIT_ROOT/skills/codex/$skill" && tar --exclude='.DS_Store' -cf - .) | (cd "$dest" && tar -xf -)
  fi
}

assert_file() {
  [ -f "$1" ] || fail "Missing file: $1"
}

assert_dir() {
  [ -d "$1" ] || fail "Missing directory: $1"
}

fake_codex="$tmp_root/bin/codex"
fake_log="$tmp_root/codex-calls.log"
mkdir -p "$tmp_root/bin"
cat > "$fake_codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CODEX_FAKE_LOG"
exit 0
SH
chmod +x "$fake_codex"
export CODEX_FAKE_LOG="$fake_log"

codex_home="$tmp_root/codex-home"
marketplace_root="$tmp_root/operator-kit-marketplace"
mkdir -p "$codex_home/skills"

copy_skill operator "$codex_home"
copy_skill operator-feedback "$codex_home"
copy_skill operator-planner "$codex_home"

bash "$MIGRATE" \
  --source "$KIT_ROOT" \
  --codex-home "$codex_home" \
  --marketplace-root "$marketplace_root" \
  --codex-bin "$fake_codex" >/dev/null

assert_file "$marketplace_root/.agents/plugins/marketplace.json"
assert_file "$marketplace_root/plugins/operator-kit/.codex-plugin/plugin.json"
grep -q 'plugin marketplace add' "$fake_log" || fail "Codex marketplace add was not called"
grep -q 'plugin add operator-kit@operator-kit-local' "$fake_log" || fail "Codex plugin add was not called"

assert_dir "$codex_home/skills/.operator-kit-legacy-backups"
test ! -e "$codex_home/skills/operator" || fail "legacy operator skill still active"
test ! -e "$codex_home/skills/operator-feedback" || fail "legacy operator-feedback skill still active"
test ! -e "$codex_home/skills/operator-planner" || fail "legacy operator-planner skill still active"

project_root="$tmp_root/acme"
mkdir -p "$project_root"

bash "$SYNC" \
  --source "$KIT_ROOT" \
  --channel latest \
  --target "$project_root" \
  --bootstrap-if-missing \
  --skip-skills \
  --no-fetch >/dev/null

repo="$project_root/code/app"
operator_dir="$project_root/operator"

assert_dir "$repo/.git"
assert_file "$repo/operator.config.env"
assert_file "$repo/AGENTS.md"
assert_file "$repo/CODEX.md"
assert_file "$repo/CLAUDE.md"
assert_file "$repo/.gitignore"
assert_file "$repo/.claude/commands/operator-bootstrap.md"
assert_file "$repo/.claude/commands/operator-status.md"
assert_file "$repo/.claude/agents/operator-workflow.md"
assert_file "$repo/.cursor/rules/operator-workflow.mdc"
assert_file "$repo/.cursor/environment.json.example"

for skill in operator-workflow operator operator-planner operator-feedback design-agent incubation ux-auditor user-journey; do
  assert_file "$repo/.cursor/skills/$skill/SKILL.md"
done

for script in operator-status.sh operator-summary.sh operator-task.sh operator-dispatch.sh operator-collect.sh operator-memory.sh operator-roadmap.sh operator-feedback.sh operator-feature.sh operator-conflicts.sh operator-system-map.sh operator-sync.sh operator-upgrade.sh; do
  assert_file "$repo/scripts/$script"
done

assert_dir "$operator_dir/tasks"
assert_dir "$operator_dir/captures"
assert_dir "$operator_dir/memory"
assert_dir "$operator_dir/features"
assert_dir "$operator_dir/roadmap/items"
assert_dir "$operator_dir/roadmap/inbox"
assert_dir "$operator_dir/roadmap/views"
assert_dir "$operator_dir/catalog/roles"
assert_dir "$operator_dir/catalog/patterns"
assert_file "$operator_dir/README.md"
assert_file "$operator_dir/roadmap/README.md"
assert_file "$operator_dir/roadmap/items/_template.md"
assert_file "$operator_dir/roadmap/inbox/_feedback-template.md"
assert_file "$operator_dir/catalog/roles/high-risk-operations.md"
assert_file "$operator_dir/catalog/patterns/architecture-pattern-library.md"
assert_file "$operator_dir/memory/project.md"
assert_file "$operator_dir/features/README.md"
assert_file "$operator_dir/features/active.md"
assert_file "$operator_dir/system-map.md"

grep -q 'OPERATOR_DIR=.*/operator' "$repo/operator.config.env" || fail "operator.config.env does not point at sibling operator dir"
grep -q 'OPERATOR_KIT_VERSION="4"' "$repo/operator.config.env" || fail "operator.config.env missing kit version"
grep -q 'Agent Operator Kit generated state' "$repo/.gitignore" || fail ".gitignore missing Operator Kit marker"
test ! -e "$project_root/operator.config.env" || fail "project root should not contain operator.config.env"
test ! -e "$KIT_ROOT/operator.config.env" || fail "source repo should not contain operator.config.env"

OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-status.sh" >/dev/null
OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-summary.sh" >/dev/null
OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-memory.sh" status >/dev/null
OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-roadmap.sh" status >/dev/null
OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-feature.sh" active >/dev/null
OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-conflicts.sh" summary >/dev/null

bash "$SYNC" \
  --source "$KIT_ROOT" \
  --channel latest \
  --target "$project_root" \
  --skip-skills \
  --no-fetch \
  --skip-checks >/dev/null

printf 'v3 final install flow smoke ok: %s\n' "$project_root"
