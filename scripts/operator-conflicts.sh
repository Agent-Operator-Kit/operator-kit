#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-conflicts.sh <command> [feature]

Commands:
  check <feature>
      Compare one feature session against other active feature sessions.
  summary
      Compare all active feature sessions and summarize conflict risk.

Conflict policy:
  - role template overlap alone is not a blocker;
  - concrete overlap in files, surfaces, contracts, resources, branches, or
    worktrees creates coordination risk;
  - exploration/design can continue while implementation is blocked.
USAGE
}

FEATURES_DIR="$OPERATOR_DIR/features"
export FEATURES_DIR

command="${1:-}"
feature="${2:-}"

case "$command" in
  check|summary)
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

if [ "$command" = "check" ] && [ -z "$feature" ]; then
  usage >&2
  exit 1
fi

python3 - "$command" "$feature" <<'PY'
import json
import os
import sys
from pathlib import Path

command = sys.argv[1]
feature_key = sys.argv[2]
features_dir = Path(os.environ["FEATURES_DIR"])

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


def load_state(path):
    with (path / "status.json").open(encoding="utf-8") as fh:
        state = json.load(fh)
    state["_dir"] = str(path)
    state["_name"] = path.name
    return state


def feature_dirs():
    if not features_dir.exists():
        return []
    out = []
    for path in sorted(features_dir.iterdir()):
        if path.name == "_archive" or not path.is_dir():
            continue
        if (path / "status.json").exists():
            state = load_state(path)
            if state.get("status") in ACTIVE_STATUSES:
                out.append(state)
    return out


def resolve_feature(states, key):
    lowered = key.lower()
    matches = []
    for state in states:
        values = {
            state.get("id", "").lower(),
            state.get("slug", "").lower(),
            state.get("_name", "").lower(),
            f"{state.get('id', '').lower()}-{state.get('slug', '').lower()}",
        }
        if lowered in values or state.get("_name", "").lower().startswith(lowered):
            matches.append(state)
    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise SystemExit(f"Feature session not found or inactive: {key}")
    raise SystemExit("Feature key is ambiguous:\n" + "\n".join(f"  - {m['_name']}" for m in matches))


def normalize_pattern(value):
    value = (value or "").strip()
    for suffix in ["/**", "/*", "/"]:
        if value.endswith(suffix):
            value = value[: -len(suffix)]
    return value


def overlaps(a, b):
    a = normalize_pattern(a)
    b = normalize_pattern(b)
    if not a or not b:
        return False
    if a == b:
        return True
    return a.startswith(b + "/") or b.startswith(a + "/")


def pair_conflicts(left, right):
    left_claims = left.get("claims", {})
    right_claims = right.get("claims", {})
    conflicts = []
    notes = []

    left_branch = left.get("branch") or ""
    right_branch = right.get("branch") or ""
    if left_branch and right_branch and left_branch == right_branch:
        conflicts.append(("branch", left_branch))

    left_worktree = left.get("worktree") or ""
    right_worktree = right.get("worktree") or ""
    if left_worktree and right_worktree and left_worktree == right_worktree:
        conflicts.append(("worktree", left_worktree))

    for key in ["files", "surfaces"]:
        for left_value in left_claims.get(key, []):
            for right_value in right_claims.get(key, []):
                if overlaps(left_value, right_value):
                    conflicts.append((key, f"{left_value} <> {right_value}"))

    for key in ["contracts", "resources"]:
        shared = sorted(set(left_claims.get(key, [])) & set(right_claims.get(key, [])))
        for value in shared:
            conflicts.append((key, value))

    shared_roles = sorted(set(left_claims.get("roles", [])) & set(right_claims.get("roles", [])))
    for role in shared_roles:
        notes.append(("role-template", role))

    hard_levels = {left_claims.get("lockLevel", "soft"), right_claims.get("lockLevel", "soft")}
    if conflicts and "hard" in hard_levels:
        risk = "high"
    elif any(kind in {"files", "surfaces", "contracts", "resources", "branch", "worktree"} for kind, _ in conflicts):
        risk = "medium"
    elif notes:
        risk = "low"
    else:
        risk = "none"
    return risk, conflicts, notes


def print_pair(left, right):
    risk, conflicts, notes = pair_conflicts(left, right)
    if risk == "none":
        return risk
    print(f"## {left['id']} {left['title']} <> {right['id']} {right['title']}")
    print("")
    print(f"- Risk: {risk}")
    if conflicts:
        print("- Concrete overlaps:")
        for kind, value in conflicts:
            print(f"  - {kind}: `{value}`")
    if notes:
        print("- Shared role templates:")
        for kind, value in notes:
            print(f"  - {value} (duplicable; not a blocker by itself)")
    print("")
    return risk


states = feature_dirs()
if command == "check":
    target = resolve_feature(states, feature_key)
    print(f"# Conflict Check: {target['id']} {target['title']}\n")
    risks = []
    for other in states:
        if other["id"] == target["id"]:
            continue
        risks.append(print_pair(target, other))
    if not any(r != "none" for r in risks):
        print("- No active conflicts detected.")
    print("\n## Policy\n")
    print("- Same role template can be duplicated into feature-specific lane instances.")
    print("- Concrete file, surface, contract, branch, worktree, and resource overlaps require coordination.")
    print("- Exploration/design may continue while implementation waits for a lock or merge decision.")
else:
    print("# Active Feature Conflict Summary\n")
    any_risk = False
    for index, left in enumerate(states):
        for right in states[index + 1 :]:
            risk = print_pair(left, right)
            any_risk = any_risk or risk != "none"
    if not any_risk:
        print("- No active feature conflicts detected.")
PY
