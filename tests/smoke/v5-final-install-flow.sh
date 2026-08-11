#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/aok-v5-final-install.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'v5 final install flow failed: %s\n' "$1" >&2; exit 1; }
expect_refusal() {
  local label="$1"; shift
  set +e
  "$@" >"$TMP_ROOT/refusal.out" 2>"$TMP_ROOT/refusal.err"
  local rc=$?
  set -e
  test "$rc" -ne 0 || fail "$label did not fail closed"
  grep -q 'Unsafe external design prompt boundary' "$TMP_ROOT/refusal.err" \
    || fail "$label omitted the prompt-boundary refusal"
}
file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

project="$TMP_ROOT/project"
repo="$project/code/app"
mkdir -p "$repo"
git -C "$repo" init -b main >/dev/null
git -C "$repo" config user.email smoke@example.com
git -C "$repo" config user.name "Smoke Test"

bash "$KIT_ROOT/scripts/operator-bootstrap.sh" "$repo" >/dev/null
grep -q 'OPERATOR_KIT_VERSION="5"' "$repo/operator.config.env" || fail "fresh latest install is not V5"

for script in operator-role-map.sh operator-graph.sh operator-scheduler.sh operator-loop.sh operator-host.sh operator-proof-broker.sh operator-design-flow.sh operator-v5-migrate.sh operator-v5-provision.sh; do
  test -x "$repo/scripts/$script" || fail "missing executable V5 runtime: $script"
done
for helper in operator_graph.py operator_host.py operator_design_provider.py operator_v5_migrate.py operator_v5_provision.py; do
  test -f "$repo/scripts/$helper" || fail "missing plain V5 helper: $helper"
  test ! -x "$repo/scripts/$helper" || fail "plain V5 helper became executable: $helper"
done

test "$(find "$repo/schemas/operator-v5" -type f -name '*.json' | wc -l | tr -d ' ')" = 11 || fail "schema bundle is not eleven files"
find "$repo/schemas/operator-v5" -type f -name '*.json' -exec test ! -x {} \; || fail "schema became executable"
find "$project/operator" -type f \( -name '*.md' -o -name '*.json' \) -exec test ! -x {} \; || fail "workspace data/template became executable"

test -f "$project/operator/graph/README.md" || fail "graph workspace template missing"
test -f "$project/operator/prompts/design-proposal.md" || fail "design proposal template missing"
test ! -e "$project/operator/graph/events.jsonl" || fail "bootstrap initialized graph history"
test ! -e "$project/operator/graph/definition.json" || fail "bootstrap initialized graph definition"
test ! -e "$project/operator/graph/projection.json" || fail "bootstrap initialized graph projection"
test ! -e "$project/operator/authority/control-graph-public-key.json" || fail "bootstrap initialized authority state"
test -z "$(find "$project/operator" -type f \( -iname '*private*key*' -o -name '*.pem' \) -print -quit)" || fail "bootstrap created key material"

OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-role-map.sh" validate >/dev/null
python3 - "$project/operator/catalog/role-map.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert [lane["id"] for lane in value["durableLanes"]] == ["backend", "operator", "ui"]
assert value["durableLanes"][0]["worktree"] == "app-backend"
assert len(value["durableLanes"]) != 8
PY

python3 - "$repo/schemas/operator-v5" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
files = sorted(root.glob("*.json"))
assert len(files) == 11
for path in files:
    value = json.loads(path.read_text(encoding="utf-8"))
    stack = [value]
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            ref = item.get("$ref")
            if isinstance(ref, str) and not ref.startswith("#"):
                target = root / ref.split("#", 1)[0]
                assert target.is_file(), (path.name, ref)
            stack.extend(item.values())
        elif isinstance(item, list):
            stack.extend(item)
PY

before_role_map="$(shasum -a 256 "$project/operator/catalog/role-map.json")"
before_config="$(shasum -a 256 "$repo/operator.config.env")"

# Update must lstat the prompt boundary rather than treating symlinks as a
# missing file. Neither dangling nor existing targets may be followed, and a
# symlinked prompts directory may not receive mkdir/chmod/copy effects.
prompt="$project/operator/prompts/design-proposal.md"
prompt_escape="$TMP_ROOT/update-prompt-escape"
mkdir -p "$prompt_escape"
rm "$prompt"
ln -s "$prompt_escape/dangling-target.md" "$prompt"
expect_refusal "update dangling prompt symlink" \
  bash "$KIT_ROOT/scripts/operator-update.sh" --source "$KIT_ROOT" --channel latest --target "$repo" --no-fetch
test ! -e "$prompt_escape/dangling-target.md" || fail "update followed a dangling prompt symlink"
unlink "$prompt"

printf 'existing external prompt target must not change\n' > "$prompt_escape/existing-target.md"
existing_target_digest="$(shasum -a 256 "$prompt_escape/existing-target.md")"
ln -s "$prompt_escape/existing-target.md" "$prompt"
expect_refusal "update existing prompt symlink" \
  bash "$KIT_ROOT/scripts/operator-update.sh" --source "$KIT_ROOT" --channel latest --target "$repo" --no-fetch
test "$existing_target_digest" = "$(shasum -a 256 "$prompt_escape/existing-target.md")" \
  || fail "update rewrote an existing prompt symlink target"
unlink "$prompt"

mv "$project/operator/prompts" "$project/operator/prompts-real"
mkdir "$prompt_escape/intermediate"
printf 'intermediate sentinel must not change\n' > "$prompt_escape/intermediate/sentinel.txt"
intermediate_digest="$(shasum -a 256 "$prompt_escape/intermediate/sentinel.txt")"
ln -s "$prompt_escape/intermediate" "$project/operator/prompts"
expect_refusal "update intermediate prompts symlink" \
  bash "$KIT_ROOT/scripts/operator-update.sh" --source "$KIT_ROOT" --channel latest --target "$repo" --no-fetch
test ! -e "$prompt_escape/intermediate/design-proposal.md" \
  || fail "update copied the prompt through an intermediate symlink"
test "$intermediate_digest" = "$(shasum -a 256 "$prompt_escape/intermediate/sentinel.txt")" \
  || fail "update mutated the intermediate prompts symlink target"
unlink "$project/operator/prompts"
mv "$project/operator/prompts-real" "$project/operator/prompts"

# Pre-existing external workspaces receive the same bootstrap boundary.
for bootstrap_escape_kind in dangling existing intermediate; do
  escape_project="$TMP_ROOT/bootstrap-$bootstrap_escape_kind"
  escape_repo="$escape_project/code/app"
  escape_operator="$escape_project/operator"
  escape_target="$TMP_ROOT/bootstrap-$bootstrap_escape_kind-target"
  mkdir -p "$escape_repo" "$escape_operator" "$escape_target"
  git -C "$escape_repo" init -b main >/dev/null
  case "$bootstrap_escape_kind" in
    dangling)
      mkdir "$escape_operator/prompts"
      ln -s "$escape_target/missing.md" "$escape_operator/prompts/design-proposal.md"
      ;;
    existing)
      mkdir "$escape_operator/prompts"
      printf 'bootstrap existing target must not change\n' > "$escape_target/existing.md"
      bootstrap_target_digest="$(shasum -a 256 "$escape_target/existing.md")"
      ln -s "$escape_target/existing.md" "$escape_operator/prompts/design-proposal.md"
      ;;
    intermediate)
      printf 'bootstrap intermediate sentinel\n' > "$escape_target/sentinel.txt"
      bootstrap_target_digest="$(shasum -a 256 "$escape_target/sentinel.txt")"
      ln -s "$escape_target" "$escape_operator/prompts"
      ;;
  esac
  expect_refusal "bootstrap $bootstrap_escape_kind prompt escape" \
    bash "$KIT_ROOT/scripts/operator-bootstrap.sh" "$escape_repo"
  case "$bootstrap_escape_kind" in
    dangling)
      test ! -e "$escape_target/missing.md" || fail "bootstrap followed a dangling prompt symlink"
      ;;
    existing)
      test "$bootstrap_target_digest" = "$(shasum -a 256 "$escape_target/existing.md")" \
        || fail "bootstrap rewrote an existing prompt symlink target"
      ;;
    intermediate)
      test ! -e "$escape_target/design-proposal.md" \
        || fail "bootstrap copied the prompt through an intermediate symlink"
      test "$bootstrap_target_digest" = "$(shasum -a 256 "$escape_target/sentinel.txt")" \
        || fail "bootstrap mutated the intermediate prompts symlink target"
      ;;
  esac
done

test ! -e "$project/operator/prompts/design-proposal.md" \
  || fail "prompt escape fixtures unexpectedly restored the canonical leaf"
bash "$KIT_ROOT/scripts/operator-update.sh" --source "$KIT_ROOT" --channel latest --target "$repo" --no-fetch >/dev/null
cmp -s "$KIT_ROOT/templates/prompts/design-proposal.md" "$project/operator/prompts/design-proposal.md" || fail "update did not restore the missing external design prompt"
test ! -x "$project/operator/prompts/design-proposal.md" || fail "restored external design prompt became executable"
test "$(file_mode "$project/operator/prompts")" = 700 || fail "restored prompts directory mode is not 0700"
test "$(file_mode "$project/operator/prompts/design-proposal.md")" = 644 || fail "restored external design prompt mode is not 0644"
bash "$KIT_ROOT/scripts/operator-update.sh" --source "$KIT_ROOT" --channel latest --target "$repo" --no-fetch >/dev/null
bash "$KIT_ROOT/scripts/operator-update.sh" --source "$KIT_ROOT" --channel latest --target "$repo" --no-fetch >/dev/null
test "$before_role_map" = "$(shasum -a 256 "$project/operator/catalog/role-map.json")" || fail "repeat update rewrote the role map"
test "$before_config" = "$(shasum -a 256 "$repo/operator.config.env")" || fail "repeat update rewrote project config"

bash "$repo/scripts/operator-sync.sh" --source "$KIT_ROOT" --channel latest --target "$repo" --skip-skills --skip-checks --no-fetch >/dev/null
bash "$repo/scripts/operator-sync.sh" --source "$KIT_ROOT" --channel latest --target "$repo" --skip-skills --skip-checks --no-fetch >/dev/null
bash "$repo/scripts/operator-upgrade.sh" --source "$KIT_ROOT" --channel latest --target "$repo" --skip-skills --skip-checks --dry-run --no-fetch >/dev/null
grep -q 'OPERATOR_KIT_VERSION="5"' "$repo/operator.config.env" || fail "repeat distribution changed the V5 marker"

status="$(OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-status.sh")"
grep -q 'Operator Kit version: 5' <<<"$status" || fail "status omitted kit version"
grep -q 'Control graph: not initialized' <<<"$status" || fail "status did not report uninitialized graph"
grep -q 'Host: runtime installed' <<<"$status" || fail "status omitted host readiness"
test ! -e "$project/operator/graph/events.jsonl" || fail "status auto-initialized graph history"
test ! -e "$project/operator/graph/.lock" || fail "status mutated graph lock state"

codex_bypass='dangerously-bypass-approvals-and-'"sandbox"
claude_bypass='dangerously-skip-'"permissions"
claude_mode='bypass'"Permissions"
if rg -n "$codex_bypass|$claude_bypass|$claude_mode" "$repo"; then
  fail "installed project contains a production permission bypass"
fi

printf 'v5 final install flow smoke ok\n'
