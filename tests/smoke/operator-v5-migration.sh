#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ -d /private/tmp ]; then
  TMP_ROOT="$(mktemp -d /private/tmp/aok-v5-migration.XXXXXX)"
else
  TMP_ROOT="$(mktemp -d /tmp/aok-v5-migration.XXXXXX)"
fi
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'operator v5 migration smoke failed: %s\n' "$1" >&2; exit 1; }
expect_refusal() {
  local label="$1"; shift
  set +e
  "$@" >"$TMP_ROOT/refusal.out" 2>"$TMP_ROOT/refusal.err"
  local rc=$?
  set -e
  test "$rc" -ne 0 || fail "$label did not fail closed"
  grep -q 'MIGRATION_REFUSED' "$TMP_ROOT/refusal.err" || fail "$label did not emit a migration refusal"
}

flock_counter=0
flock_pid=""
start_flock() {
  local kind="$1"
  local path="$2"
  flock_counter=$((flock_counter + 1))
  local ready="$TMP_ROOT/flock-$flock_counter.ready"
  /usr/bin/python3 - "$kind" "$path" "$ready" <<'PY' &
import fcntl, os, pathlib, signal, sys
kind, path, ready = sys.argv[1:]
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) if kind == "directory" else os.O_RDWR | os.O_CREAT
descriptor = os.open(path, flags, 0o600)
fcntl.flock(descriptor, fcntl.LOCK_EX)
pathlib.Path(ready).touch()
signal.pause()
PY
  flock_pid=$!
  for _ in $(seq 1 500); do
    [ -e "$ready" ] && return 0
    sleep 0.01
  done
  fail "live flock helper did not become ready"
}

stop_flock() {
  kill "$flock_pid"
  wait "$flock_pid" 2>/dev/null || true
  flock_pid=""
}

file_metadata() {
  /usr/bin/python3 - "$1" <<'PY'
import json, os, sys
value = os.lstat(sys.argv[1])
print(json.dumps([value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
                  value.st_size, value.st_mtime_ns, value.st_ctime_ns]))
PY
}

graph_lock_pid=""
start_graph_lock() {
  local graph_runtime="$1"
  local graph_lock_path="$2"
  local ready="$TMP_ROOT/graph-protocol-lock.ready"
  /usr/bin/python3 - "$graph_runtime" "$graph_lock_path" "$ready" <<'PY' &
import importlib.util, pathlib, signal, sys
runtime, lock_path, ready = sys.argv[1:]
spec = importlib.util.spec_from_file_location("migration_graph_lock_holder", runtime)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
lock = module.DirectoryLock(pathlib.Path(lock_path), timeout=0.0)
lock.__enter__()
pathlib.Path(ready).touch()
try:
    signal.pause()
finally:
    lock.__exit__(None, None, None)
PY
  graph_lock_pid=$!
  for _ in $(seq 1 500); do
    [ -e "$ready" ] && return 0
    sleep 0.01
  done
  fail "production graph lock helper did not become ready"
}

stop_graph_lock() {
  kill "$graph_lock_pid"
  wait "$graph_lock_pid" 2>/dev/null || true
  graph_lock_pid=""
}

project="$TMP_ROOT/project"
repo="$project/code/app"
operator_dir="$project/operator"
mkdir -p "$repo" "$operator_dir/features/FS-0001" "$operator_dir/tasks/T-0001/handoffs" \
  "$operator_dir/roadmap/items" "$operator_dir/memory" "$operator_dir/catalog/roles"
git -C "$repo" init -b main >/dev/null

cat > "$repo/operator.config.env" <<EOF
PROJECT_NAME="migration-smoke"
PROJECT_ROOT="$project"
CODE_DIR="$project/code"
OPERATOR_DIR="$operator_dir"
TMUX_SESSION="aok-v5-migration-$$"
DEFAULT_BRANCH="main"
OPERATOR_KIT_VERSION="4"
OPERATOR_LANES='
operator|Codex Desktop|app|main|
'
EOF
printf '# V4 feature\n' > "$operator_dir/features/FS-0001/feature.md"
printf '# V4 task\n' > "$operator_dir/tasks/T-0001/task.md"
printf '# V4 handoff\n' > "$operator_dir/tasks/T-0001/handoffs/lane.md"
printf '# V4 roadmap\n' > "$operator_dir/roadmap/items/RM-0001.md"
printf '# V4 memory\n' > "$operator_dir/memory/project.md"
printf '# V4 Role\n\n- ID: custom\n' > "$operator_dir/catalog/roles/custom.md"

bash "$KIT_ROOT/scripts/operator-update.sh" --source "$KIT_ROOT" --channel latest --target "$repo" --no-fetch >/dev/null
grep -q 'OPERATOR_KIT_VERSION="4"' "$repo/operator.config.env" || fail "plain update migrated V4"
test -x "$repo/scripts/operator-v5-migrate.sh" || fail "plain update omitted migration tooling"
test ! -x "$repo/scripts/operator_v5_migrate.py" || fail "plain migration helper became executable"
test -f "$repo/.claude/commands/operator-open.md" || fail "plain update omitted final Claude host commands"
migration_status="$(OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-status.sh")"
grep -q 'Migration: required' <<<"$migration_status" || fail "status omitted migration required"

# The production launcher ignores Python startup injection before application
# imports, pins its interpreter, and replaces the caller's executable path.
mkdir -p "$TMP_ROOT/path-poison" "$TMP_ROOT/python-path-poison" "$TMP_ROOT/python-home-poison"
cat > "$TMP_ROOT/python-path-poison/sitecustomize.py" <<'PY'
import os
with open(os.environ["MIGRATION_PYTHONPATH_POISON_MARKER"], "w", encoding="utf-8") as marker:
    marker.write("poison imported\n")
PY
cat > "$TMP_ROOT/path-poison/python3" <<'SH'
#!/bin/sh
: > "${MIGRATION_PATH_POISON_MARKER:?}"
exit 0
SH
chmod +x "$TMP_ROOT/path-poison/python3"
/usr/bin/env PATH="$TMP_ROOT/path-poison" \
  PYTHONPATH="$TMP_ROOT/python-path-poison" PYTHONHOME="$TMP_ROOT/python-home-poison" \
  MIGRATION_PATH_POISON_MARKER="$TMP_ROOT/path-poison-ran" \
  MIGRATION_PYTHONPATH_POISON_MARKER="$TMP_ROOT/pythonpath-poison-ran" \
  OPERATOR_CONFIG="$repo/operator.config.env" /bin/bash "$repo/scripts/operator-v5-migrate.sh" plan \
  > "$TMP_ROOT/path-safe-plan.json"
test ! -e "$TMP_ROOT/path-poison-ran" || fail "PATH-provided python3 executed"
test ! -e "$TMP_ROOT/pythonpath-poison-ran" || fail "PYTHONPATH sitecustomize executed"
/usr/bin/python3 -m json.tool "$TMP_ROOT/path-safe-plan.json" >/dev/null

# Config, OPERATOR_DIR, legacy parents, and legacy leaves are all no-follow.
ln -s "$repo/operator.config.env" "$TMP_ROOT/config-link.env"
expect_refusal "symlinked config leaf" env OPERATOR_CONFIG="$TMP_ROOT/config-link.env" \
  /bin/bash "$repo/scripts/operator-v5-migrate.sh" plan
unlink "$TMP_ROOT/config-link.env"
ln -s "$operator_dir" "$TMP_ROOT/operator-link"
sed "s#OPERATOR_DIR=\"$operator_dir\"#OPERATOR_DIR=\"$TMP_ROOT/operator-link\"#" \
  "$repo/operator.config.env" > "$repo/symlink-root.config"
expect_refusal "symlinked OPERATOR_DIR root" env OPERATOR_CONFIG="$repo/symlink-root.config" \
  /bin/bash "$repo/scripts/operator-v5-migrate.sh" plan
unlink "$TMP_ROOT/operator-link"
rm "$repo/symlink-root.config"
mkdir "$TMP_ROOT/parent-poison"
mv "$operator_dir/tasks/T-0001" "$TMP_ROOT/T-0001-real"
ln -s "$TMP_ROOT/parent-poison" "$operator_dir/tasks/T-0001"
expect_refusal "symlinked legacy parent" env OPERATOR_CONFIG="$repo/operator.config.env" \
  /bin/bash "$repo/scripts/operator-v5-migrate.sh" plan
unlink "$operator_dir/tasks/T-0001"
mv "$TMP_ROOT/T-0001-real" "$operator_dir/tasks/T-0001"
mv "$operator_dir/tasks/T-0001/task.md" "$TMP_ROOT/task-real.md"
ln -s "$TMP_ROOT/task-real.md" "$operator_dir/tasks/T-0001/task.md"
expect_refusal "symlinked legacy leaf" env OPERATOR_CONFIG="$repo/operator.config.env" \
  /bin/bash "$repo/scripts/operator-v5-migrate.sh" plan
unlink "$operator_dir/tasks/T-0001/task.md"
mv "$TMP_ROOT/task-real.md" "$operator_dir/tasks/T-0001/task.md"

config_before="$(shasum -a 256 "$repo/operator.config.env")"
legacy_before="$(find "$operator_dir/features" "$operator_dir/tasks" "$operator_dir/roadmap" "$operator_dir/memory" "$operator_dir/catalog" -type f -exec shasum -a 256 {} \; | sort)"
OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-v5-migrate.sh" plan > "$TMP_ROOT/plan.json"
test "$config_before" = "$(shasum -a 256 "$repo/operator.config.env")" || fail "plan mutated config"
test ! -e "$operator_dir/migrations/v4-to-v5-manifest.json" || fail "plan wrote a manifest"

python3 - "$TMP_ROOT/plan.json" "$TMP_ROOT/mapping.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
assert plan["mutated"] is False
for category in ("config", "features", "tasks", "handoffs", "roadmap", "memory", "catalog"):
    assert category in plan["inventory"]["categories"]
mapping = plan["mappingTemplate"]
mapping.update({"reviewed": True, "reviewer": "migration-smoke", "reviewedAt": "2026-07-22T12:00:00Z"})
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(mapping, sort_keys=True, separators=(",", ":")) + "\n")
PY

# The reviewed artifact is one exact canonical byte string. A duplicate key
# cannot show an approved value first and smuggle a different last-key-wins
# value into apply, even when every other field and the authorization are valid.
/usr/bin/python3 - "$TMP_ROOT/mapping.json" "$TMP_ROOT/duplicate-mapping.json" <<'PY'
import pathlib, sys
source, target = map(pathlib.Path, sys.argv[1:])
raw = source.read_bytes()
assert raw.endswith(b"}\n")
target.write_bytes(raw[:-2] + b',"selectedUnfinishedScopes":["smuggled-scope"]}\n')
PY
expect_refusal "duplicate-key reviewed mapping" env OPERATOR_CONFIG="$repo/operator.config.env" \
  bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/duplicate-mapping.json" --authorize MIGRATE_V4_TO_V5
grep -q 'OPERATOR_KIT_VERSION="4"' "$repo/operator.config.env" || fail "duplicate mapping changed marker"
test ! -e "$operator_dir/migrations/v4-to-v5-manifest.json" || fail "duplicate mapping created manifest"

expect_refusal "missing authorization" env OPERATOR_CONFIG="$repo/operator.config.env" \
  bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize NO

python3 - "$TMP_ROOT/mapping.json" "$TMP_ROOT/unreviewed.json" "$TMP_ROOT/selected.json" <<'PY'
import json, sys
mapping = json.load(open(sys.argv[1], encoding="utf-8"))
unreviewed = dict(mapping, reviewed=False, reviewer="", reviewedAt="")
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(unreviewed, sort_keys=True, separators=(",", ":")) + "\n")
selected = dict(mapping, selectedUnfinishedScopes=["legacy-task"])
open(sys.argv[3], "w", encoding="utf-8").write(json.dumps(selected, sort_keys=True, separators=(",", ":")) + "\n")
PY
expect_refusal "unreviewed mapping" env OPERATOR_CONFIG="$repo/operator.config.env" \
  bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/unreviewed.json" --authorize MIGRATE_V4_TO_V5

# Reach the real dynamically loaded operator_graph.py with a reviewed mapping.
# Its boot/process lock identity lookups must not consume caller sysctl/ps
# shims, and the selected uninitialized scope still fails closed normally.
cat > "$TMP_ROOT/path-poison/sysctl" <<'SH'
#!/bin/sh
: > "${MIGRATION_SYSCTL_POISON_MARKER:?}"
printf '{ sec = 1, usec = 0 } Mon Jan  1 00:00:01 1970\n'
SH
cat > "$TMP_ROOT/path-poison/ps" <<'SH'
#!/bin/sh
: > "${MIGRATION_PS_POISON_MARKER:?}"
printf 'Mon Jan  1 00:00:01 1970\n'
SH
chmod +x "$TMP_ROOT/path-poison/sysctl" "$TMP_ROOT/path-poison/ps"
expect_refusal "isolated Python and graph utility path" /usr/bin/env \
  PATH="$TMP_ROOT/path-poison" \
  PYTHONPATH="$TMP_ROOT/python-path-poison" PYTHONHOME="$TMP_ROOT/python-home-poison" \
  MIGRATION_PATH_POISON_MARKER="$TMP_ROOT/path-poison-ran" \
  MIGRATION_PYTHONPATH_POISON_MARKER="$TMP_ROOT/pythonpath-poison-ran" \
  MIGRATION_SYSCTL_POISON_MARKER="$TMP_ROOT/sysctl-poison-ran" \
  MIGRATION_PS_POISON_MARKER="$TMP_ROOT/ps-poison-ran" \
  OPERATOR_CONFIG="$repo/operator.config.env" /bin/bash "$repo/scripts/operator-v5-migrate.sh" \
  apply --mapping "$TMP_ROOT/selected.json" --authorize MIGRATE_V4_TO_V5
for poison_marker in path-poison-ran pythonpath-poison-ran sysctl-poison-ran ps-poison-ran; do
  test ! -e "$TMP_ROOT/$poison_marker" || fail "migration consumed startup/PATH poison: $poison_marker"
done
grep -q 'OPERATOR_KIT_VERSION="4"' "$repo/operator.config.env" || fail "poison regression changed marker"
test ! -e "$operator_dir/migrations/v4-to-v5-manifest.json" || fail "poison regression created manifest"

# A symlinked migrations parent cannot escape the external workspace or flip
# the marker, even with a valid reviewed mapping and authorization.
mkdir "$TMP_ROOT/migration-escape"
mv "$operator_dir/migrations" "$TMP_ROOT/migrations-real"
ln -s "$TMP_ROOT/migration-escape" "$operator_dir/migrations"
expect_refusal "symlinked migrations escape" env OPERATOR_CONFIG="$repo/operator.config.env" \
  /bin/bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5
grep -q 'OPERATOR_KIT_VERSION="4"' "$repo/operator.config.env" || fail "migrations symlink flipped marker"
test ! -e "$TMP_ROOT/migration-escape/v4-to-v5-manifest.json" || fail "manifest escaped through migrations symlink"
unlink "$operator_dir/migrations"
mv "$TMP_ROOT/migrations-real" "$operator_dir/migrations"

# The migration-wide lock and every live writer family are rejected while held.
# Refusing on an existing migration lock must not normalize that inode's mode
# or change any other metadata before flock ownership is established.
migration_lock="$operator_dir/migrations/.v4-to-v5.lock"
printf 'existing migration lock payload\n' > "$migration_lock"
chmod 0644 "$migration_lock"
migration_lock_before="$(file_metadata "$migration_lock")"
migration_lock_digest="$(shasum -a 256 "$migration_lock")"
start_flock file "$migration_lock"
expect_refusal "concurrent migration flock" env OPERATOR_CONFIG="$repo/operator.config.env" \
  /bin/bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5
stop_flock
test "$migration_lock_before" = "$(file_metadata "$migration_lock")" || fail "refused migration changed existing migration-lock metadata"
test "$migration_lock_digest" = "$(shasum -a 256 "$migration_lock")" || fail "refused migration changed existing migration-lock contents"

# A live writer using the production graph directory-lock protocol excludes
# migration before validation or mutable graph/config commits.
start_graph_lock "$repo/scripts/operator_graph.py" "$operator_dir/graph/.lock"
expect_refusal "production graph transaction lock" env OPERATOR_CONFIG="$repo/operator.config.env" \
  /bin/bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5
grep -q 'OPERATOR_KIT_VERSION="4"' "$repo/operator.config.env" || fail "graph-lock refusal changed marker"
test ! -e "$operator_dir/migrations/v4-to-v5-manifest.json" || fail "graph-lock refusal created manifest"
stop_graph_lock
mkdir -p "$operator_dir/loop"
start_flock directory "$operator_dir/loop"
expect_refusal "live loop flock writer" env OPERATOR_CONFIG="$repo/operator.config.env" \
  /bin/bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5
stop_flock
mkdir -p "$operator_dir/host"
start_flock file "$operator_dir/host/mutation-effect.lock"
expect_refusal "live host flock writer" env OPERATOR_CONFIG="$repo/operator.config.env" \
  /bin/bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5
stop_flock
rm "$operator_dir/host/mutation-effect.lock"
start_flock file "$operator_dir/tasks/T-0001/writer.lock"
expect_refusal "live legacy flock writer" env OPERATOR_CONFIG="$repo/operator.config.env" \
  /bin/bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5
stop_flock
rm "$operator_dir/tasks/T-0001/writer.lock"

# Deterministic in-invocation interchanges after the first exact inventory
# cannot redirect root, parent, or leaf commit targets.
replacement_race_writer="$operator_dir/host/replacement-race-writer.lock"
printf 'replacement race writer lock\n' > "$replacement_race_writer"
chmod 0640 "$replacement_race_writer"
for lock_race_mode in \
  migration-lock-replace writer-lock-replace \
  migration-lock-exit-replace writer-lock-exit-replace; do
  /usr/bin/python3 "$KIT_ROOT/tests/smoke/v5-migration-races.py" "$lock_race_mode" \
    "$repo/scripts/operator_v5_migrate.py" "$repo/operator.config.env" "$TMP_ROOT/mapping.json" \
    "$repo/scripts" "$operator_dir"
done
rm "$replacement_race_writer"
for guard_swap_mode in \
  guard-acquire-root guard-acquire-graph guard-acquire-lock \
  guard-exit-root guard-exit-graph guard-exit-lock; do
  /usr/bin/python3 "$KIT_ROOT/tests/smoke/v5-migration-races.py" "$guard_swap_mode" \
    "$repo/scripts/operator_v5_migrate.py" "$repo/operator.config.env" "$TMP_ROOT/mapping.json" \
    "$repo/scripts" "$operator_dir"
done
for swap_mode in root parent leaf; do
  /usr/bin/python3 "$KIT_ROOT/tests/smoke/v5-migration-races.py" "$swap_mode" \
    "$repo/scripts/operator_v5_migrate.py" "$repo/operator.config.env" "$TMP_ROOT/mapping.json" \
    "$repo/scripts" "$operator_dir"
done
for graph_race_mode in graph-create graph-revision; do
  /usr/bin/python3 "$KIT_ROOT/tests/smoke/v5-migration-races.py" "$graph_race_mode" \
    "$repo/scripts/operator_v5_migrate.py" "$repo/operator.config.env" "$TMP_ROOT/mapping.json" \
    "$repo/scripts" "$operator_dir"
done
/usr/bin/python3 "$KIT_ROOT/tests/smoke/v5-migration-races.py" graph-state \
  "$repo/scripts/operator_v5_migrate.py" "$repo/operator.config.env" "$TMP_ROOT/selected.json" \
  "$repo/scripts" "$operator_dir"

chmod 0644 "$repo/scripts/operator-proof-broker.sh"
expect_refusal "unavailable broker" env OPERATOR_CONFIG="$repo/operator.config.env" \
  bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5
chmod 0755 "$repo/scripts/operator-proof-broker.sh"

printf '{}\n' > "$operator_dir/graph/definition.json"
expect_refusal "partial graph state" env OPERATOR_CONFIG="$repo/operator.config.env" \
  bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5
rm "$operator_dir/graph/definition.json"

expect_refusal "selected scope without trusted graph" env OPERATOR_CONFIG="$repo/operator.config.env" \
  bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/selected.json" --authorize MIGRATE_V4_TO_V5

printf 'changed after review\n' >> "$operator_dir/tasks/T-0001/task.md"
expect_refusal "changed inventory" env OPERATOR_CONFIG="$repo/operator.config.env" \
  bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5
printf '# V4 task\n' > "$operator_dir/tasks/T-0001/task.md"

mkdir "$operator_dir/graph/.lock"
expect_refusal "active writer lock" env OPERATOR_CONFIG="$repo/operator.config.env" \
  bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5
rmdir "$operator_dir/graph/.lock"

# Inspecting and acquiring a discovered, inactive writer lock must not create,
# chmod, truncate, replace, or otherwise mutate that existing lock inode.
preserved_lock="$operator_dir/host/preserved-writer.lock"
printf 'existing writer lock payload\n' > "$preserved_lock"
chmod 0640 "$preserved_lock"
preserved_lock_metadata="$(/usr/bin/python3 - "$preserved_lock" <<'PY'
import json, os, sys
value = os.lstat(sys.argv[1])
print(json.dumps([value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
                  value.st_size, value.st_mtime_ns, value.st_ctime_ns]))
PY
)"
preserved_lock_digest="$(shasum -a 256 "$preserved_lock")"

OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-v5-migrate.sh" apply \
  --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5 > "$TMP_ROOT/applied.json"
grep -q 'OPERATOR_KIT_VERSION="5"' "$repo/operator.config.env" || fail "successful migration did not change marker"
test "$preserved_lock_digest" = "$(shasum -a 256 "$preserved_lock")" || fail "writer-lock inspection changed its contents"
test "$preserved_lock_metadata" = "$(/usr/bin/python3 - "$preserved_lock" <<'PY'
import json, os, sys
value = os.lstat(sys.argv[1])
print(json.dumps([value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
                  value.st_size, value.st_mtime_ns, value.st_ctime_ns]))
PY
)" || fail "writer-lock inspection changed its inode metadata"
manifest="$operator_dir/migrations/v4-to-v5-manifest.json"
test -f "$manifest" || fail "migration manifest missing"
test "$(stat -f '%Lp' "$manifest")" = 600 || fail "migration manifest is not private"
test ! -e "$operator_dir/graph/.lock" || fail "migration left production graph lock state behind"
for graph_state_leaf in definition.json projection.json events.jsonl; do
  test ! -e "$operator_dir/graph/$graph_state_leaf" || fail "migration initialized graph state: $graph_state_leaf"
done
test ! -e "$operator_dir/authority/control-graph-public-key.json" || fail "migration initialized graph authority"
test "$legacy_before" = "$(find "$operator_dir/features" "$operator_dir/tasks" "$operator_dir/roadmap" "$operator_dir/memory" "$operator_dir/catalog" -type f -exec shasum -a 256 {} \; | sort)" || fail "migration changed V4 artifacts"
python3 - "$manifest" "$TMP_ROOT/mapping.json" <<'PY'
import hashlib, json, pathlib, sys
manifest_path, mapping_path = map(pathlib.Path, sys.argv[1:])
value = json.loads(manifest_path.read_bytes())
assert value["schemaVersion"] == "operator.v5-migration-manifest/v1"
assert value["sourceKitVersion"] == "4" and value["targetKitVersion"] == "5"
assert value["selectedUnfinishedScopes"] == []
assert value["graph"]["initialized"] is False
assert value["review"]["mappingSha256"] == "sha256:" + hashlib.sha256(mapping_path.read_bytes()).hexdigest()
for category in ("config", "features", "tasks", "handoffs", "roadmap", "memory", "catalog"):
    assert category in value["legacyInventory"]
PY

# A durable manifest is not permission to skip recovery validation. Restore the
# exact V4 marker to model a crash before the marker rename, then prove changed
# legacy bytes and newly selected untrusted scopes both refuse recovery.
cp "$manifest" "$TMP_ROOT/manifest-original.json"
/usr/bin/python3 - "$repo/operator.config.env" <<'PY'
from pathlib import Path
path = Path(__import__('sys').argv[1])
raw = path.read_text(encoding="utf-8")
assert raw.count('OPERATOR_KIT_VERSION="5"') == 1
path.write_text(raw.replace('OPERATOR_KIT_VERSION="5"', 'OPERATOR_KIT_VERSION="4"'), encoding="utf-8")
PY

# Partial recovery accepts only the exact canonical manifest emitted by the
# first phase. These payloads would all be accepted or normalized by permissive
# json.loads: duplicate keys, harmless-looking whitespace, int-as-float, and an
# ignored unknown field. Each must leave both the durable payload and V4 marker
# unchanged.
/usr/bin/python3 - "$TMP_ROOT/manifest-original.json" "$TMP_ROOT" <<'PY'
import json, pathlib, re, sys
source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
raw = source.read_bytes()
assert raw.endswith(b"}\n")
(target / "manifest-duplicate.json").write_bytes(
    raw[:-2] + b',"schemaVersion":"operator.v5-migration-manifest/v1"}\n')
(target / "manifest-noncanonical.json").write_bytes(b" " + raw)
floated, count = re.subn(rb'"bytes":([0-9]+)', lambda match: b'"bytes":' + match.group(1) + b'.0', raw, count=1)
assert count == 1
(target / "manifest-float.json").write_bytes(floated)
negative_zero, count = re.subn(rb'"bytes":([0-9]+)', b'"bytes":-0', raw, count=1)
assert count == 1
(target / "manifest-negative-zero.json").write_bytes(negative_zero)
constant, count = re.subn(rb'"bytes":([0-9]+)', b'"bytes":NaN', raw, count=1)
assert count == 1
(target / "manifest-constant.json").write_bytes(constant)
value = json.loads(raw)
value["unexpected"] = False
(target / "manifest-unknown.json").write_text(
    json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
value = json.loads(raw)
value["review"]["reviewer"] += "\x7f"
(target / "manifest-control.json").write_text(
    json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n", encoding="utf-8")
value = json.loads(raw)
value["graph"]["initialized"] = 0
(target / "manifest-wrong-type.json").write_text(
    json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
for hostile_manifest in duplicate noncanonical float negative-zero constant unknown control wrong-type; do
  cp "$TMP_ROOT/manifest-$hostile_manifest.json" "$manifest"
  hostile_manifest_digest="$(shasum -a 256 "$manifest")"
  expect_refusal "partial recovery $hostile_manifest manifest" env OPERATOR_CONFIG="$repo/operator.config.env" \
    /bin/bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5
  grep -q 'OPERATOR_KIT_VERSION="4"' "$repo/operator.config.env" || fail "$hostile_manifest manifest changed marker"
  test "$hostile_manifest_digest" = "$(shasum -a 256 "$manifest")" || fail "$hostile_manifest manifest was rewritten"
done
cp "$TMP_ROOT/manifest-original.json" "$manifest"

printf 'partial recovery drift\n' >> "$operator_dir/tasks/T-0001/task.md"
expect_refusal "partial recovery changed legacy inventory" env OPERATOR_CONFIG="$repo/operator.config.env" \
  /bin/bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5
printf '# V4 task\n' > "$operator_dir/tasks/T-0001/task.md"
OPERATOR_CONFIG="$repo/operator.config.env" /bin/bash "$repo/scripts/operator-v5-migrate.sh" apply \
  --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5 > "$TMP_ROOT/recovered.json"
grep -q '"recoveredPartialApply":true' "$TMP_ROOT/recovered.json" || fail "exact partial recovery was not reported"

/usr/bin/python3 - "$repo/operator.config.env" "$manifest" <<'PY'
import json, pathlib, sys
config_path, manifest_path = map(pathlib.Path, sys.argv[1:])
raw = config_path.read_text(encoding="utf-8")
config_path.write_text(raw.replace('OPERATOR_KIT_VERSION="5"', 'OPERATOR_KIT_VERSION="4"'), encoding="utf-8")
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest["graph"]["revision"] = 999
manifest_path.write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
expect_refusal "partial recovery graph identity/revision drift" env OPERATOR_CONFIG="$repo/operator.config.env" \
  /bin/bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5
cp "$TMP_ROOT/manifest-original.json" "$manifest"

/usr/bin/python3 - "$repo/operator.config.env" "$TMP_ROOT/mapping.json" "$TMP_ROOT/selected-partial.json" \
  "$manifest" <<'PY'
import hashlib, json, pathlib, sys
config_path, mapping_path, selected_path, manifest_path = map(pathlib.Path, sys.argv[1:])
raw = config_path.read_text(encoding="utf-8")
config_path.write_text(raw.replace('OPERATOR_KIT_VERSION="5"', 'OPERATOR_KIT_VERSION="4"'), encoding="utf-8")
mapping = json.loads(mapping_path.read_text(encoding="utf-8"))
mapping["selectedUnfinishedScopes"] = ["unknown-partial-scope"]
encoded_mapping = (json.dumps(mapping, sort_keys=True, separators=(",", ":")) + "\n").encode()
selected_path.write_bytes(encoded_mapping)
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest["selectedUnfinishedScopes"] = mapping["selectedUnfinishedScopes"]
manifest["review"]["mappingSha256"] = "sha256:" + hashlib.sha256(encoded_mapping).hexdigest()
manifest_path.write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
expect_refusal "partial recovery selected scope revalidation" env OPERATOR_CONFIG="$repo/operator.config.env" \
  /bin/bash "$repo/scripts/operator-v5-migrate.sh" apply --mapping "$TMP_ROOT/selected-partial.json" --authorize MIGRATE_V4_TO_V5
cp "$TMP_ROOT/manifest-original.json" "$manifest"
/usr/bin/python3 - "$repo/operator.config.env" <<'PY'
from pathlib import Path
path = Path(__import__('sys').argv[1])
raw = path.read_text(encoding="utf-8")
path.write_text(raw.replace('OPERATOR_KIT_VERSION="4"', 'OPERATOR_KIT_VERSION="5"'), encoding="utf-8")
PY

chmod 0644 "$migration_lock"
repeated_lock_before="$(file_metadata "$migration_lock")"
repeated_lock_digest="$(shasum -a 256 "$migration_lock")"
OPERATOR_CONFIG="$repo/operator.config.env" bash "$repo/scripts/operator-v5-migrate.sh" apply \
  --mapping "$TMP_ROOT/mapping.json" --authorize MIGRATE_V4_TO_V5 > "$TMP_ROOT/repeated.json"
grep -q '"alreadyApplied":true' "$TMP_ROOT/repeated.json" || fail "migration rerun was not idempotent"
test "$repeated_lock_before" = "$(file_metadata "$migration_lock")" || fail "repeated migration changed existing migration-lock metadata"
test "$repeated_lock_digest" = "$(shasum -a 256 "$migration_lock")" || fail "repeated migration changed existing migration-lock contents"

# Unsafe repo-local state and ambiguous config both fail before mutation.
unsafe_repo="$TMP_ROOT/unsafe"
mkdir -p "$unsafe_repo/operator"
git -C "$unsafe_repo" init -b main >/dev/null
sed -e "s#PROJECT_ROOT=\"$project\"#PROJECT_ROOT=\"$unsafe_repo\"#" \
  -e "s#CODE_DIR=\"$project/code\"#CODE_DIR=\"$unsafe_repo\"#" \
  -e "s#OPERATOR_DIR=\"$operator_dir\"#OPERATOR_DIR=\"$unsafe_repo/operator\"#" \
  -e 's/OPERATOR_KIT_VERSION="5"/OPERATOR_KIT_VERSION="4"/' \
  "$repo/operator.config.env" > "$unsafe_repo/operator.config.env"
expect_refusal "repo-local OPERATOR_DIR" env OPERATOR_CONFIG="$unsafe_repo/operator.config.env" \
  bash "$repo/scripts/operator-v5-migrate.sh" plan
printf 'OPERATOR_KIT_VERSION="4"\n' >> "$unsafe_repo/operator.config.env"
expect_refusal "ambiguous config" env OPERATOR_CONFIG="$unsafe_repo/operator.config.env" \
  bash "$repo/scripts/operator-v5-migrate.sh" plan

# A plain latest update may refresh repo-local scripts for a legacy V4 project,
# but it must not create V5 control-plane state inside that repository.
repo_local="$TMP_ROOT/repo-local"
mkdir -p "$repo_local/operator"
git -C "$repo_local" init -b main >/dev/null
cat > "$repo_local/operator.config.env" <<EOF
PROJECT_NAME="repo-local-update-smoke"
PROJECT_ROOT="$repo_local"
CODE_DIR="$repo_local"
OPERATOR_DIR="$repo_local/operator"
TMUX_SESSION="aok-v5-repo-local-$$"
DEFAULT_BRANCH="main"
OPERATOR_KIT_VERSION="4"
OPERATOR_LANES='
operator|Codex Desktop|app|main|
'
EOF
/bin/bash "$KIT_ROOT/scripts/operator-update.sh" --source "$KIT_ROOT" --channel latest \
  --target "$repo_local" --no-fetch > "$TMP_ROOT/repo-local-update.out"
grep -q 'OPERATOR_KIT_VERSION="4"' "$repo_local/operator.config.env" || fail "repo-local update changed V4 marker"
grep -q 'relocation/migration blocked' "$TMP_ROOT/repo-local-update.out" || fail "repo-local update omitted blocked report"
for forbidden_root in authority graph host loop migrations prompts; do
  test ! -e "$repo_local/operator/$forbidden_root" || fail "repo-local update created V5 state: $forbidden_root"
done
repo_local_status="$(OPERATOR_CONFIG="$repo_local/operator.config.env" /bin/bash "$repo_local/scripts/operator-status.sh")"
grep -q 'Migration: blocked (relocate OPERATOR_DIR outside repository' <<<"$repo_local_status" || fail "status omitted repo-local relocation block"

# Both shell-safe marker quote forms have identical plan/apply semantics.
single_project="$TMP_ROOT/single-quote-project"
single_repo="$single_project/code/app"
single_operator="$single_project/operator"
mkdir -p "$single_repo" "$single_operator/features/FS-0001" "$single_operator/tasks/T-0001" \
  "$single_operator/roadmap" "$single_operator/memory" "$single_operator/catalog"
git -C "$single_repo" init -b main >/dev/null
cat > "$single_repo/operator.config.env" <<EOF
PROJECT_NAME="single-quote-migration"
PROJECT_ROOT="$single_project"
CODE_DIR="$single_project/code"
OPERATOR_DIR="$single_operator"
TMUX_SESSION="aok-v5-single-quote-$$"
DEFAULT_BRANCH="main"
OPERATOR_KIT_VERSION='4'
OPERATOR_LANES='
operator|Codex Desktop|app|main|
'
EOF
printf '# Single quote task\n' > "$single_operator/tasks/T-0001/task.md"
/bin/bash "$KIT_ROOT/scripts/operator-update.sh" --source "$KIT_ROOT" --channel latest \
  --target "$single_repo" --no-fetch >/dev/null
OPERATOR_CONFIG="$single_repo/operator.config.env" /bin/bash "$single_repo/scripts/operator-v5-migrate.sh" plan \
  > "$TMP_ROOT/single-plan.json"
/usr/bin/python3 - "$TMP_ROOT/single-plan.json" "$TMP_ROOT/single-mapping.json" <<'PY'
import json, pathlib, sys
plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
mapping = plan["mappingTemplate"]
mapping.update({"reviewed": True, "reviewer": "single-quote-smoke", "reviewedAt": "2026-07-22T13:00:00Z"})
pathlib.Path(sys.argv[2]).write_text(json.dumps(mapping, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
OPERATOR_CONFIG="$single_repo/operator.config.env" /bin/bash "$single_repo/scripts/operator-v5-migrate.sh" apply \
  --mapping "$TMP_ROOT/single-mapping.json" --authorize MIGRATE_V4_TO_V5 >/dev/null
grep -q "OPERATOR_KIT_VERSION='5'" "$single_repo/operator.config.env" || fail "single-quoted V4 marker did not migrate consistently"

printf 'operator v5 migration smoke ok\n'
