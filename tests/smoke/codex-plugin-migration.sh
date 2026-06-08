#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIGRATE="$KIT_ROOT/scripts/operator-plugin-migrate.sh"

tmp_root="$(mktemp -d /tmp/aok-plugin-migration.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

copy_skill() {
  local skill="$1"
  local dest="$2/skills/$skill"
  mkdir -p "$dest"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude='.DS_Store' "$KIT_ROOT/skills/codex/$skill/" "$dest/"
  else
    rm -rf "$dest"
    mkdir -p "$dest"
    (cd "$KIT_ROOT/skills/codex/$skill" && tar --exclude='.DS_Store' -cf - .) | (cd "$dest" && tar -xf -)
  fi
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

dry_codex_home="$tmp_root/dry-codex-home"
mkdir -p "$dry_codex_home/skills"
copy_skill operator "$dry_codex_home"

bash "$MIGRATE" \
  --source "$KIT_ROOT" \
  --codex-home "$dry_codex_home" \
  --marketplace-root "$tmp_root/dry-marketplace" \
  --codex-bin "$fake_codex" \
  --dry-run >/dev/null

test -d "$dry_codex_home/skills/operator" || fail "dry-run retired a legacy skill"
test ! -e "$tmp_root/dry-marketplace" || fail "dry-run wrote marketplace state"

codex_home="$tmp_root/codex-home"
marketplace_root="$tmp_root/operator-kit-marketplace"
mkdir -p "$codex_home/skills"

copy_skill operator "$codex_home"
copy_skill operator-feedback "$codex_home"
copy_skill design-agent "$codex_home"
printf '\n# local customization\n' >> "$codex_home/skills/design-agent/SKILL.md"

mkdir -p "$codex_home/skills/custom-skill"
cat > "$codex_home/skills/custom-skill/SKILL.md" <<'EOF'
---
name: custom-skill
description: User-owned skill.
---

# Custom Skill
EOF

bash "$MIGRATE" \
  --source "$KIT_ROOT" \
  --codex-home "$codex_home" \
  --marketplace-root "$marketplace_root" \
  --codex-bin "$fake_codex" >/dev/null

test -f "$marketplace_root/.agents/plugins/marketplace.json" || fail "marketplace file not written"
test -f "$marketplace_root/plugins/operator-kit/.codex-plugin/plugin.json" || fail "plugin package not copied"
grep -q 'plugin marketplace add' "$fake_log" || fail "codex marketplace add was not called"
grep -q 'plugin add operator-kit@operator-kit-local' "$fake_log" || fail "codex plugin add was not called"

backup_dir="$(find "$codex_home/skills/.operator-kit-legacy-backups" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
test -n "$backup_dir" || fail "backup directory not created"
test ! -e "$codex_home/skills/operator" || fail "exact operator skill was not retired"
test ! -e "$codex_home/skills/operator-feedback" || fail "exact operator-feedback skill was not retired"
test ! -e "$codex_home/skills/design-agent" || fail "changed design-agent should be retired by default"
test -d "$backup_dir/operator" || fail "operator skill not backed up"
test -d "$backup_dir/operator-feedback" || fail "operator-feedback skill not backed up"
test -d "$backup_dir/design-agent" || fail "changed design-agent skill not backed up"
test -d "$codex_home/skills/custom-skill" || fail "unrelated custom skill should remain in place"

python3 - "$marketplace_root/.agents/plugins/marketplace.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

assert payload["name"] == "operator-kit-local"
plugin = payload["plugins"][0]
assert plugin["name"] == "operator-kit"
assert plugin["source"] == {"source": "local", "path": "./plugins/operator-kit"}
assert plugin["policy"]["installation"] == "AVAILABLE"
assert plugin["policy"]["authentication"] == "ON_INSTALL"
PY

bash "$MIGRATE" \
  --codex-home "$codex_home" \
  --restore "$backup_dir" >/dev/null

test -d "$codex_home/skills/operator" || fail "operator skill was not restored"
test -d "$codex_home/skills/operator-feedback" || fail "operator-feedback skill was not restored"
test -d "$codex_home/skills/design-agent" || fail "design-agent skill was not restored"

printf 'codex plugin migration smoke ok: %s\n' "$marketplace_root"
