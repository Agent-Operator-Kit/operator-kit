#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN_ROOT="$KIT_ROOT/plugins/operator-kit"
BUNDLE="$PLUGIN_ROOT/v3-adapter-bundle.json"
CURSOR="$PLUGIN_ROOT/adapters/cursor"
CLAUDE="$PLUGIN_ROOT/adapters/claude-code"

tmp_root="$(mktemp -d /tmp/aok-v3-adapters.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT
export HOME="$tmp_root/home"
mkdir -p "$HOME"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test ! -e "$KIT_ROOT/operator.config.env" || fail "Source repo root must not contain operator.config.env."
test -f "$BUNDLE" || fail "Missing V3 adapter bundle metadata."
test -f "$CURSOR/adapter.json" || fail "Missing Cursor adapter metadata."
test -f "$CLAUDE/adapter.json" || fail "Missing Claude Code adapter metadata."

python3 - "$PLUGIN_ROOT" "$BUNDLE" "$CURSOR/adapter.json" "$CLAUDE/adapter.json" <<'PY'
import json
import re
import sys
from pathlib import Path

plugin_root = Path(sys.argv[1])
bundle_path = Path(sys.argv[2])
adapter_paths = [Path(path) for path in sys.argv[3:]]
semver = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:[-+][0-9A-Za-z.-]+)?$")

def load(path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)

bundle = load(bundle_path)
errors = []

def require(condition, message):
    if not condition:
        errors.append(message)

require(bundle.get("name") == "operator-kit-v3-adapter-bundle", "bundle name mismatch")
bundle_version = bundle.get("version")
require(isinstance(bundle_version, str) and semver.fullmatch(bundle_version), "bundle version must be semver")
require(bundle.get("releaseTrack") == "v3", "bundle releaseTrack must be v3")
require(bundle.get("projectScopedSetupRequired") is True, "bundle must require project-scoped setup")
require("2" in bundle.get("compatibleProjectKitVersions", []), "bundle must target Operator Kit V2")

bundle_adapters = bundle.get("adapters")
require(isinstance(bundle_adapters, list) and len(bundle_adapters) == 3, "bundle must list three host adapters")

for adapter_path in adapter_paths:
    adapter = load(adapter_path)
    host = adapter.get("host")
    require(host in {"cursor", "claude-code"}, f"{adapter_path} host mismatch")
    require(adapter.get("kind") == "host-adapter-package", f"{host} kind must be host-adapter-package")
    version = adapter.get("version")
    require(isinstance(version, str) and semver.fullmatch(version), f"{host} version must be semver")
    require(adapter.get("bundleVersion") == bundle_version, f"{host} bundleVersion must match bundle")
    require(adapter.get("releaseTrack") == "v3", f"{host} releaseTrack must be v3")
    require(adapter.get("requiresProjectScopedSetup") is True, f"{host} must require project setup")
    require(adapter.get("requiresSourceRootOperatorConfig") is False, f"{host} must not require source-root operator.config.env")
    require(adapter.get("writesUserGlobalStateDuringValidation") is False, f"{host} validation must not write user-global state")
    require(adapter.get("runtimeApiAssumptions") == [], f"{host} must not invent runtime API assumptions")
    require("2" in adapter.get("compatibleProjectKitVersions", []), f"{host} must target Operator Kit V2")

    assets = adapter.get("assets")
    require(isinstance(assets, dict) and assets, f"{host} assets must be an object")
    adapter_root = adapter_path.parent
    for label, raw_path in assets.items():
        candidate = adapter_root / raw_path
        require(candidate.exists(), f"{host} asset path missing for {label}: {candidate}")
        require(candidate.resolve().is_relative_to(plugin_root.resolve()), f"{host} asset path escapes plugin root: {candidate}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY

diff_log="$tmp_root/diff.log"

if ! diff -qr "$KIT_ROOT/skills/cursor" "$CURSOR/skills" >"$diff_log"; then
  cat "$diff_log" >&2
  fail "Cursor adapter skills are out of sync with skills/cursor."
fi

if ! diff -qr "$KIT_ROOT/templates/cursor/skills" "$CURSOR/project-templates/.cursor/skills" >"$diff_log"; then
  cat "$diff_log" >&2
  fail "Cursor project skill templates are out of sync with templates/cursor/skills."
fi

cmp -s "$KIT_ROOT/templates/cursor/rules/operator-workflow.mdc" \
  "$CURSOR/project-templates/.cursor/rules/operator-workflow.mdc" \
  || fail "Cursor rule template is out of sync."
cmp -s "$KIT_ROOT/templates/cursor/environment.json.example" \
  "$CURSOR/project-templates/.cursor/environment.json.example" \
  || fail "Cursor environment example is out of sync."
cmp -s "$KIT_ROOT/templates/prompts/cursor-agent-bootstrap.md" \
  "$CURSOR/prompts/cursor-agent-bootstrap.md" \
  || fail "Cursor bootstrap prompt is out of sync."

if ! diff -qr "$KIT_ROOT/skills/claude-code" "$CLAUDE/skills" >"$diff_log"; then
  cat "$diff_log" >&2
  fail "Claude Code adapter skills are out of sync with skills/claude-code."
fi

cmp -s "$KIT_ROOT/templates/claude/commands/operator-bootstrap.md" \
  "$CLAUDE/project-templates/.claude/commands/operator-bootstrap.md" \
  || fail "Claude operator-bootstrap command is out of sync."
cmp -s "$KIT_ROOT/templates/claude/commands/operator-status.md" \
  "$CLAUDE/project-templates/.claude/commands/operator-status.md" \
  || fail "Claude operator-status command is out of sync."
cmp -s "$KIT_ROOT/templates/claude/agents/operator-workflow.md" \
  "$CLAUDE/project-templates/.claude/agents/operator-workflow.md" \
  || fail "Claude operator-workflow agent is out of sync."

test ! -e "$HOME/.codex" || fail "Validation wrote to HOME/.codex."
test ! -e "$HOME/.cursor" || fail "Validation wrote to HOME/.cursor."
test ! -e "$HOME/.claude" || fail "Validation wrote to HOME/.claude."

printf 'v3 host adapters smoke ok: %s\n' "$PLUGIN_ROOT"
