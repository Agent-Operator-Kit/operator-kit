#!/usr/bin/env bash

# Shared helpers for Agent Operator Kit scripts.

operator_restore_design_prompt() {
  local operator_root="$1"
  local source_prompt="$2"
  local dry_run="${3:-0}"

  if [ ! -x /usr/bin/python3 ]; then
    printf 'Pinned Python interpreter is unavailable: /usr/bin/python3\n' >&2
    return 1
  fi

  (
    unset PYTHONPATH PYTHONHOME
    PATH='/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin'
    export PATH
    exec /usr/bin/python3 -E -s - "$operator_root" "$source_prompt" "$dry_run" <<'PY'
import contextlib
import os
from pathlib import Path
import stat
import sys
import uuid


DIRECTORY_FLAGS = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
FILE_FLAGS = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
MAX_PROMPT_BYTES = 4 * 1024 * 1024


class PromptSafetyError(Exception):
    pass


def fail(message):
    raise PromptSafetyError(message)


def safe_component(value, label):
    if not value or value in {".", ".."} or "/" in value or "\x00" in value:
        fail(f"{label} contains an unsafe path component")
    return value


def open_absolute_directory(raw_path, label):
    path = Path(os.path.abspath(os.path.expanduser(raw_path)))
    descriptor = os.open("/", DIRECTORY_FLAGS)
    try:
        for component in path.parts[1:]:
            safe_component(component, label)
            before = os.stat(component, dir_fd=descriptor, follow_symlinks=False)
            if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
                fail(f"{label} traverses a symlink or non-directory: {path}")
            child = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            actual = os.fstat(child)
            if ((actual.st_dev, actual.st_ino) != (before.st_dev, before.st_ino)
                    or not stat.S_ISDIR(actual.st_mode)):
                os.close(child)
                fail(f"{label} changed during descriptor traversal: {path}")
            os.close(descriptor)
            descriptor = child
        root_info = os.fstat(descriptor)
        if root_info.st_uid != os.geteuid():
            fail(f"{label} is not owned by the current user: {path}")
        return path, descriptor, (root_info.st_dev, root_info.st_ino)
    except BaseException:
        with contextlib.suppress(OSError):
            os.close(descriptor)
        raise


def verify_absolute_directory(path, identity, label):
    reopened_path, descriptor, reopened_identity = open_absolute_directory(str(path), label)
    try:
        if reopened_path != path or reopened_identity != identity:
            fail(f"{label} was interchanged during prompt restoration: {path}")
    finally:
        os.close(descriptor)


def read_source_prompt(raw_path):
    path = Path(os.path.abspath(os.path.expanduser(raw_path)))
    parent_path, parent_fd, _identity = open_absolute_directory(str(path.parent), "design prompt source parent")
    descriptor = None
    try:
        leaf = safe_component(path.name, "design prompt source")
        before = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
        if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
                or before.st_uid != os.geteuid() or before.st_nlink != 1
                or before.st_size > MAX_PROMPT_BYTES):
            fail(f"design prompt source is not a safe owned regular file: {path}")
        descriptor = os.open(leaf, FILE_FLAGS, dir_fd=parent_fd)
        actual = os.fstat(descriptor)
        if ((actual.st_dev, actual.st_ino) != (before.st_dev, before.st_ino)
                or not stat.S_ISREG(actual.st_mode) or actual.st_uid != os.geteuid()
                or actual.st_nlink != 1 or actual.st_size > MAX_PROMPT_BYTES):
            fail(f"design prompt source changed during descriptor open: {path}")
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, MAX_PROMPT_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_PROMPT_BYTES:
                fail(f"design prompt source exceeds {MAX_PROMPT_BYTES} bytes: {path}")
        final = os.fstat(descriptor)
        if ((final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns)
                != (actual.st_dev, actual.st_ino, actual.st_size, actual.st_mtime_ns)
                or total != final.st_size):
            fail(f"design prompt source changed during descriptor read: {path}")
        return b"".join(chunks)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent_fd)


def open_prompts_directory(root_fd, create):
    try:
        before = os.stat("prompts", dir_fd=root_fd, follow_symlinks=False)
    except FileNotFoundError:
        if not create:
            return None
        os.mkdir("prompts", 0o700, dir_fd=root_fd)
        os.fsync(root_fd)
        before = os.stat("prompts", dir_fd=root_fd, follow_symlinks=False)
    if (not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode)
            or before.st_uid != os.geteuid()):
        fail("OPERATOR_DIR/prompts must be an owned real directory")
    descriptor = os.open("prompts", DIRECTORY_FLAGS, dir_fd=root_fd)
    actual = os.fstat(descriptor)
    if ((actual.st_dev, actual.st_ino) != (before.st_dev, before.st_ino)
            or not stat.S_ISDIR(actual.st_mode) or actual.st_uid != os.geteuid()):
        os.close(descriptor)
        fail("OPERATOR_DIR/prompts changed during descriptor open")
    return descriptor


def inspect_leaf(prompts_fd):
    try:
        before = os.stat("design-proposal.md", dir_fd=prompts_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
            or before.st_uid != os.geteuid() or before.st_nlink != 1):
        fail("OPERATOR_DIR/prompts/design-proposal.md must be an owned single-link regular file")
    descriptor = os.open("design-proposal.md", FILE_FLAGS, dir_fd=prompts_fd)
    try:
        actual = os.fstat(descriptor)
        if ((actual.st_dev, actual.st_ino) != (before.st_dev, before.st_ino)
                or not stat.S_ISREG(actual.st_mode) or actual.st_uid != os.geteuid()
                or actual.st_nlink != 1):
            fail("OPERATOR_DIR/prompts/design-proposal.md changed during descriptor open")
    finally:
        os.close(descriptor)
    return before


def restore(operator_raw, source_raw, dry_run):
    root_path, root_fd, root_identity = open_absolute_directory(operator_raw, "OPERATOR_DIR")
    prompts_fd = None
    temporary = None
    temporary_fd = None
    try:
        prompts_fd = open_prompts_directory(root_fd, create=not dry_run)
        if prompts_fd is None:
            return "planned"
        existing = inspect_leaf(prompts_fd)
        if existing is not None:
            verify_absolute_directory(root_path, root_identity, "OPERATOR_DIR")
            return "preserved"
        if dry_run:
            verify_absolute_directory(root_path, root_identity, "OPERATOR_DIR")
            return "planned"

        data = read_source_prompt(source_raw)
        os.fchmod(prompts_fd, 0o700)
        temporary = f".design-proposal.md.tmp.{os.getpid()}.{uuid.uuid4()}"
        temporary_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                               | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=prompts_fd)
        written = 0
        while written < len(data):
            count = os.write(temporary_fd, data[written:])
            if count <= 0:
                fail("short write while restoring the external design prompt")
            written += count
        os.fchmod(temporary_fd, 0o644)
        os.fsync(temporary_fd)
        staged = os.fstat(temporary_fd)
        verify_absolute_directory(root_path, root_identity, "OPERATOR_DIR")
        try:
            os.link(temporary, "design-proposal.md", src_dir_fd=prompts_fd,
                    dst_dir_fd=prompts_fd, follow_symlinks=False)
        except FileExistsError:
            fail("OPERATOR_DIR/prompts/design-proposal.md appeared during restoration")
        published = os.stat("design-proposal.md", dir_fd=prompts_fd, follow_symlinks=False)
        if ((published.st_dev, published.st_ino) != (staged.st_dev, staged.st_ino)
                or not stat.S_ISREG(published.st_mode) or published.st_uid != os.geteuid()
                or published.st_nlink != 2 or stat.S_IMODE(published.st_mode) != 0o644):
            fail("restored design prompt did not retain its staged inode and safe mode")
        os.fsync(prompts_fd)
        os.unlink(temporary, dir_fd=prompts_fd)
        temporary = None
        os.fsync(prompts_fd)
        final_leaf = os.stat("design-proposal.md", dir_fd=prompts_fd, follow_symlinks=False)
        final_descriptor = os.fstat(temporary_fd)
        if ((final_leaf.st_dev, final_leaf.st_ino) != (staged.st_dev, staged.st_ino)
                or (final_descriptor.st_dev, final_descriptor.st_ino) != (staged.st_dev, staged.st_ino)
                or final_leaf.st_nlink != 1 or final_descriptor.st_nlink != 1
                or stat.S_IMODE(final_leaf.st_mode) != 0o644):
            fail("restored design prompt changed during final publication")
        verify_absolute_directory(root_path, root_identity, "OPERATOR_DIR")
        return "installed"
    finally:
        if temporary_fd is not None:
            with contextlib.suppress(OSError):
                os.close(temporary_fd)
        if temporary is not None and prompts_fd is not None:
            with contextlib.suppress(OSError):
                os.unlink(temporary, dir_fd=prompts_fd)
        if prompts_fd is not None:
            os.close(prompts_fd)
        os.close(root_fd)


try:
    if len(sys.argv) != 4 or sys.argv[3] not in {"0", "1"}:
        fail("invalid anchored design-prompt restoration arguments")
    print(restore(sys.argv[1], sys.argv[2], sys.argv[3] == "1"))
except (PromptSafetyError, OSError, ValueError) as error:
    print(f"Unsafe external design prompt boundary: {error}", file=sys.stderr)
    raise SystemExit(4)
PY
  )
}

operator_repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$script_dir/.." && pwd
}

operator_config_file() {
  printf '%s\n' "${OPERATOR_CONFIG:-$(pwd)/operator.config.env}"
}

operator_load_config() {
  local config_file="${1:-$(operator_config_file)}"
  if [ ! -f "$config_file" ]; then
    printf 'Missing operator config: %s\n' "$config_file" >&2
    printf 'Run: bash scripts/operator-bootstrap.sh /path/to/repo\n' >&2
    return 1
  fi

  # shellcheck source=/dev/null
  source "$config_file"

  : "${PROJECT_NAME:?PROJECT_NAME is required}"
  : "${PROJECT_ROOT:?PROJECT_ROOT is required}"
  : "${CODE_DIR:?CODE_DIR is required}"
  : "${OPERATOR_DIR:?OPERATOR_DIR is required}"
  : "${TMUX_SESSION:?TMUX_SESSION is required}"
  : "${DEFAULT_BRANCH:=main}"
  : "${OPERATOR_KIT_VERSION:=2}"
  : "${OPERATOR_LANES:?OPERATOR_LANES is required}"
}

operator_kit_version() {
  printf '%s\n' "${OPERATOR_KIT_VERSION:-2}"
}

operator_dir_is_repo_local() {
  local repo_root operator_root
  repo_root="$(cd "$(operator_repo_root)" 2>/dev/null && pwd -P)" || return 1
  operator_root="$(cd "$OPERATOR_DIR" 2>/dev/null && pwd -P)" || return 1
  case "$operator_root" in
    "$repo_root"|"$repo_root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

operator_v5_migration_state() {
  case "$(operator_kit_version)" in
    5.1)
      if [ -f "$OPERATOR_DIR/migrations/to-v5.1-local-graph.json" ]; then
        printf 'complete (V5.1 manifest present)\n'
      else
        printf 'not required (native V5.1 install)\n'
      fi
      ;;
    5)
      printf 'required (run operator-v5-1-migrate.sh plan; signed V5 remains unchanged)\n'
      ;;
    4)
      if [ -f "$(operator_repo_root)/scripts/operator-v5-1-migrate.sh" ]; then
        printf 'required (run operator-v5-1-migrate.sh plan; update did not migrate)\n'
      else
        printf 'V5.1 tooling not installed\n'
      fi
      ;;
    *) printf 'not applicable to legacy channel\n' ;;
  esac
}

operator_v5_graph_state() {
  if [ "$(operator_kit_version)" = "5.1" ]; then
    local count
    count="$(find "$OPERATOR_DIR/features" -mindepth 2 -maxdepth 2 -type f -name graph.json 2>/dev/null | wc -l | tr -d ' ')"
    printf 'local advisory (%s feature graph%s; no credentials required)\n' "$count" "$([ "$count" = "1" ] || printf s)"
    return 0
  fi
  local graph="$OPERATOR_DIR/graph"
  local authority="$OPERATOR_DIR/authority/control-graph-public-key.json"
  local material=0
  if [ -e "$authority" ] || [ -L "$authority" ]; then material=1; fi
  if [ -e "$graph/definition.json" ] || [ -L "$graph/definition.json" ]; then material=1; fi
  if [ -e "$graph/projection.json" ] || [ -L "$graph/projection.json" ]; then material=1; fi
  if [ -e "$graph/events.jsonl" ] || [ -L "$graph/events.jsonl" ]; then material=1; fi
  if [ "$material" -eq 0 ]; then
    printf 'signed V5 not initialized\n'
  elif [ -f "$authority" ] && [ ! -L "$authority" ] \
    && [ -f "$graph/definition.json" ] && [ ! -L "$graph/definition.json" ] \
    && [ -f "$graph/projection.json" ] && [ ! -L "$graph/projection.json" ] \
    && [ -s "$graph/events.jsonl" ] && [ ! -L "$graph/events.jsonl" ]; then
    printf 'signed V5 initialized (migration archives this state)\n'
  else
    printf 'signed V5 incomplete (migration plan will report it)\n'
  fi
}

operator_v5_host_state() {
  local root
  root="$(operator_repo_root)"
  if [ -x "$root/scripts/operator-host.sh" ] && [ -x "$root/scripts/operator-proof-broker.sh" ] \
    && [ -f "$root/scripts/operator_host.py" ] && [ -x "$root/scripts/operator-loop.sh" ]; then
    printf 'runtime installed; no bound session assumed\n'
  else
    printf 'runtime unavailable\n'
  fi
}

operator_v5_broker_state() {
  local root
  root="$(operator_repo_root)"
  if [ ! -x "$root/scripts/operator-proof-broker.sh" ]; then
    printf 'broker unavailable\n'
  elif [ -x /usr/bin/security ] || command -v secret-tool >/dev/null 2>&1; then
    printf 'broker/keychain tooling available; credential verified only by trusted host session\n'
  else
    printf 'keychain client unavailable\n'
  fi
}

operator_lanes() {
  printf '%s\n' "$OPERATOR_LANES" | awk -F'|' 'NF >= 4 && $1 !~ /^[[:space:]]*$/ { print $1 }'
}

operator_lane_row() {
  local lane="$1"
  printf '%s\n' "$OPERATOR_LANES" | awk -F'|' -v lane="$lane" 'NF >= 4 && $1 == lane { print; exit }'
}

operator_lane_field() {
  local lane="$1"
  local field="$2"
  local row
  row="$(operator_lane_row "$lane")"
  [ -n "$row" ] || return 1
  printf '%s\n' "$row" | awk -F'|' -v field="$field" '{ print $field }'
}

operator_lane_owner() {
  operator_lane_field "$1" 2
}

operator_lane_worktree_name() {
  operator_lane_field "$1" 3
}

operator_lane_branch() {
  operator_lane_field "$1" 4
}

operator_lane_invocation() {
  operator_lane_field "$1" 5
}

operator_lane_path() {
  local worktree_name
  worktree_name="$(operator_lane_worktree_name "$1")"
  printf '%s\n' "$CODE_DIR/$worktree_name"
}

operator_lane_exists() {
  local lane="$1"
  [ -n "$(operator_lane_row "$lane")" ]
}

operator_require_lane() {
  local lane="${1:-}"
  if ! operator_lane_exists "$lane"; then
    printf 'Unknown lane: %s\n' "$lane" >&2
    printf 'Valid lanes:\n' >&2
    operator_lanes >&2
    return 1
  fi
}

operator_tmux_bin() {
  if command -v tmux >/dev/null 2>&1; then
    command -v tmux
    return 0
  fi

  if [ -x /opt/homebrew/bin/tmux ]; then
    printf '%s\n' /opt/homebrew/bin/tmux
    return 0
  fi

  return 1
}
