#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/operator-v5-1-install.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT
repo="$TMP_ROOT/code/app"
mkdir -p "$repo"
git -C "$repo" init -b main >/dev/null
git -C "$repo" config user.email smoke@example.com
git -C "$repo" config user.name Smoke
printf '# smoke\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -m init >/dev/null

bash "$KIT_ROOT/scripts/operator-bootstrap.sh" "$repo" >/dev/null
grep -q 'OPERATOR_KIT_VERSION="5.1"' "$repo/operator.config.env"
test -x "$repo/scripts/operator-graph.sh"
test -f "$repo/scripts/operator_local_graph.py"
test -x "$repo/scripts/operator-v5-1-migrate.sh"
test -x "$repo/scripts/operator-model-select.sh"
test -f "$repo/scripts/operator_model_selector.py"
test ! -x "$repo/scripts/operator_model_selector.py"
for obsolete in operator-host.sh operator-proof-broker.sh operator-loop.sh operator-v5-provision.sh; do
  test ! -e "$repo/scripts/$obsolete"
done
test ! -e "$repo/schemas/operator-v5"
for schema in task-demand model-catalog model-policy model-decision model-outcome; do
  test -f "$repo/schemas/operator-model-selection/v1/$schema.schema.json"
  test ! -x "$repo/schemas/operator-model-selection/v1/$schema.schema.json"
done

model_selection_dir="$TMP_ROOT/operator/model-selection"
test -f "$model_selection_dir/README.md"
test -f "$model_selection_dir/catalog.example.json"
test -f "$model_selection_dir/policy.example.json"
test ! -e "$model_selection_dir/catalog.json"
test ! -e "$model_selection_dir/policy.json"
! grep -Eq 'MODEL_SELECTION|model-selection' "$repo/operator.config.env"

/usr/bin/python3 - "$model_selection_dir/catalog.example.json" "$model_selection_dir/policy.example.json" <<'PY'
import json
import sys

catalog = json.load(open(sys.argv[1], encoding="utf-8"))
policy = json.load(open(sys.argv[2], encoding="utf-8"))
assert policy["mode"] == "off"
assert catalog["candidates"]
assert all(candidate["enabled"] is False for candidate in catalog["candidates"])
assert all(candidate["availability"] == "unavailable" for candidate in catalog["candidates"])
PY

OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-model-select.sh" \
  validate --kind catalog "$model_selection_dir/catalog.example.json" >/dev/null
OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-model-select.sh" \
  validate --kind policy "$model_selection_dir/policy.example.json" >/dev/null

snapshot_model_selection() {
  /usr/bin/python3 - "$1" <<'PY'
import hashlib
import json
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
snapshot = {}
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    relative = str(path.relative_to(root))
    info = path.stat()
    snapshot[relative] = {
        "mode": stat.S_IMODE(info.st_mode),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
print(json.dumps(snapshot, sort_keys=True, separators=(",", ":")))
PY
}

# Updates refresh repo-owned runtime/schema assets while preserving every
# existing project-owned model-selection workspace file.
printf 'project-owned workspace readme\n' > "$model_selection_dir/README.md"
printf '{"projectOwned":"catalog example"}\n' > "$model_selection_dir/catalog.example.json"
printf '{"projectOwned":"policy example"}\n' > "$model_selection_dir/policy.example.json"
printf '{"projectOwned":"live catalog"}\n' > "$model_selection_dir/catalog.json"
printf '{"projectOwned":"live policy"}\n' > "$model_selection_dir/policy.json"
mkdir -p "$model_selection_dir/history"
printf 'project-owned outcome evidence\n' > "$model_selection_dir/history/outcomes.jsonl"
snapshot_model_selection "$model_selection_dir" > "$TMP_ROOT/model-selection-before.json"
config_digest_before="$(shasum -a 256 "$repo/operator.config.env")"

printf 'stale selector wrapper\n' > "$repo/scripts/operator-model-select.sh"
chmod 0644 "$repo/scripts/operator-model-select.sh"
printf 'stale selector runtime\n' > "$repo/scripts/operator_model_selector.py"
printf '{}\n' > "$repo/schemas/operator-model-selection/v1/model-policy.schema.json"

bash "$repo/scripts/operator-update.sh" \
  --source "$KIT_ROOT" \
  --target "$repo" \
  --channel latest \
  --no-fetch >/dev/null

snapshot_model_selection "$model_selection_dir" > "$TMP_ROOT/model-selection-after.json"
cmp -s "$TMP_ROOT/model-selection-before.json" "$TMP_ROOT/model-selection-after.json"
test "$config_digest_before" = "$(shasum -a 256 "$repo/operator.config.env")"
cmp -s "$KIT_ROOT/scripts/operator-model-select.sh" "$repo/scripts/operator-model-select.sh"
cmp -s "$KIT_ROOT/scripts/operator_model_selector.py" "$repo/scripts/operator_model_selector.py"
cmp -s \
  "$KIT_ROOT/schemas/operator-model-selection/v1/model-policy.schema.json" \
  "$repo/schemas/operator-model-selection/v1/model-policy.schema.json"
test -x "$repo/scripts/operator-model-select.sh"
test ! -x "$repo/scripts/operator_model_selector.py"

# A later update may restore a missing starter without changing sibling files.
rm "$model_selection_dir/README.md"
bash "$repo/scripts/operator-update.sh" \
  --source "$KIT_ROOT" \
  --target "$repo" \
  --channel latest \
  --no-fetch >/dev/null
cmp -s \
  "$KIT_ROOT/templates/operator-workspace/model-selection/README.md" \
  "$model_selection_dir/README.md"
grep -q 'projectOwned.*catalog example' "$model_selection_dir/catalog.example.json"
grep -q 'projectOwned.*live catalog' "$model_selection_dir/catalog.json"

OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-status.sh" > "$TMP_ROOT/status.txt"
grep -q 'Operator Kit version: 5.1' "$TMP_ROOT/status.txt"
grep -q 'no credentials required' "$TMP_ROOT/status.txt"
printf 'operator v5.1 final install smoke ok\n'
