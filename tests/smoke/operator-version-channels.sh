#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d /tmp/aok-channel-smoke.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

snapshot_roots() {
  /usr/bin/python3 - "$@" <<'PY'
import hashlib
import json
import os
import stat
import sys


def metadata(path):
    info = os.lstat(path)
    value = {
        "dev": info.st_dev,
        "ino": info.st_ino,
        "mode": info.st_mode,
        "nlink": info.st_nlink,
        "uid": info.st_uid,
        "gid": info.st_gid,
        "size": info.st_size,
        "mtime_ns": info.st_mtime_ns,
        "ctime_ns": info.st_ctime_ns,
    }
    if stat.S_ISREG(info.st_mode):
        digest = hashlib.sha256()
        with open(path, "rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        value["sha256"] = digest.hexdigest()
    elif stat.S_ISLNK(info.st_mode):
        value["target"] = os.readlink(path)
    return value


result = {}
for raw_root in sys.argv[1:]:
    root = os.path.abspath(raw_root)
    entries = {".": metadata(root)}
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        for name in directories + files:
            path = os.path.join(current, name)
            entries[os.path.relpath(path, root)] = metadata(path)
    result[root] = entries
json.dump(result, sys.stdout, sort_keys=True, separators=(",", ":"))
print()
PY
}

assert_snapshot() {
  local label="$1"
  local baseline="$2"
  local actual="$3"
  if ! cmp -s "$baseline" "$actual"; then
    diff -u "$baseline" "$actual" >&2 || true
    fail "$label changed minimal-install bytes, metadata, or topology"
  fi
}

assert_minimal_install_unmaterialized() {
  local label="$1"
  local path

  for path in \
    "$minimal_repo/scripts" \
    "$minimal_repo/schemas" \
    "$minimal_repo/.claude" \
    "$minimal_repo/.cursor" \
    "$minimal_repo/.gitignore" \
    "$minimal_repo/AGENTS.md" \
    "$minimal_repo/CODEX.md" \
    "$minimal_repo/CLAUDE.md" \
    "$minimal_operator/tasks" \
    "$minimal_operator/captures" \
    "$minimal_operator/memory" \
    "$minimal_operator/features" \
    "$minimal_operator/roadmap" \
    "$minimal_operator/catalog" \
    "$minimal_operator/authority" \
    "$minimal_operator/graph" \
    "$minimal_operator/host" \
    "$minimal_operator/loop" \
    "$minimal_operator/migrations" \
    "$minimal_operator/prompts" \
    "$minimal_operator/README.md"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "$label materialized $path"
  done
}

stable_project="$tmp_root/stable"
v3_project="$tmp_root/v3"
latest_project="$tmp_root/latest"
mkdir -p "$stable_project" "$v3_project" "$latest_project"

bash "$KIT_ROOT/scripts/operator-sync.sh" \
  --source "$KIT_ROOT" \
  --channel stable \
  --target "$stable_project" \
  --bootstrap-if-missing \
  --skip-skills \
  --skip-checks \
  --no-fetch >/dev/null

stable_repo="$stable_project/code/app"
grep -q 'OPERATOR_KIT_VERSION="2"' "$stable_repo/operator.config.env"
test ! -f "$stable_repo/scripts/operator-feature.sh"

bash "$KIT_ROOT/scripts/operator-sync.sh" \
  --source "$KIT_ROOT" \
  --channel v3 \
  --target "$v3_project" \
  --bootstrap-if-missing \
  --skip-skills \
  --skip-checks \
  --no-fetch >/dev/null

v3_repo="$v3_project/code/app"
grep -q 'OPERATOR_KIT_VERSION="2"' "$v3_repo/operator.config.env"
test ! -f "$v3_repo/scripts/operator-v5-migrate.sh"

bash "$KIT_ROOT/scripts/operator-sync.sh" \
  --source "$KIT_ROOT" \
  --channel latest \
  --target "$latest_project" \
  --bootstrap-if-missing \
  --skip-skills \
  --skip-checks \
  --no-fetch >/dev/null

latest_repo="$latest_project/code/app"
grep -q 'OPERATOR_KIT_VERSION="5"' "$latest_repo/operator.config.env"
test -f "$latest_repo/scripts/operator-feature.sh"
test -f "$latest_repo/scripts/operator-v5-migrate.sh"
test "$(find "$latest_repo/schemas/operator-v5" -type f | wc -l | tr -d ' ')" = 11
test -f "$latest_project/operator/features/active.md"

# A config-only installation is deliberately missing every generated repo and
# OPERATOR_DIR child. Dry-run must report all decisions without using mkdir,
# chmod, copies, or state initializers to fill those gaps. Snapshot inode and
# ctime as well as content so replace-with-identical and transient topology
# changes cannot pass as read-only behavior.
minimal_repo="$tmp_root/minimal/code/app"
minimal_operator="$tmp_root/minimal/operator"
minimal_codex_home="$tmp_root/minimal/codex-home"
mkdir -p "$minimal_repo" "$minimal_operator"
minimal_repo="$(cd "$minimal_repo" && pwd -P)"
minimal_operator="$(cd "$minimal_operator" && pwd -P)"
git -C "$minimal_repo" init -b main >/dev/null
git -C "$minimal_repo" config user.email smoke@example.com
git -C "$minimal_repo" config user.name "Smoke Test"
cat > "$minimal_repo/operator.config.env" <<EOF
PROJECT_NAME="dry-run-minimal"
PROJECT_ROOT="$minimal_repo"
CODE_DIR="$minimal_repo"
OPERATOR_DIR="$minimal_operator"
TMUX_SESSION="dry-run-minimal"
DEFAULT_BRANCH="main"
OPERATOR_LANES="backend"
OPERATOR_KIT_VERSION='4'
EOF
printf 'repo sentinel\n' > "$minimal_repo/sentinel.txt"
printf 'operator sentinel\n' > "$minimal_operator/sentinel.txt"
chmod 0640 "$minimal_repo/sentinel.txt" "$minimal_operator/sentinel.txt"
chmod 0710 "$minimal_operator"
git -C "$minimal_repo" add operator.config.env sentinel.txt
git -C "$minimal_repo" commit -m 'minimal operator install' >/dev/null

minimal_baseline="$tmp_root/minimal-baseline.json"
minimal_actual="$tmp_root/minimal-actual.json"
snapshot_roots "$minimal_repo" "$minimal_operator" > "$minimal_baseline"

update_output="$(bash "$KIT_ROOT/scripts/operator-update.sh" \
  --source "$KIT_ROOT" \
  --channel latest \
  --target "$minimal_repo" \
  --dry-run \
  --no-fetch 2>&1)"
printf '%s\n' "$update_output" | grep -q 'Mode: dry run' || fail "update did not report dry-run mode"
printf '%s\n' "$update_output" | grep -q 'scripts/operator-lib.sh' || fail "update did not report missing script decisions"
printf '%s\n' "$update_output" | grep -q 'OPERATOR_DIR/README.md' || fail "update did not report missing external workspace decisions"
printf '%s\n' "$update_output" | grep -q 'OPERATOR_DIR/prompts/design-proposal.md' || fail "update did not report missing V5 prompt restoration"
snapshot_roots "$minimal_repo" "$minimal_operator" > "$minimal_actual"
assert_snapshot "operator-update --dry-run" "$minimal_baseline" "$minimal_actual"
assert_minimal_install_unmaterialized "operator-update --dry-run"

sync_output="$(bash "$KIT_ROOT/scripts/operator-sync.sh" \
  --source "$KIT_ROOT" \
  --channel latest \
  --target "$minimal_repo" \
  --codex-home "$minimal_codex_home" \
  --dry-run \
  --no-fetch \
  --skip-checks 2>&1)"
printf '%s\n' "$sync_output" | grep -q 'Mode: dry run' || fail "sync did not report dry-run mode"
printf '%s\n' "$sync_output" | grep -q '## Project Update' || fail "sync did not compose the project update"
printf '%s\n' "$sync_output" | grep -q 'OPERATOR_DIR/prompts/design-proposal.md' || fail "sync did not preserve update planning output"
test ! -e "$minimal_codex_home" || fail "sync dry-run created Codex home state"
snapshot_roots "$minimal_repo" "$minimal_operator" > "$minimal_actual"
assert_snapshot "operator-sync --dry-run" "$minimal_baseline" "$minimal_actual"
assert_minimal_install_unmaterialized "operator-sync --dry-run"

upgrade_output="$(bash "$KIT_ROOT/scripts/operator-upgrade.sh" \
  --source "$KIT_ROOT" \
  --channel latest \
  --target "$minimal_repo" \
  --codex-home "$minimal_codex_home" \
  --dry-run \
  --no-fetch \
  --skip-checks 2>&1)"
printf '%s\n' "$upgrade_output" | grep -q 'Mode: dry run' || fail "upgrade did not report dry-run mode"
printf '%s\n' "$upgrade_output" | grep -q 'Projects processed: 1' || fail "upgrade did not compose sync/update for the target"
printf '%s\n' "$upgrade_output" | grep -q 'OPERATOR_DIR/prompts/design-proposal.md' || fail "upgrade did not preserve nested update planning output"
test ! -e "$minimal_codex_home" || fail "upgrade dry-run created Codex home state"
snapshot_roots "$minimal_repo" "$minimal_operator" > "$minimal_actual"
assert_snapshot "operator-upgrade --dry-run" "$minimal_baseline" "$minimal_actual"
assert_minimal_install_unmaterialized "operator-upgrade --dry-run"

dry_bootstrap_root="$tmp_root/dry-bootstrap"
mkdir -p "$dry_bootstrap_root"
snapshot_roots "$dry_bootstrap_root" > "$minimal_baseline"
dry_bootstrap_output="$(bash "$KIT_ROOT/scripts/operator-sync.sh" \
  --source "$KIT_ROOT" \
  --channel latest \
  --target "$dry_bootstrap_root" \
  --bootstrap-if-missing \
  --skip-skills \
  --skip-checks \
  --dry-run \
  --no-fetch 2>&1)"
printf '%s\n' "$dry_bootstrap_output" | grep -q 'Would initialize a git repository and bootstrap Operator Kit' || fail "sync did not report a planned empty-root bootstrap"
snapshot_roots "$dry_bootstrap_root" > "$minimal_actual"
assert_snapshot "operator-sync --bootstrap-if-missing --dry-run" "$minimal_baseline" "$minimal_actual"

printf 'version channel smoke ok: %s\n' "$tmp_root"
