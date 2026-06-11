#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN_ROOT="$KIT_ROOT/plugins/operator-kit"
MANIFEST="$PLUGIN_ROOT/.codex-plugin/plugin.json"
MARKETPLACE_ENTRY="$PLUGIN_ROOT/marketplace-entry.json"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test -d "$PLUGIN_ROOT" || fail "Missing plugin root: $PLUGIN_ROOT"
test -f "$MANIFEST" || fail "Missing plugin manifest: $MANIFEST"
test -f "$MARKETPLACE_ENTRY" || fail "Missing marketplace entry metadata."
test -d "$PLUGIN_ROOT/skills" || fail "Missing plugin skills directory."

python3 - "$MANIFEST" "$MARKETPLACE_ENTRY" <<'PY'
import json
import re
import sys
from pathlib import PurePosixPath

manifest_path = sys.argv[1]
marketplace_entry_path = sys.argv[2]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
with open(marketplace_entry_path, encoding="utf-8") as handle:
    marketplace_entry = json.load(handle)

errors = []

def require_string(payload, key, label):
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{label}.{key} must be a non-empty string")
    return value

if manifest.get("name") != "operator":
    errors.append("manifest name must be operator")

version = require_string(manifest, "version", "manifest")
if version and not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:[-+][0-9A-Za-z.-]+)?", version):
    errors.append("manifest version must be semver")

require_string(manifest, "description", "manifest")

skills_path = manifest.get("skills")
if not isinstance(skills_path, str):
    errors.append("manifest.skills must be a string")
else:
    normalized = PurePosixPath(skills_path.replace("\\", "/")).as_posix().rstrip("/")
    if normalized not in {"skills", "./skills"}:
        errors.append("manifest.skills must resolve to ./skills/")

for field in ("apps", "mcpServers"):
    if field in manifest:
        errors.append(f"manifest must not declare {field} until companion files exist")

author = manifest.get("author")
if not isinstance(author, dict):
    errors.append("manifest.author must be an object")
else:
    require_string(author, "name", "author")

interface = manifest.get("interface")
if not isinstance(interface, dict):
    errors.append("manifest.interface must be an object")
else:
    for key in (
        "displayName",
        "shortDescription",
        "longDescription",
        "developerName",
        "category",
    ):
        require_string(interface, key, "interface")
    capabilities = interface.get("capabilities")
    if not isinstance(capabilities, list) or not all(isinstance(item, str) and item.strip() for item in capabilities):
        errors.append("interface.capabilities must be a non-empty string array")
    default_prompt = interface.get("defaultPrompt") or interface.get("default_prompt")
    if isinstance(default_prompt, str):
        prompts = [default_prompt]
    elif isinstance(default_prompt, list):
        prompts = default_prompt
    else:
        prompts = []
    if not prompts or not all(isinstance(item, str) and item.strip() for item in prompts):
        errors.append("interface.defaultPrompt must be a non-empty string or string array")
    elif not any("get started" in item.lower() for item in prompts):
        errors.append("interface.defaultPrompt must include a get-started prompt")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)

source = marketplace_entry.get("source")
policy = marketplace_entry.get("policy")
if marketplace_entry.get("name") != "operator":
    print("marketplace entry name must be operator", file=sys.stderr)
    raise SystemExit(1)
if source != {"source": "local", "path": "./plugins/operator-kit"}:
    print("marketplace entry source must point at ./plugins/operator-kit", file=sys.stderr)
    raise SystemExit(1)
if not isinstance(policy, dict) or policy.get("installation") != "AVAILABLE" or policy.get("authentication") != "ON_INSTALL":
    print("marketplace entry policy must be AVAILABLE/ON_INSTALL", file=sys.stderr)
    raise SystemExit(1)
if marketplace_entry.get("category") != "Developer Tools":
    print("marketplace entry category must be Developer Tools", file=sys.stderr)
    raise SystemExit(1)
PY

diff_log="$(mktemp /tmp/aok-plugin-skills-diff.XXXXXX)"
if ! diff -qr "$KIT_ROOT/skills/codex" "$PLUGIN_ROOT/skills" >"$diff_log"; then
  cat "$diff_log" >&2
  fail "Plugin skill bundle is out of sync with skills/codex."
fi
rm -f "$diff_log"

skill_count="$(find "$PLUGIN_ROOT/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
test "$skill_count" -ge 1 || fail "No packaged skills discovered."

while IFS= read -r skill_dir; do
  skill_md="$skill_dir/SKILL.md"
  test -f "$skill_md" || fail "Packaged skill is missing SKILL.md: $skill_dir"
  test "$(sed -n '1p' "$skill_md")" = "---" || fail "Skill frontmatter missing: $skill_md"
  sed -n '2,20p' "$skill_md" | grep -q '^---$' || fail "Skill frontmatter not closed: $skill_md"
  sed -n '2,20p' "$skill_md" | grep -q '^name:[[:space:]]*' || fail "Skill name missing: $skill_md"
  sed -n '2,20p' "$skill_md" | grep -q '^description:[[:space:]]*' || fail "Skill description missing: $skill_md"
done < <(find "$PLUGIN_ROOT/skills" -mindepth 1 -maxdepth 1 -type d | sort)

tmp_root="$(mktemp -d /tmp/aok-plugin-sync.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

repo="$tmp_root/code/app"
mkdir -p "$repo"
git -C "$repo" init -b main >/dev/null
git -C "$repo" config user.email smoke@example.com
git -C "$repo" config user.name "Smoke Test"
printf '# Plugin Sync Smoke\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -m 'init' >/dev/null

bash "$KIT_ROOT/scripts/operator-bootstrap.sh" "$repo" >/dev/null

sync_output="$(
  bash "$KIT_ROOT/scripts/operator-sync.sh" \
    --source "$KIT_ROOT" \
    --target "$repo" \
    --skip-skills \
    --dry-run \
    --no-fetch \
    --skip-checks 2>&1
)"

if printf '%s\n' "$sync_output" | grep -q 'unexpected EOF'; then
  printf '%s\n' "$sync_output" >&2
  exit 1
fi
printf '%s\n' "$sync_output" | grep -q 'Mode: dry run' || fail "Sync dry-run output did not report dry-run mode."
printf '%s\n' "$sync_output" | grep -q '## Project Update' || fail "Sync dry-run did not reach project update."
printf '%s\n' "$sync_output" | grep -q '## Project Checks' || fail "Sync dry-run did not report skipped project checks."

printf 'codex plugin package smoke ok: %s\n' "$PLUGIN_ROOT"
