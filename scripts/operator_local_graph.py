#!/usr/bin/env python3
"""Operator V5.1 local, advisory dependency graph.

The graph is intentionally feature-scoped and credential-free. It helps the
operator decide what is ready and what can run in parallel; it never dispatches
work or grants authority.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


SCHEMA = "operator.local-dependency-graph/v1"
EVENT_SCHEMA = "operator.local-dependency-event/v1"
NODE_KINDS = {"task", "validation", "integration", "feedback"}
STATES = {"pending", "active", "blocked", "completed", "failed", "cancelled"}
APPROVALS = {"not-required", "pending", "approved", "rejected"}
ACTIVE_FEATURE_STATES = {"shaped", "active", "in-review"}
CLAIM_KINDS = ("files", "contracts", "resources", "surfaces")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+\-]*$")


class GraphError(Exception):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def emit(payload: Any, as_json: bool = False) -> None:
    if as_json:
        print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
    else:
        print(payload)


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextmanager
def locked(feature_dir: Path):
    lock_path = feature_dir / ".graph.lock"
    lock_path.touch(mode=0o600, exist_ok=True)
    with lock_path.open("r+") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield


def csv(value: str | None) -> list[str]:
    if not value:
        return []
    result = []
    for item in value.split(","):
        item = item.strip()
        if item and item not in result:
            result.append(item)
    return result


def require_id(value: str, label: str) -> str:
    if not ID_RE.fullmatch(value) or len(value) > 128:
        raise GraphError(f"invalid {label}: {value}")
    return value


class Store:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.features = self.root / "features"

    def feature_dirs(self, include_inactive: bool = False) -> list[Path]:
        found = []
        if not self.features.is_dir():
            return found
        for path in sorted(self.features.iterdir()):
            if not path.is_dir() or path.name.startswith("_"):
                continue
            status_path = path / "status.json"
            if not status_path.is_file():
                continue
            status = self.read_json(status_path, "feature status")
            if include_inactive or status.get("status") in ACTIVE_FEATURE_STATES:
                found.append(path)
        return found

    def resolve_feature(self, token: str) -> Path:
        matches = []
        for path in self.feature_dirs(include_inactive=True):
            status = self.read_json(path / "status.json", "feature status")
            if token in {path.name, status.get("id"), status.get("slug")}:
                matches.append(path)
        if len(matches) != 1:
            raise GraphError(f"feature must resolve exactly once: {token}")
        return matches[0]

    @staticmethod
    def read_json(path: Path, label: str) -> dict[str, Any]:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise GraphError(f"cannot read {label}: {path}: {exc}") from exc
        if not isinstance(value, dict):
            raise GraphError(f"{label} must be a JSON object: {path}")
        return value

    def load(self, feature_dir: Path, create: bool = False) -> dict[str, Any]:
        path = feature_dir / "graph.json"
        if not path.exists():
            if not create:
                raise GraphError(f"dependency graph is not initialized: {feature_dir.name}")
            status = self.read_json(feature_dir / "status.json", "feature status")
            graph = {
                "schemaVersion": SCHEMA,
                "featureId": status["id"],
                "revision": 0,
                "updatedAt": utc_now(),
                "nodes": [],
            }
            atomic_json(path, graph)
            return graph
        graph = self.read_json(path, "dependency graph")
        validate_graph(graph)
        return graph

    def save(self, feature_dir: Path, graph: dict[str, Any], action: str, details: dict[str, Any]) -> None:
        graph["revision"] += 1
        graph["updatedAt"] = utc_now()
        validate_graph(graph)
        atomic_json(feature_dir / "graph.json", graph)
        event = {
            "schemaVersion": EVENT_SCHEMA,
            "occurredAt": graph["updatedAt"],
            "featureId": graph["featureId"],
            "revision": graph["revision"],
            "action": action,
            "details": details,
        }
        with (feature_dir / "graph-events.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")


def validate_graph(graph: dict[str, Any]) -> None:
    if set(graph) != {"schemaVersion", "featureId", "revision", "updatedAt", "nodes"}:
        raise GraphError("dependency graph has unexpected or missing fields")
    if graph["schemaVersion"] != SCHEMA:
        raise GraphError(f"unsupported graph schema: {graph.get('schemaVersion')}")
    require_id(graph["featureId"], "feature id")
    if not isinstance(graph["revision"], int) or graph["revision"] < 0:
        raise GraphError("graph revision must be a non-negative integer")
    if not isinstance(graph["nodes"], list):
        raise GraphError("graph nodes must be an array")
    ids: set[str] = set()
    for node in graph["nodes"]:
        required = {"id", "title", "kind", "state", "priority", "lane", "dependsOn", "claims", "approval", "taskFile"}
        if not isinstance(node, dict) or set(node) != required:
            raise GraphError("every node must use the exact local graph shape")
        node_id = require_id(node["id"], "node id")
        if node_id in ids:
            raise GraphError(f"duplicate node: {node_id}")
        ids.add(node_id)
        if not isinstance(node["title"], str) or not node["title"].strip():
            raise GraphError(f"node title is required: {node_id}")
        if node["kind"] not in NODE_KINDS or node["state"] not in STATES:
            raise GraphError(f"invalid kind or state: {node_id}")
        if not isinstance(node["priority"], int) or not 0 <= node["priority"] <= 1000:
            raise GraphError(f"priority must be 0..1000: {node_id}")
        if node["lane"] is not None:
            require_id(node["lane"], "lane")
        if node["approval"] not in APPROVALS:
            raise GraphError(f"invalid approval: {node_id}")
        if node["taskFile"] is not None and not isinstance(node["taskFile"], str):
            raise GraphError(f"taskFile must be a string or null: {node_id}")
        if not isinstance(node["dependsOn"], list) or len(node["dependsOn"]) != len(set(node["dependsOn"])):
            raise GraphError(f"dependsOn must contain unique ids: {node_id}")
        if not isinstance(node["claims"], dict) or set(node["claims"]) != set(CLAIM_KINDS):
            raise GraphError(f"claims have the wrong shape: {node_id}")
        for kind in CLAIM_KINDS:
            values = node["claims"][kind]
            if not isinstance(values, list) or not all(isinstance(v, str) and v for v in values) or len(values) != len(set(values)):
                raise GraphError(f"invalid {kind} claims: {node_id}")
    by_id = {node["id"]: node for node in graph["nodes"]}
    for node in graph["nodes"]:
        for dep in node["dependsOn"]:
            if dep not in by_id:
                raise GraphError(f"missing dependency {dep} referenced by {node['id']}")
            if dep == node["id"]:
                raise GraphError(f"self dependency: {dep}")
    visiting: set[str] = set()
    visited: set[str] = set()
    def visit(node_id: str) -> None:
        if node_id in visiting:
            raise GraphError(f"dependency cycle includes {node_id}")
        if node_id in visited:
            return
        visiting.add(node_id)
        for dep in by_id[node_id]["dependsOn"]:
            visit(dep)
        visiting.remove(node_id)
        visited.add(node_id)
    for node_id in sorted(by_id):
        visit(node_id)


def node_by_id(graph: dict[str, Any], node_id: str) -> dict[str, Any]:
    for node in graph["nodes"]:
        if node["id"] == node_id:
            return node
    raise GraphError(f"unknown node: {node_id}")


def feature_claims(feature_dir: Path) -> dict[str, set[str]]:
    status = Store.read_json(feature_dir / "status.json", "feature status")
    claims = status.get("claims") if isinstance(status.get("claims"), dict) else {}
    return {kind: set(claims.get(kind, [])) for kind in CLAIM_KINDS}


def overlap(left: dict[str, set[str]], right: dict[str, set[str]]) -> str | None:
    for kind in CLAIM_KINDS:
        if left[kind] & right[kind]:
            return kind
    return None


def frontier(store: Store, feature: str | None, capacity: int) -> dict[str, Any]:
    dirs = [store.resolve_feature(feature)] if feature else store.feature_dirs()
    candidates = []
    excluded = []
    active_claims: list[tuple[str, str, dict[str, set[str]]]] = []
    feature_claim_map = {path.name: feature_claims(path) for path in dirs}
    for path in dirs:
        graph_path = path / "graph.json"
        if not graph_path.exists():
            continue
        graph = store.load(path)
        by_id = {n["id"]: n for n in graph["nodes"]}
        for node in graph["nodes"]:
            node_claims = {k: set(node["claims"][k]) for k in CLAIM_KINDS}
            if node["state"] == "active":
                active_claims.append((path.name, node["lane"] or "", node_claims))
                continue
            if node["state"] in {"completed", "cancelled"}:
                continue
            reasons = []
            if node["state"] != "pending":
                reasons.append(f"state:{node['state']}")
            if node["lane"] is None:
                reasons.append("lane-missing")
            if node["approval"] == "pending":
                reasons.append("approval-pending")
            elif node["approval"] == "rejected":
                reasons.append("approval-rejected")
            incomplete = [dep for dep in node["dependsOn"] if by_id[dep]["state"] != "completed"]
            if incomplete:
                reasons.append("dependencies:" + ",".join(sorted(incomplete)))
            item = {"featureId": graph["featureId"], "featureDir": path.name, "node": node}
            if reasons:
                excluded.append({**item, "reasons": reasons})
            else:
                candidates.append(item)
    candidates.sort(key=lambda item: (-item["node"]["priority"], item["featureId"], item["node"]["id"]))
    selected = []
    selected_claims: list[tuple[str, str, dict[str, set[str]]]] = []
    for item in candidates:
        node = item["node"]
        claims = {k: set(node["claims"][k]) for k in CLAIM_KINDS}
        reasons = []
        for active_feature, lane, reserved in active_claims:
            if node["lane"] == lane or overlap(claims, reserved):
                reasons.append("conflict:active-work")
                break
            if active_feature != item["featureDir"] and overlap(feature_claim_map[item["featureDir"]], feature_claim_map[active_feature]):
                reasons.append("conflict:active-feature")
                break
        for selected_feature, lane, reserved in selected_claims:
            if node["lane"] == lane:
                reasons.append("conflict:lane")
                break
            claim_kind = overlap(claims, reserved)
            if claim_kind:
                reasons.append(f"conflict:{claim_kind}")
                break
            if selected_feature != item["featureDir"]:
                feature_kind = overlap(feature_claim_map[item["featureDir"]], feature_claim_map[selected_feature])
                if feature_kind:
                    reasons.append(f"conflict:feature-{feature_kind}")
                    break
        if len(selected) >= capacity:
            reasons.append("capacity")
        if reasons:
            excluded.append({**item, "reasons": reasons})
        else:
            selected.append(item)
            selected_claims.append((item["featureDir"], node["lane"], claims))
    return {
        "schemaVersion": "operator.local-frontier/v1",
        "capacity": capacity,
        "features": len(dirs),
        "runnable": selected,
        "excluded": excluded,
    }


def render_frontier(result: dict[str, Any]) -> str:
    lines = ["# Operator Local Dependency Frontier", "", f"- Capacity: {result['capacity']}", f"- Active feature sessions: {result['features']}", "", "## Runnable Now", ""]
    if not result["runnable"]:
        lines.append("- none")
    for item in result["runnable"]:
        node = item["node"]
        lines.append(f"- `{item['featureId']}/{node['id']}` {node['title']} -> lane `{node['lane']}`")
    lines.extend(["", "## Waiting Or Serialized", ""])
    if not result["excluded"]:
        lines.append("- none")
    for item in result["excluded"]:
        node = item["node"]
        lines.append(f"- `{item['featureId']}/{node['id']}`: {', '.join(item['reasons'])}")
    return "\n".join(lines)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="operator-graph", description="Operator V5.1 local dependency graph")
    root.add_argument("--operator-dir", required=True)
    sub = root.add_subparsers(dest="command", required=True)
    for name in ("init", "validate", "status"):
        cmd = sub.add_parser(name)
        cmd.add_argument("feature", nargs="?")
        cmd.add_argument("--json", action="store_true")
    add = sub.add_parser("add")
    add.add_argument("feature")
    add.add_argument("node_id")
    add.add_argument("title")
    add.add_argument("--kind", choices=sorted(NODE_KINDS), default="task")
    add.add_argument("--lane")
    add.add_argument("--depends-on", default="")
    add.add_argument("--priority", type=int, default=0)
    add.add_argument("--task-file")
    add.add_argument("--approval", choices=sorted(APPROVALS), default="not-required")
    for kind in CLAIM_KINDS:
        add.add_argument(f"--claims-{kind}", default="")
    add.add_argument("--json", action="store_true")
    depend = sub.add_parser("depend")
    depend.add_argument("feature")
    depend.add_argument("node_id")
    depend.add_argument("dependency")
    depend.add_argument("--json", action="store_true")
    state = sub.add_parser("set-state")
    state.add_argument("feature")
    state.add_argument("node_id")
    state.add_argument("state", choices=sorted(STATES))
    state.add_argument("--json", action="store_true")
    approve = sub.add_parser("approve")
    approve.add_argument("feature")
    approve.add_argument("node_id")
    approve.add_argument("decision", choices=("approved", "rejected", "pending"))
    approve.add_argument("--json", action="store_true")
    front = sub.add_parser("frontier")
    front.add_argument("feature", nargs="?")
    front.add_argument("--capacity", type=int, default=4)
    front.add_argument("--json", action="store_true")
    return root


def main(argv: Iterable[str] | None = None) -> int:
    args = parser().parse_args(argv)
    store = Store(Path(args.operator_dir))
    if args.command == "frontier":
        if not 0 <= args.capacity <= 1000:
            raise GraphError("capacity must be between 0 and 1000")
        result = frontier(store, args.feature, args.capacity)
        emit(result if args.json else render_frontier(result), args.json)
        return 0
    if args.command == "init" and args.feature is None:
        initialized = []
        for feature_dir in store.feature_dirs(include_inactive=True):
            with locked(feature_dir):
                if not (feature_dir / "graph.json").exists():
                    store.load(feature_dir, create=True)
                    initialized.append(Store.read_json(feature_dir / "status.json", "feature status")["id"])
        emit({"ok": True, "initialized": initialized}, args.json)
        return 0
    if args.command in {"validate", "status"} and args.feature is None:
        result = frontier(store, None, 1000)
        summary = {"ok": True, "mode": "local-advisory", "credentialsRequired": False, "activeFeatures": result["features"], "runnable": len(result["runnable"]), "excluded": len(result["excluded"])}
        emit(summary if args.json else f"Local dependency graph: {summary['activeFeatures']} active features, {summary['runnable']} runnable, {summary['excluded']} waiting; no credentials required", args.json)
        return 0
    feature_dir = store.resolve_feature(args.feature)
    with locked(feature_dir):
        graph = store.load(feature_dir, create=args.command == "init")
        if args.command == "init":
            result = {"ok": True, "featureId": graph["featureId"], "revision": graph["revision"], "path": str(feature_dir / "graph.json")}
        elif args.command == "validate":
            validate_graph(graph)
            result = {"ok": True, "featureId": graph["featureId"], "revision": graph["revision"], "nodes": len(graph["nodes"])}
        elif args.command == "status":
            by_state = {state: 0 for state in sorted(STATES)}
            for node in graph["nodes"]:
                by_state[node["state"]] += 1
            result = {"ok": True, "mode": "local-advisory", "credentialsRequired": False, "featureId": graph["featureId"], "revision": graph["revision"], "nodes": len(graph["nodes"]), "byState": by_state}
        elif args.command == "add":
            require_id(args.node_id, "node id")
            if any(node["id"] == args.node_id for node in graph["nodes"]):
                raise GraphError(f"node already exists: {args.node_id}")
            node = {"id": args.node_id, "title": args.title, "kind": args.kind, "state": "pending", "priority": args.priority, "lane": args.lane, "dependsOn": csv(args.depends_on), "claims": {kind: csv(getattr(args, f"claims_{kind}")) for kind in CLAIM_KINDS}, "approval": args.approval, "taskFile": args.task_file}
            graph["nodes"].append(node)
            store.save(feature_dir, graph, "node-added", {"nodeId": args.node_id})
            result = {"ok": True, "featureId": graph["featureId"], "revision": graph["revision"], "node": node}
        elif args.command == "depend":
            node = node_by_id(graph, args.node_id)
            node_by_id(graph, args.dependency)
            if args.dependency not in node["dependsOn"]:
                node["dependsOn"].append(args.dependency)
            store.save(feature_dir, graph, "dependency-added", {"nodeId": args.node_id, "dependency": args.dependency})
            result = {"ok": True, "featureId": graph["featureId"], "revision": graph["revision"]}
        elif args.command == "set-state":
            node = node_by_id(graph, args.node_id)
            previous = node["state"]
            node["state"] = args.state
            store.save(feature_dir, graph, "state-changed", {"nodeId": args.node_id, "from": previous, "to": args.state})
            result = {"ok": True, "featureId": graph["featureId"], "revision": graph["revision"], "nodeId": args.node_id, "state": args.state}
        elif args.command == "approve":
            node = node_by_id(graph, args.node_id)
            node["approval"] = args.decision
            store.save(feature_dir, graph, "approval-changed", {"nodeId": args.node_id, "decision": args.decision})
            result = {"ok": True, "featureId": graph["featureId"], "revision": graph["revision"], "nodeId": args.node_id, "approval": args.decision}
        else:
            raise GraphError(f"unsupported command: {args.command}")
    emit(result if args.json else json.dumps(result, indent=2, sort_keys=True), args.json)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GraphError as exc:
        print(json.dumps({"ok": False, "error": {"code": "LOCAL_GRAPH_ERROR", "message": str(exc)}}, sort_keys=True), file=sys.stderr)
        raise SystemExit(2)
