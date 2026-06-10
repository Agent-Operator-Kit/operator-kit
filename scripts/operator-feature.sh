#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-feature.sh <command> [args]

Commands:
  init
      Create the V4 feature-session workspace.
  start <slug> "<title>" [--status idea] [--roadmap RM-0001]
      Create a feature session under OPERATOR_DIR/features.
  list|active
      List active feature sessions as chat-facing Markdown.
  status <feature>
      Show one feature-session status summary.
  bind <feature> [--tool codex|cursor|claude] [--chat <id>] [--mode <mode>]
      Record that the current chat/tool is working on a feature session.
  set-status <feature> <status>
      Move a feature through idea, discovery, design, shaped, active,
      in-review, integrated, shipped, parked, blocked, closed, or archived.
  link-roadmap <feature> <RM-id...>
      Link roadmap items to a feature session.
  claim <feature> [--files a,b] [--surfaces a,b] [--contracts a,b]
      [--resources a,b] [--roles a,b] [--level observe|design|soft|hard]
      Declare intended ownership/usage for conflict checks.
  workspace <feature> [--from <branch>] [--branch <branch>]
      [--worktree <name>] [--dry-run]
      Create or record a feature worktree and branch.
  spawn-lane <feature> <role> [--tool <tool>] [--owner <owner>]
      [--branch <branch>] [--worktree <name>] [--resources a,b]
      Register a feature-specific role lane instance.
  close <feature> [--reason "..."]
      Mark a feature session closed.
  archive <feature>
      Move a closed/integrated/shipped/parked feature session to _archive.
  cleanup [--dry-run]
      Show archive candidates, or archive closed/integrated/shipped sessions.
USAGE
}

FEATURES_DIR="$OPERATOR_DIR/features"
REPO_ROOT="$(cd "$(dirname "$(operator_config_file)")" && pwd)"
export PROJECT_NAME PROJECT_ROOT CODE_DIR OPERATOR_DIR DEFAULT_BRANCH FEATURES_DIR REPO_ROOT

command="${1:-}"
shift || true

case "$command" in
  init|start|list|active|status|bind|set-status|link-roadmap|claim|workspace|spawn-lane|close|archive|cleanup)
    ;;
  -h|--help|"")
    usage
    exit 0
    ;;
  *)
    printf 'Unknown command: %s\n\n' "$command" >&2
    usage >&2
    exit 1
    ;;
esac

python3 - "$command" "$@" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

command = sys.argv[1]
args = sys.argv[2:]

project_name = os.environ["PROJECT_NAME"]
project_root = Path(os.environ["PROJECT_ROOT"])
repo_root = Path(os.environ["REPO_ROOT"])
code_dir = Path(os.environ["CODE_DIR"])
operator_dir = Path(os.environ["OPERATOR_DIR"])
features_dir = Path(os.environ["FEATURES_DIR"])
default_branch = os.environ.get("DEFAULT_BRANCH", "main")

ACTIVE_STATUSES = {
    "idea",
    "discovery",
    "design",
    "shaped",
    "active",
    "dev-validation",
    "human-feedback",
    "staging-validation",
    "in-review",
    "parked",
    "blocked",
}

VALID_STATUSES = ACTIVE_STATUSES | {"integrated", "shipped", "closed", "archived"}


def now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def slugify(value):
    value = re.sub(r"[^a-zA-Z0-9._-]+", "-", value.strip().lower())
    value = re.sub(r"-+", "-", value).strip("-")
    return value[:72] or "feature"


def split_csv(value):
    out = []
    for item in (value or "").split(","):
        item = item.strip()
        if item and item.lower() not in {"none", "tbd"}:
            out.append(item)
    return out


def ensure_workspace():
    features_dir.mkdir(parents=True, exist_ok=True)
    (features_dir / "_archive").mkdir(parents=True, exist_ok=True)
    readme = features_dir / "README.md"
    if not readme.exists():
        readme.write_text(
            "# Operator Feature Sessions\n\n"
            "Feature sessions are V4 Operator Kit state. They let one Codex or Cursor "
            "project host multiple feature-focused chats while keeping durable state "
            "under `OPERATOR_DIR`.\n\n"
            "Markdown files are the chat-facing source of context. Small JSON files "
            "store script-safe status, ownership claims, role instances, and cleanup "
            "state.\n",
            encoding="utf-8",
        )
    active = features_dir / "active.md"
    if not active.exists():
        active.write_text("# Active Feature Sessions\n\n- none\n", encoding="utf-8")


def state_path(feature_dir):
    return feature_dir / "status.json"


def load_state(feature_dir):
    with state_path(feature_dir).open(encoding="utf-8") as fh:
        return json.load(fh)


def write_state(feature_dir, state):
    state["updatedAt"] = now()
    state["lastActivity"] = state["updatedAt"]
    tmp = state_path(feature_dir).with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(state_path(feature_dir))


def emit_event(feature_dir, event, **fields):
    payload = {"time": now(), "event": event, **fields}
    with (feature_dir / "events.jsonl").open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, sort_keys=True) + "\n")


def feature_dirs(include_archive=False):
    if not features_dir.exists():
        return []
    dirs = []
    for path in sorted(features_dir.iterdir()):
        if not path.is_dir():
            continue
        if path.name == "_archive":
            if include_archive:
                dirs.extend(sorted(p for p in path.iterdir() if p.is_dir()))
            continue
        if (path / "status.json").exists():
            dirs.append(path)
    return dirs


def resolve_feature(key):
    ensure_workspace()
    if not key:
        raise SystemExit("feature is required")
    candidates = []
    direct = features_dir / key
    if direct.is_dir():
        candidates.append(direct)
    archive_direct = features_dir / "_archive" / key
    if archive_direct.is_dir():
        candidates.append(archive_direct)
    lowered = key.lower()
    for path in feature_dirs(include_archive=True):
        state = load_state(path)
        values = {
            path.name.lower(),
            state.get("id", "").lower(),
            state.get("slug", "").lower(),
            f"{state.get('id', '').lower()}-{state.get('slug', '').lower()}",
        }
        if lowered in values or path.name.lower().startswith(lowered):
            candidates.append(path)
    unique = []
    seen = set()
    for path in candidates:
        if path not in seen:
            unique.append(path)
            seen.add(path)
    if len(unique) == 1:
        return unique[0]
    if not unique:
        raise SystemExit(f"Feature session not found: {key}")
    raise SystemExit("Feature key is ambiguous:\n" + "\n".join(f"  - {p.name}" for p in unique))


def next_id():
    max_num = 0
    for path in feature_dirs(include_archive=True):
        state = load_state(path)
        match = re.match(r"FS-(\d{4})$", state.get("id", ""))
        if match:
            max_num = max(max_num, int(match.group(1)))
    return f"FS-{max_num + 1:04d}"


def render_active():
    features_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    for path in feature_dirs():
        state = load_state(path)
        if state.get("status") not in ACTIVE_STATUSES:
            continue
        rows.append((state.get("lastActivity", ""), path, state))
    rows.sort(reverse=True)

    lines = ["# Active Feature Sessions", ""]
    if not rows:
        lines.append("- none")
    else:
        lines.extend(["| Feature | Status | Roadmap | Branch | Worktree | Roles | Last activity |", "| --- | --- | --- | --- | --- | --- | --- |"])
        for _, _path, state in rows:
            roadmap = ", ".join(state.get("roadmap", [])) or "none"
            roles = ", ".join(sorted(set(state.get("claims", {}).get("roles", [])))) or "none"
            branch = state.get("branch") or "none"
            worktree = state.get("worktree") or "none"
            lines.append(
                f"| `{state.get('id')}` {state.get('title')} | {state.get('status')} | "
                f"{roadmap} | `{branch}` | `{worktree}` | {roles} | {state.get('lastActivity', '')} |"
            )
    lines.append("")
    (features_dir / "active.md").write_text("\n".join(lines), encoding="utf-8")
    return "\n".join(lines)


def write_feature_markdown(feature_dir, state):
    roadmap = ", ".join(state.get("roadmap", [])) or "none"
    lines = [
        f"# {state['title']}",
        "",
        f"- ID: {state['id']}",
        f"- Slug: {state['slug']}",
        f"- Status: {state['status']}",
        f"- Project: {project_name}",
        f"- Roadmap: {roadmap}",
        f"- Branch: {state.get('branch') or 'none'}",
        f"- Worktree: {state.get('worktree') or 'none'}",
        f"- Created: {state['createdAt']}",
        "",
        "## Intent",
        "",
        "Describe the feature outcome, user value, and current product bet.",
        "",
        "## Lifecycle Notes",
        "",
        "- `idea`, `discovery`, and `design` can usually proceed without code locks.",
        "- `active` implementation should declare files, surfaces, contracts, resources, and roles before dispatch.",
        "- Operator owns merge planning and final integration into the stable branch.",
        "",
        "## Current Claims",
        "",
        "- Files: none",
        "- Surfaces: none",
        "- Contracts: none",
        "- Resources: none",
        "- Roles: none",
    ]
    (feature_dir / "feature.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def append_section(path, heading, lines):
    with path.open("a", encoding="utf-8") as fh:
        fh.write(f"\n## {heading}\n\n")
        for line in lines:
            fh.write(f"{line}\n")


def require_args(count, summary):
    if len(args) < count:
        raise SystemExit(summary)


def parse_flags(items, defaults=None):
    values = dict(defaults or {})
    positional = []
    i = 0
    while i < len(items):
        item = items[i]
        if item.startswith("--"):
            key = item[2:].replace("-", "_")
            if i + 1 >= len(items) or items[i + 1].startswith("--"):
                values[key] = "yes"
                i += 1
            else:
                values[key] = items[i + 1]
                i += 2
        else:
            positional.append(item)
            i += 1
    return positional, values


def cmd_init():
    ensure_workspace()
    print(features_dir)


def cmd_start():
    positional, flags = parse_flags(args, {"status": "idea", "roadmap": ""})
    if len(positional) < 2:
        raise SystemExit('start requires <slug> "<title>"')
    status = flags.get("status", "idea")
    if status not in VALID_STATUSES:
        raise SystemExit(f"Invalid status: {status}")
    slug = slugify(positional[0])
    title = positional[1]
    for path in feature_dirs(include_archive=True):
        if load_state(path).get("slug") == slug:
            raise SystemExit(f"Feature slug already exists: {slug}")
    feature_id = flags.get("id") or next_id()
    if not re.match(r"^FS-\d{4}$", feature_id):
        raise SystemExit("Feature id must use FS-0001 format")
    feature_dir = features_dir / f"{feature_id}-{slug}"
    feature_dir.mkdir(parents=True)
    for child in ["work", "tasks", "handoffs"]:
        (feature_dir / child).mkdir()
    created = now()
    state = {
        "id": feature_id,
        "slug": slug,
        "title": title,
        "status": status,
        "project": project_name,
        "createdAt": created,
        "updatedAt": created,
        "lastActivity": created,
        "roadmap": split_csv(flags.get("roadmap", "")),
        "branch": "",
        "worktree": "",
        "baseBranch": "",
        "boundChats": [],
        "claims": {
            "files": [],
            "surfaces": [],
            "contracts": [],
            "resources": [],
            "roles": [],
            "lockLevel": "soft",
        },
        "roleInstances": [],
        "merge": {"status": "not-started", "target": default_branch},
    }
    (feature_dir / "status.json").write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (feature_dir / "events.jsonl").write_text("", encoding="utf-8")
    write_feature_markdown(feature_dir, state)
    (feature_dir / "memory.md").write_text(f"# Feature Memory: {feature_id}\n\n## Entries\n", encoding="utf-8")
    (feature_dir / "decisions.md").write_text(f"# Decisions: {title}\n\n", encoding="utf-8")
    (feature_dir / "roadmap.md").write_text(f"# Roadmap Links: {title}\n\n- Roadmap: {', '.join(state['roadmap']) or 'none'}\n", encoding="utf-8")
    (feature_dir / "lanes.md").write_text(f"# Role Lane Instances: {title}\n\n", encoding="utf-8")
    (feature_dir / "resources.md").write_text(f"# Resource Notes: {title}\n\n", encoding="utf-8")
    (feature_dir / "merge-plan.md").write_text(f"# Merge Plan: {title}\n\n- Target: `{default_branch}`\n- Status: not-started\n", encoding="utf-8")
    emit_event(feature_dir, "created", status=status, roadmap=state["roadmap"])
    render_active()
    print(feature_dir)


def cmd_list():
    ensure_workspace()
    print(render_active())


def cmd_status():
    require_args(1, "status requires <feature>")
    feature_dir = resolve_feature(args[0])
    state = load_state(feature_dir)
    claims = state.get("claims", {})
    print(f"# Feature Session: {state.get('id')} {state.get('title')}\n")
    print(f"- Status: {state.get('status')}")
    print(f"- Folder: `{feature_dir}`")
    print(f"- Roadmap: {', '.join(state.get('roadmap', [])) or 'none'}")
    print(f"- Branch: `{state.get('branch') or 'none'}`")
    print(f"- Worktree: `{state.get('worktree') or 'none'}`")
    print(f"- Last activity: {state.get('lastActivity')}")
    print("\n## Claims\n")
    for key in ["files", "surfaces", "contracts", "resources", "roles"]:
        print(f"- {key}: {', '.join(claims.get(key, [])) or 'none'}")
    print(f"- lock level: {claims.get('lockLevel', 'soft')}")
    print("\n## Role Instances\n")
    role_instances = state.get("roleInstances", [])
    if not role_instances:
        print("- none")
    else:
        for role in role_instances:
            print(f"- `{role.get('id')}` role={role.get('role')} branch=`{role.get('branch') or 'none'}` worktree=`{role.get('worktree') or 'none'}` resources={', '.join(role.get('resources', [])) or 'none'}")


def cmd_bind():
    require_args(1, "bind requires <feature>")
    feature_dir = resolve_feature(args[0])
    _positional, flags = parse_flags(args[1:], {"tool": "codex", "chat": "", "mode": "feature"})
    state = load_state(feature_dir)
    binding = {
        "tool": flags.get("tool") or "codex",
        "chat": flags.get("chat") or "",
        "mode": flags.get("mode") or "feature",
        "boundAt": now(),
    }
    state.setdefault("boundChats", []).append(binding)
    write_state(feature_dir, state)
    emit_event(feature_dir, "bound_chat", **binding)
    render_active()
    print(f"Bound to {state['id']} {state['title']} ({binding['tool']}, {binding['mode']})")


def cmd_set_status():
    require_args(2, "set-status requires <feature> <status>")
    feature_dir = resolve_feature(args[0])
    status = args[1]
    if status not in VALID_STATUSES:
        raise SystemExit(f"Invalid status: {status}")
    state = load_state(feature_dir)
    old = state.get("status")
    state["status"] = status
    write_state(feature_dir, state)
    emit_event(feature_dir, "status_changed", old=old, new=status)
    render_active()
    print(f"{state['id']} status: {old} -> {status}")


def cmd_link_roadmap():
    require_args(2, "link-roadmap requires <feature> <RM-id...>")
    feature_dir = resolve_feature(args[0])
    roadmap_ids = args[1:]
    state = load_state(feature_dir)
    current = state.setdefault("roadmap", [])
    for roadmap_id in roadmap_ids:
        if roadmap_id not in current:
            current.append(roadmap_id)
    write_state(feature_dir, state)
    append_section(feature_dir / "roadmap.md", now(), [f"- Linked roadmap: {', '.join(roadmap_ids)}"])
    emit_event(feature_dir, "roadmap_linked", roadmap=roadmap_ids)
    render_active()
    print(f"{state['id']} roadmap: {', '.join(current)}")


def cmd_claim():
    require_args(1, "claim requires <feature>")
    feature_dir = resolve_feature(args[0])
    _positional, flags = parse_flags(args[1:])
    state = load_state(feature_dir)
    claims = state.setdefault("claims", {})
    for key in ["files", "surfaces", "contracts", "resources", "roles"]:
        incoming = split_csv(flags.get(key, ""))
        if not incoming:
            continue
        existing = claims.setdefault(key, [])
        for item in incoming:
            if item not in existing:
                existing.append(item)
    if flags.get("level"):
        level = flags["level"]
        if level not in {"observe", "design", "soft", "hard"}:
            raise SystemExit("claim --level must be observe, design, soft, or hard")
        claims["lockLevel"] = level
    write_state(feature_dir, state)
    append_section(
        feature_dir / "feature.md",
        f"Claims {now()}",
        [
            f"- Files: {', '.join(claims.get('files', [])) or 'none'}",
            f"- Surfaces: {', '.join(claims.get('surfaces', [])) or 'none'}",
            f"- Contracts: {', '.join(claims.get('contracts', [])) or 'none'}",
            f"- Resources: {', '.join(claims.get('resources', [])) or 'none'}",
            f"- Roles: {', '.join(claims.get('roles', [])) or 'none'}",
            f"- Lock level: {claims.get('lockLevel', 'soft')}",
        ],
    )
    emit_event(feature_dir, "claims_updated", claims=claims)
    render_active()
    print(f"{state['id']} claims updated")


def branch_exists(branch):
    result = subprocess.run(["git", "-C", str(repo_root), "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"])
    return result.returncode == 0


def cmd_workspace():
    require_args(1, "workspace requires <feature>")
    feature_dir = resolve_feature(args[0])
    _positional, flags = parse_flags(args[1:], {"from": default_branch, "dry_run": "no"})
    dry_run = flags.get("dry_run") == "yes"
    state = load_state(feature_dir)
    branch = flags.get("branch") or f"feature/{state['slug']}"
    worktree_name = flags.get("worktree") or f"{project_name}-{state['id'].lower()}-{state['slug']}"
    worktree_path = code_dir / worktree_name
    base = flags.get("from") or default_branch
    commands = []
    if not worktree_path.exists():
        if branch_exists(branch):
            commands.append(["git", "-C", str(repo_root), "worktree", "add", str(worktree_path), branch])
        else:
            commands.append(["git", "-C", str(repo_root), "worktree", "add", "-b", branch, str(worktree_path), base])
    if dry_run:
        for cmd in commands:
            print("Would run: " + " ".join(cmd))
    else:
        for cmd in commands:
            subprocess.run(cmd, check=True)
    state["branch"] = branch
    state["worktree"] = str(worktree_path)
    state["baseBranch"] = base
    if state.get("status") in {"idea", "discovery", "design", "shaped"}:
        state["status"] = "active"
    write_state(feature_dir, state)
    emit_event(feature_dir, "workspace_recorded", branch=branch, worktree=str(worktree_path), base=base, dryRun=dry_run)
    render_active()
    print(f"{state['id']} workspace: branch={branch} worktree={worktree_path}")


def cmd_spawn_lane():
    require_args(2, "spawn-lane requires <feature> <role>")
    feature_dir = resolve_feature(args[0])
    role = args[1]
    _positional, flags = parse_flags(args[2:])
    state = load_state(feature_dir)
    role_slug = slugify(role)
    instance = {
        "id": f"{role_slug}@{state['id']}",
        "role": role,
        "tool": flags.get("tool", ""),
        "owner": flags.get("owner", ""),
        "branch": flags.get("branch", ""),
        "worktree": flags.get("worktree", ""),
        "resources": split_csv(flags.get("resources", "")),
        "createdAt": now(),
    }
    state.setdefault("roleInstances", []).append(instance)
    claims = state.setdefault("claims", {})
    roles = claims.setdefault("roles", [])
    if role not in roles:
        roles.append(role)
    for resource in instance["resources"]:
        resources = claims.setdefault("resources", [])
        if resource not in resources:
            resources.append(resource)
    write_state(feature_dir, state)
    append_section(
        feature_dir / "lanes.md",
        f"{instance['id']} {instance['createdAt']}",
        [
            f"- Role: {role}",
            f"- Tool: {instance['tool'] or 'TBD'}",
            f"- Owner: {instance['owner'] or 'TBD'}",
            f"- Branch: `{instance['branch'] or 'none'}`",
            f"- Worktree: `{instance['worktree'] or 'none'}`",
            f"- Resources: {', '.join(instance['resources']) or 'none'}",
        ],
    )
    emit_event(feature_dir, "role_lane_spawned", instance=instance)
    render_active()
    print(f"{state['id']} role instance: {instance['id']}")


def cmd_close():
    require_args(1, "close requires <feature>")
    feature_dir = resolve_feature(args[0])
    _positional, flags = parse_flags(args[1:], {"reason": ""})
    state = load_state(feature_dir)
    old = state.get("status")
    state["status"] = "closed"
    write_state(feature_dir, state)
    emit_event(feature_dir, "closed", old=old, reason=flags.get("reason", ""))
    render_active()
    print(f"{state['id']} closed")


def cmd_archive():
    require_args(1, "archive requires <feature>")
    feature_dir = resolve_feature(args[0])
    state = load_state(feature_dir)
    if state.get("status") not in {"closed", "integrated", "shipped", "parked", "archived"}:
        raise SystemExit(f"Refusing to archive active feature {state['id']} with status {state.get('status')}. Close or park it first.")
    state["status"] = "archived"
    write_state(feature_dir, state)
    emit_event(feature_dir, "archived")
    archive_dir = features_dir / "_archive" / feature_dir.name
    if archive_dir.exists():
        raise SystemExit(f"Archive target already exists: {archive_dir}")
    shutil.move(str(feature_dir), str(archive_dir))
    render_active()
    print(archive_dir)


def cmd_cleanup():
    _positional, flags = parse_flags(args, {"dry_run": "no"})
    dry_run = flags.get("dry_run") == "yes"
    candidates = []
    for path in feature_dirs():
        state = load_state(path)
        if state.get("status") in {"closed", "integrated", "shipped"}:
            candidates.append((path, state))
    if dry_run:
        print("# Feature Cleanup Candidates\n")
        if not candidates:
            print("- none")
        for path, state in candidates:
            print(f"- `{state['id']}` {state['title']} status={state['status']} folder=`{path}`")
        return
    for path, state in candidates:
        state["status"] = "archived"
        write_state(path, state)
        emit_event(path, "archived_by_cleanup")
        target = features_dir / "_archive" / path.name
        if not target.exists():
            shutil.move(str(path), str(target))
            print(target)
    render_active()


dispatch = {
    "init": cmd_init,
    "start": cmd_start,
    "list": cmd_list,
    "active": cmd_list,
    "status": cmd_status,
    "bind": cmd_bind,
    "set-status": cmd_set_status,
    "link-roadmap": cmd_link_roadmap,
    "claim": cmd_claim,
    "workspace": cmd_workspace,
    "spawn-lane": cmd_spawn_lane,
    "close": cmd_close,
    "archive": cmd_archive,
    "cleanup": cmd_cleanup,
}

dispatch[command]()
PY
