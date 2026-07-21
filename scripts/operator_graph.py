#!/usr/bin/env python3
"""Operator V5 typed control graph runtime.

The journal is authoritative. Definition and projection files are deterministic
materializations updated under one host-aware transaction lock.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import heapq
import json
import math
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Set, Tuple


GRAPH_VERSION = "operator.control-graph/v1"
EVENT_VERSION = "operator.control-event/v1"
PROJECTION_VERSION = "operator.control-projection/v1"
LEASE_VERSION = "operator.ownership-lease/v1"
BINDING_VERSION = "operator.actor-binding/v1"
LOCK_VERSION = "operator.graph-lock/v1"

ACTOR_TYPES = {"operator", "lane", "host", "human", "subagent", "system"}
CAPABILITIES = {
    "graph-init", "graph-replace", "gate-decision", "lease", "transition",
    "sweep", "replay-repair", "test-injection",
}
NODE_KINDS = {
    "goal", "feature", "lane", "task", "validation", "human-gate",
    "integration", "feedback",
}
EDGE_KINDS = {
    "contains", "depends-on", "assigned-to", "validated-by", "gated-by",
    "integrates-into", "feedback-for",
}
IMMUTABLE_EXECUTION_EDGE_KINDS = {"depends-on", "assigned-to", "validated-by", "gated-by", "integrates-into"}
CONTAINER_KINDS = {"goal", "feature", "lane"}
WORK_KINDS = {"task", "validation", "integration", "feedback"}
GATE_KINDS = {"human-gate"}

STATES_BY_FAMILY = {
    "container": {"planned", "active", "blocked", "completed", "cancelled"},
    "work": {"pending", "ready", "active", "blocked", "completed", "failed", "cancelled"},
    "gate": {"pending", "approved", "rejected", "cancelled"},
}
INITIAL_STATES = {"container": "planned", "work": "pending", "gate": "pending"}
SUCCESS_TERMINAL = {"container": {"completed"}, "work": {"completed"}, "gate": {"approved"}}
TERMINAL_STATES = {
    "container": {"completed", "cancelled"},
    "work": {"completed", "failed", "cancelled"},
    "gate": {"approved", "rejected", "cancelled"},
}
TRANSITIONS = {
    "container": {
        "planned": {"active", "blocked", "cancelled"},
        "active": {"blocked", "completed", "cancelled"},
        "blocked": {"active", "cancelled"},
        "completed": set(),
        "cancelled": set(),
    },
    "work": {
        "pending": {"ready", "blocked", "cancelled"},
        "ready": {"active", "blocked", "cancelled"},
        "active": {"blocked", "completed", "failed", "cancelled"},
        "blocked": {"ready", "active", "failed", "cancelled"},
        "completed": set(),
        "failed": {"ready", "cancelled"},
        "cancelled": set(),
    },
    "gate": {
        "pending": {"approved", "rejected", "cancelled"},
        "approved": set(),
        "rejected": set(),
        "cancelled": set(),
    },
}

ENDPOINTS: Mapping[str, Tuple[Set[str], Set[str]]] = {
    "contains": (CONTAINER_KINDS, NODE_KINDS - {"goal"}),
    "depends-on": (NODE_KINDS - {"human-gate"}, NODE_KINDS),
    "assigned-to": (WORK_KINDS, {"lane"}),
    "validated-by": ({"task", "integration"}, {"validation"}),
    "gated-by": ({"goal", "feature", "task", "integration"}, {"human-gate"}),
    "integrates-into": ({"integration"}, {"feature"}),
    "feedback-for": ({"feedback"}, NODE_KINDS - {"feedback"}),
}

EVENT_COMMANDS = {
    "graph.initialized": "init",
    "definition.replaced": "replace-definition",
    "node.transitioned": "transition",
    "gate.decided": "gate decide",
    "lease.acquired": "lease acquire",
    "lease.renewed": "lease renew",
    "lease.released": "lease release",
    "lease.swept": "lease sweep",
    "replay.repaired": "replay repair",
}
EVENT_CAPABILITIES = {
    "graph.initialized": "graph-init",
    "definition.replaced": "graph-replace",
    "node.transitioned": "transition",
    "gate.decided": "gate-decision",
    "lease.acquired": "lease",
    "lease.renewed": "lease",
    "lease.released": "lease",
    "lease.swept": "sweep",
    "replay.repaired": "replay-repair",
}

MAX_GRAPH_BYTES = 4 * 1024 * 1024
MAX_BINDING_BYTES = 64 * 1024
MAX_JOURNAL_BYTES = 256 * 1024 * 1024
MAX_EVENT_BYTES = 8 * 1024 * 1024
MAX_NODES = 10000
MAX_EDGES = 50000
MAX_METADATA_BYTES = 64 * 1024
MAX_JSON_DEPTH = 32
MAX_JSON_ITEMS = 200000
ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+\-]*$")
BINDING_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]*$")

EXIT_CODES = {
    "USAGE": 2,
    "IO_ERROR": 3,
    "UNKNOWN_VERSION": 4,
    "INVALID_GRAPH": 5,
    "REVISION_CONFLICT": 6,
    "REQUEST_CONFLICT": 7,
    "AUTHORITY_DENIED": 8,
    "LEASE_CONFLICT": 9,
    "FENCE_STALE": 10,
    "INVALID_TRANSITION": 11,
    "REPLAY_DRIFT": 12,
    "CORRUPT_JOURNAL": 13,
    "NOT_INITIALIZED": 14,
    "INVALID_STATE": 15,
    "LOCK_TIMEOUT": 16,
    "LEASE_REQUIRED": 17,
    "LEASE_EXPIRED": 18,
    "TEST_FAULT": 19,
    "PRECONDITION_FAILED": 20,
    "GATE_REQUIRED": 21,
    "RECONCILIATION_REQUIRED": 22,
    "CLOCK_ROLLBACK": 23,
}


class GraphError(Exception):
    def __init__(self, code: str, message: str, details: Any = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details


def fail(condition: bool, code: str, message: str, details: Any = None) -> None:
    if not condition:
        raise GraphError(code, message, details)


def has_control(value: str) -> bool:
    return any(ord(character) < 32 or 127 <= ord(character) <= 159 for character in value)


def valid_string(value: Any, maximum: int, pattern: bool = False) -> bool:
    return (
        isinstance(value, str)
        and bool(value.strip())
        and len(value) <= maximum
        and not has_control(value)
        and (not pattern or ID_PATTERN.fullmatch(value) is not None)
    )


def valid_binding_id(value: Any) -> bool:
    return isinstance(value, str) and len(value) <= 128 and BINDING_ID_PATTERN.fullmatch(value) is not None


def validate_json_value(value: Any, label: str, maximum_depth: int = MAX_JSON_DEPTH) -> None:
    stack: List[Tuple[Any, int]] = [(value, 1)]
    count = 0
    while stack:
        current, depth = stack.pop()
        count += 1
        fail(count <= MAX_JSON_ITEMS, "INVALID_GRAPH", f"{label} contains too many values")
        fail(depth <= maximum_depth, "INVALID_GRAPH", f"{label} exceeds maximum depth {maximum_depth}")
        if isinstance(current, float):
            fail(math.isfinite(current), "INVALID_GRAPH", f"{label} contains a non-finite number")
        elif isinstance(current, str):
            fail(not has_control(current), "INVALID_GRAPH", f"{label} contains control characters")
        elif isinstance(current, dict):
            for key, item in current.items():
                fail(isinstance(key, str) and not has_control(key), "INVALID_GRAPH", f"{label} contains an invalid object key")
                stack.append((item, depth + 1))
        elif isinstance(current, list):
            for item in current:
                stack.append((item, depth + 1))
        else:
            fail(current is None or isinstance(current, (bool, int)), "INVALID_GRAPH", f"{label} contains an unsupported JSON value")


def reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number: {value}")


def parse_json_bytes(data: bytes, path: Path, error_code: str) -> Dict[str, Any]:
    try:
        text = data.decode("utf-8")
        value = json.loads(text, parse_constant=reject_constant)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise GraphError(error_code, f"Invalid JSON: {path}", str(exc)) from exc
    fail(isinstance(value, dict), error_code, f"Expected a JSON object: {path}")
    return value


def read_json_file(path: Path, missing_code: str, invalid_code: str, maximum_bytes: int) -> Dict[str, Any]:
    if not path.is_file():
        raise GraphError(missing_code, f"Missing state file: {path}")
    try:
        size = path.stat().st_size
        fail(size <= maximum_bytes, invalid_code, f"JSON file exceeds {maximum_bytes} bytes: {path}")
        data = path.read_bytes()
    except OSError as exc:
        raise GraphError("IO_ERROR", f"Cannot read JSON file: {path}", str(exc)) from exc
    return parse_json_bytes(data, path, invalid_code)


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def parse_time(value: Any, code: str = "USAGE") -> dt.datetime:
    fail(isinstance(value, str) and len(value) <= 64 and not has_control(value), code, "Timestamp must be a bounded string")
    raw = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = dt.datetime.fromisoformat(raw)
    except (ValueError, OverflowError) as exc:
        raise GraphError(code, f"Invalid RFC 3339 timestamp: {value}") from exc
    fail(parsed.tzinfo is not None, code, "Timestamp must include a timezone")
    return parsed.astimezone(dt.timezone.utc)


def format_time(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def canonical_bytes(value: Any) -> bytes:
    try:
        text = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
    except (TypeError, ValueError, RecursionError) as exc:
        raise GraphError("INVALID_GRAPH", "Value cannot be encoded as canonical JSON", str(exc)) from exc
    return (text + "\n").encode("utf-8")


def semantic_equal(left: Any, right: Any) -> bool:
    return canonical_bytes(left) == canonical_bytes(right)


def sha256_value(value: Any) -> str:
    return "sha256:" + hashlib.sha256(canonical_bytes(value)).hexdigest()


def require_keys(value: Mapping[str, Any], required: Set[str], optional: Set[str], label: str,
                 code: str = "INVALID_GRAPH") -> None:
    missing = required - set(value)
    extra = set(value) - required - optional
    fail(not missing, code, f"{label} is missing required fields", sorted(missing))
    fail(not extra, code, f"{label} has unknown fields", sorted(extra))


def validate_version(value: Any, expected: str, label: str) -> None:
    fail(isinstance(value, str), "UNKNOWN_VERSION", f"{label} schemaVersion is required")
    fail(value == expected, "UNKNOWN_VERSION", f"Unsupported {label} schemaVersion: {value}", {"expected": expected})


def family_for(kind: str) -> str:
    if kind in CONTAINER_KINDS:
        return "container"
    if kind in WORK_KINDS:
        return "work"
    return "gate"


def default_gate_transitions(source_kind: str) -> List[str]:
    if source_kind == "integration":
        return ["ready", "active", "completed"]
    return ["active", "completed"]


def validate_definition(value: Mapping[str, Any], materialized: bool = True) -> Dict[str, Any]:
    fail(isinstance(value, dict), "INVALID_GRAPH", "Graph definition must be an object")
    validate_json_value(value, "graph definition")
    require_keys(value, {"schemaVersion", "graphId", "nodes", "edges"}, {"definitionRevision"}, "graph definition")
    validate_version(value.get("schemaVersion"), GRAPH_VERSION, "graph")
    graph_id = value.get("graphId")
    fail(valid_string(graph_id, 128, pattern=True), "INVALID_GRAPH", "graphId is invalid")
    if "definitionRevision" in value:
        fail(isinstance(value["definitionRevision"], int) and not isinstance(value["definitionRevision"], bool) and value["definitionRevision"] >= 1,
             "INVALID_GRAPH", "definitionRevision must be a positive integer")
    elif materialized:
        raise GraphError("INVALID_GRAPH", "Materialized definition is missing definitionRevision")
    nodes = value.get("nodes")
    edges = value.get("edges")
    fail(isinstance(nodes, list) and len(nodes) <= MAX_NODES, "INVALID_GRAPH", f"nodes must be an array of at most {MAX_NODES} items")
    fail(isinstance(edges, list) and len(edges) <= MAX_EDGES, "INVALID_GRAPH", f"edges must be an array of at most {MAX_EDGES} items")

    normalized_nodes: List[Dict[str, Any]] = []
    node_by_id: Dict[str, Dict[str, Any]] = {}
    for index, raw in enumerate(nodes):
        fail(isinstance(raw, dict), "INVALID_GRAPH", f"nodes[{index}] must be an object")
        require_keys(raw, {"id", "kind"}, {"title", "initialState", "priority", "metadata"}, f"nodes[{index}]")
        node_id = raw.get("id")
        kind = raw.get("kind")
        fail(valid_string(node_id, 128, pattern=True), "INVALID_GRAPH", f"nodes[{index}].id is invalid")
        fail(node_id not in node_by_id, "INVALID_GRAPH", f"Duplicate node id: {node_id}")
        fail(kind in NODE_KINDS, "INVALID_GRAPH", f"Unknown node kind: {kind}")
        family = family_for(kind)
        state = raw.get("initialState", INITIAL_STATES[family])
        fail(state in STATES_BY_FAMILY[family], "INVALID_GRAPH", f"Invalid initialState for {kind}: {state}")
        priority = raw.get("priority", 0)
        fail(isinstance(priority, int) and not isinstance(priority, bool) and 0 <= priority <= 1000,
             "INVALID_GRAPH", f"Invalid priority for node {node_id}")
        title = raw.get("title", node_id)
        fail(valid_string(title, 512), "INVALID_GRAPH", f"Invalid title for node {node_id}")
        metadata = raw.get("metadata", {})
        fail(isinstance(metadata, dict), "INVALID_GRAPH", f"metadata for node {node_id} must be an object")
        fail(len(canonical_bytes(metadata)) <= MAX_METADATA_BYTES, "INVALID_GRAPH", f"metadata for node {node_id} is too large")
        execution = metadata.get("execution")
        if execution is not None:
            fail(isinstance(execution, dict), "INVALID_GRAPH", f"execution metadata for node {node_id} must be an object")
            require_keys(execution, {"idempotent", "reclaimable"}, set(), f"execution metadata for node {node_id}")
            fail(all(isinstance(execution[key], bool) for key in ("idempotent", "reclaimable")),
                 "INVALID_GRAPH", f"execution metadata for node {node_id} must use booleans")
        normalized = {
            "id": node_id, "kind": kind, "title": title, "initialState": state,
            "priority": priority, "metadata": metadata,
        }
        node_by_id[node_id] = normalized
        normalized_nodes.append(normalized)

    normalized_edges: List[Dict[str, Any]] = []
    edge_ids: Set[str] = set()
    edge_tuples: Set[Tuple[str, str, str]] = set()
    for index, raw in enumerate(edges):
        fail(isinstance(raw, dict), "INVALID_GRAPH", f"edges[{index}] must be an object")
        require_keys(raw, {"kind", "from", "to"}, {"id", "metadata"}, f"edges[{index}]")
        kind = raw.get("kind")
        source = raw.get("from")
        target = raw.get("to")
        fail(kind in EDGE_KINDS, "INVALID_GRAPH", f"Unknown edge kind: {kind}")
        fail(isinstance(source, str) and source in node_by_id, "INVALID_GRAPH", f"Unknown edge source: {source}")
        fail(isinstance(target, str) and target in node_by_id, "INVALID_GRAPH", f"Unknown edge target: {target}")
        fail(source != target, "INVALID_GRAPH", f"Self edge is not allowed: {source}")
        allowed_from, allowed_to = ENDPOINTS[kind]
        fail(node_by_id[source]["kind"] in allowed_from and node_by_id[target]["kind"] in allowed_to,
             "INVALID_GRAPH", f"Invalid endpoints for {kind}: {node_by_id[source]['kind']} -> {node_by_id[target]['kind']}")
        triple = (kind, source, target)
        fail(triple not in edge_tuples, "INVALID_GRAPH", f"Duplicate edge: {kind} {source} -> {target}")
        edge_tuples.add(triple)
        edge_id = raw.get("id", f"{kind}:{source}:{target}")
        fail(valid_string(edge_id, 384, pattern=True), "INVALID_GRAPH", f"Invalid edge id at index {index}")
        fail(edge_id not in edge_ids, "INVALID_GRAPH", f"Duplicate edge id: {edge_id}")
        edge_ids.add(edge_id)
        metadata = raw.get("metadata", {})
        fail(isinstance(metadata, dict), "INVALID_GRAPH", f"metadata for edge {edge_id} must be an object")
        fail(len(canonical_bytes(metadata)) <= MAX_METADATA_BYTES, "INVALID_GRAPH", f"metadata for edge {edge_id} is too large")
        if kind == "gated-by":
            require_keys(metadata, set(), {"protectedTransitions"}, f"metadata for gated edge {edge_id}")
            protected = metadata.get("protectedTransitions", default_gate_transitions(node_by_id[source]["kind"]))
            family_states = STATES_BY_FAMILY[family_for(node_by_id[source]["kind"])]
            fail(isinstance(protected, list) and bool(protected) and len(protected) == len(set(protected)),
                 "INVALID_GRAPH", f"gated-by edge {edge_id} requires unique protectedTransitions")
            fail(all(isinstance(item, str) and item in family_states for item in protected),
                 "INVALID_GRAPH", f"gated-by edge {edge_id} has an invalid protected transition")
            metadata = {"protectedTransitions": sorted(protected)}
        normalized_edges.append({"id": edge_id, "kind": kind, "from": source, "to": target, "metadata": metadata})

    adjacency: Dict[str, List[str]] = {node_id: [] for node_id in node_by_id}
    indegree: Dict[str, int] = {node_id: 0 for node_id in node_by_id}
    for edge in normalized_edges:
        if edge["kind"] in {"contains", "depends-on"}:
            adjacency[edge["from"]].append(edge["to"])
            indegree[edge["to"]] += 1
    frontier = [node_id for node_id, degree in indegree.items() if degree == 0]
    heapq.heapify(frontier)
    visited = 0
    while frontier:
        node_id = heapq.heappop(frontier)
        visited += 1
        for target_id in sorted(adjacency[node_id]):
            indegree[target_id] -= 1
            if indegree[target_id] == 0:
                heapq.heappush(frontier, target_id)
    fail(visited == len(node_by_id), "INVALID_GRAPH", "contains/depends-on edges must be acyclic")

    result: Dict[str, Any] = {
        "schemaVersion": GRAPH_VERSION,
        "graphId": graph_id,
        "nodes": sorted(normalized_nodes, key=lambda item: item["id"]),
        "edges": sorted(normalized_edges, key=lambda item: item["id"]),
    }
    if "definitionRevision" in value:
        result["definitionRevision"] = value["definitionRevision"]
    return result


def load_input_definition(path: Path) -> Dict[str, Any]:
    value = read_json_file(path, "INVALID_GRAPH", "INVALID_GRAPH", MAX_GRAPH_BYTES)
    return validate_definition(value, materialized=False)


def definition_hash(definition: Mapping[str, Any]) -> str:
    return sha256_value(definition)


def blank_projection(definition: Mapping[str, Any], occurred_at: str, sequence: int) -> Dict[str, Any]:
    return {
        "schemaVersion": PROJECTION_VERSION,
        "graphId": definition["graphId"],
        "revision": sequence,
        "definitionRevision": definition["definitionRevision"],
        "definitionHash": definition_hash(definition),
        "updatedAt": occurred_at,
        "nodeStates": {node["id"]: node["initialState"] for node in definition["nodes"]},
        "leases": {},
        "leaseFences": {},
    }


def validate_lease(value: Mapping[str, Any], code: str = "INVALID_STATE") -> None:
    required = {"schemaVersion", "nodeId", "leaseId", "holder", "acquiredAt", "renewedAt", "expiresAt", "fence"}
    fail(isinstance(value, dict) and set(value) == required, code, "Lease fields are invalid")
    validate_version(value.get("schemaVersion"), LEASE_VERSION, "lease")
    fail(valid_string(value.get("nodeId"), 128, pattern=True), code, "Lease nodeId is invalid")
    fail(valid_string(value.get("leaseId"), 256, pattern=True), code, "Lease leaseId is invalid")
    holder = value.get("holder")
    holder_fields = {"actorType", "actorId", "bindingId", "scope", "laneNodeId"}
    fail(isinstance(holder, dict) and set(holder) == holder_fields, code, "Lease holder is invalid")
    fail(holder.get("actorType") in {"lane", "host"}, code, "Lease holder actorType is invalid")
    fail(valid_string(holder.get("actorId"), 256, pattern=True), code, "Lease holder actorId is invalid")
    fail(valid_binding_id(holder.get("bindingId")), code, "Lease holder bindingId is invalid")
    fail(valid_string(holder.get("scope"), 512, pattern=True), code, "Lease holder scope is invalid")
    fail(valid_string(holder.get("laneNodeId"), 128, pattern=True), code, "Lease holder laneNodeId is invalid")
    acquired = parse_time(value.get("acquiredAt"), code)
    renewed = parse_time(value.get("renewedAt"), code)
    expires = parse_time(value.get("expiresAt"), code)
    fail(acquired <= renewed < expires, code, "Lease timestamps are not ordered")
    fail(isinstance(value.get("fence"), int) and not isinstance(value["fence"], bool) and value["fence"] >= 1,
         code, "Lease fence is invalid")


def validate_projection(value: Mapping[str, Any], definition: Mapping[str, Any]) -> None:
    required = {"schemaVersion", "graphId", "revision", "definitionRevision", "definitionHash", "updatedAt", "nodeStates", "leases", "leaseFences"}
    fail(isinstance(value, dict) and set(value) == required, "INVALID_STATE", "Projection fields are invalid")
    validate_version(value.get("schemaVersion"), PROJECTION_VERSION, "projection")
    fail(value.get("graphId") == definition["graphId"], "INVALID_STATE", "Projection graphId does not match definition")
    fail(value.get("definitionRevision") == definition["definitionRevision"], "INVALID_STATE", "Projection definitionRevision does not match definition")
    fail(value.get("definitionHash") == definition_hash(definition), "INVALID_STATE", "Projection definitionHash does not match definition")
    fail(isinstance(value.get("revision"), int) and not isinstance(value["revision"], bool) and value["revision"] >= 1,
         "INVALID_STATE", "Projection revision is invalid")
    parse_time(value.get("updatedAt"), "INVALID_STATE")
    node_states = value.get("nodeStates")
    fail(isinstance(node_states, dict), "INVALID_STATE", "Projection nodeStates must be an object")
    node_map = {node["id"]: node for node in definition["nodes"]}
    fail(set(node_states) == set(node_map), "INVALID_STATE", "Projection nodeStates do not match definition nodes")
    for node_id, state in node_states.items():
        fail(state in STATES_BY_FAMILY[family_for(node_map[node_id]["kind"])], "INVALID_STATE", f"Invalid projected state for {node_id}: {state}")
    leases = value.get("leases")
    fences = value.get("leaseFences")
    fail(isinstance(leases, dict) and isinstance(fences, dict), "INVALID_STATE", "Projection leases and leaseFences must be objects")
    for node_id, lease in leases.items():
        fail(node_id in node_map and lease.get("nodeId") == node_id, "INVALID_STATE", f"Lease references unknown node: {node_id}")
        validate_lease(lease)
    for node_id, fence in fences.items():
        fail(valid_string(node_id, 128, pattern=True) and isinstance(fence, int) and not isinstance(fence, bool) and fence >= 1,
             "INVALID_STATE", f"Invalid lease fence tombstone: {node_id}")
        if node_id in leases:
            fail(fence == leases[node_id]["fence"], "INVALID_STATE", f"Lease fence mismatch for node: {node_id}")


def find_node(definition: Mapping[str, Any], node_id: str) -> Dict[str, Any]:
    for node in definition["nodes"]:
        if node["id"] == node_id:
            return node
    raise GraphError("INVALID_GRAPH", f"Unknown node: {node_id}")


def is_success_terminal(definition: Mapping[str, Any], projection: Mapping[str, Any], node_id: str) -> bool:
    node = find_node(definition, node_id)
    return projection["nodeStates"][node_id] in SUCCESS_TERMINAL[family_for(node["kind"])]


def transition_preconditions(definition: Mapping[str, Any], projection: Mapping[str, Any], node_id: str,
                             target_state: str) -> None:
    node = find_node(definition, node_id)
    edges = definition["edges"]
    if target_state in {"ready", "active"}:
        blockers = [
            edge["to"] for edge in edges
            if edge["kind"] == "depends-on" and edge["from"] == node_id
            and not is_success_terminal(definition, projection, edge["to"])
        ]
        fail(not blockers, "PRECONDITION_FAILED", f"Dependencies are not success-terminal for node: {node_id}", {"dependencies": sorted(blockers)})
    if target_state == "completed":
        blockers = [
            edge["to"] for edge in edges
            if edge["kind"] == "validated-by" and edge["from"] == node_id
            and not is_success_terminal(definition, projection, edge["to"])
        ]
        fail(not blockers, "PRECONDITION_FAILED", f"Validations are not success-terminal for node: {node_id}", {"validations": sorted(blockers)})
    gated_edges = [
        edge for edge in edges
        if edge["kind"] == "gated-by" and edge["from"] == node_id
        and target_state in edge["metadata"]["protectedTransitions"]
    ]
    if node["kind"] == "integration" and target_state in {"ready", "active", "completed"}:
        fail(bool(gated_edges), "GATE_REQUIRED", f"Integration transition requires an applicable human gate: {node_id}")
    blocked_gates = [edge["to"] for edge in gated_edges if projection["nodeStates"].get(edge["to"]) != "approved"]
    fail(not blocked_gates, "PRECONDITION_FAILED", f"Protected transition lacks approved human gates for node: {node_id}", {"gates": sorted(blocked_gates)})


def validate_actor_record(actor: Any, code: str) -> None:
    required = {"type", "id", "bindingId", "bindingHash", "capabilities", "subject", "leaseScopes"}
    fail(isinstance(actor, dict) and set(actor) == required, code, "Event actor is invalid")
    fail(actor.get("type") in ACTOR_TYPES, code, "Event actor type is invalid")
    fail(valid_string(actor.get("id"), 256, pattern=True), code, "Event actor id is invalid")
    fail(valid_binding_id(actor.get("bindingId")), code, "Event actor bindingId is invalid")
    fail(isinstance(actor.get("bindingHash"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", actor["bindingHash"]), code, "Event actor bindingHash is invalid")
    capabilities = actor.get("capabilities")
    fail(isinstance(capabilities, list) and capabilities == sorted(set(capabilities)) and set(capabilities) <= CAPABILITIES,
         code, "Event actor capabilities are invalid")
    subject = actor.get("subject")
    fail(isinstance(subject, dict) and subject.get("type") == actor["type"] and subject.get("id") == actor["id"],
         code, "Event actor subject does not match type/id")
    required_subject = {"type", "id"}
    if actor["type"] == "lane":
        required_subject.add("laneNodeId")
    elif actor["type"] == "host":
        required_subject.add("hostRunnerId")
    fail(set(subject) == required_subject, code, "Event actor subject fields are invalid")
    if "laneNodeId" in subject:
        fail(valid_string(subject["laneNodeId"], 128, pattern=True), code, "Event actor laneNodeId is invalid")
    if "hostRunnerId" in subject:
        fail(valid_string(subject["hostRunnerId"], 128, pattern=True), code, "Event actor hostRunnerId is invalid")
    scopes = actor.get("leaseScopes")
    fail(isinstance(scopes, list) and len(scopes) <= 1000, code, "Event actor leaseScopes are invalid")
    seen_scopes: Set[str] = set()
    for scope in scopes:
        fail(isinstance(scope, dict) and set(scope) == {"scope", "laneNodeId"}, code, "Event actor lease scope fields are invalid")
        fail(valid_string(scope.get("scope"), 512, pattern=True) and valid_string(scope.get("laneNodeId"), 128, pattern=True),
             code, "Event actor lease scope is invalid")
        fail(scope["scope"] not in seen_scopes, code, "Event actor lease scopes are duplicated")
        seen_scopes.add(scope["scope"])
        if actor["type"] == "lane":
            fail(scope["laneNodeId"] == subject["laneNodeId"], code, "Event lane actor scope crosses lane nodes")
    if actor["type"] not in {"lane", "host"}:
        fail(not scopes, code, "Event non-owner actor contains lease scopes")


def expected_result_data(event_type: str, data: Mapping[str, Any], prior_definition: Optional[Mapping[str, Any]],
                         prior_projection: Optional[Mapping[str, Any]]) -> Dict[str, Any]:
    if event_type == "graph.initialized":
        definition = data["definition"]
        return {"initialized": True, "alreadyInitialized": False, "graphId": definition["graphId"]}
    if event_type == "definition.replaced":
        definition = data["definition"]
        return {"graphId": definition["graphId"], "definitionRevision": definition["definitionRevision"],
                "nodes": len(definition["nodes"]), "edges": len(definition["edges"])}
    if event_type in {"node.transitioned", "gate.decided", "lease.released"}:
        return dict(data)
    if event_type == "lease.acquired":
        assert prior_projection is not None
        lease = data["lease"]
        return {"lease": lease, "reclaimed": lease["nodeId"] in prior_projection["leases"]}
    if event_type == "lease.renewed":
        return {"lease": data["lease"]}
    if event_type == "lease.swept":
        return {"expired": data["expired"], "count": len(data["expired"])}
    if event_type == "replay.repaired":
        return {"repairedRevision": data["repairedRevision"]}
    raise GraphError("CORRUPT_JOURNAL", f"Unknown event type: {event_type}")


def validate_event(event: Any, sequence: int, seen_requests: Set[str]) -> None:
    required = {"schemaVersion", "sequence", "eventId", "requestId", "requestFingerprint", "occurredAt", "actor", "type", "data", "result"}
    fail(isinstance(event, dict) and set(event) == required, "CORRUPT_JOURNAL", "Event fields are invalid", {"line": sequence})
    validate_version(event.get("schemaVersion"), EVENT_VERSION, "event")
    fail(event.get("sequence") == sequence, "CORRUPT_JOURNAL", "Event sequence is not strict", {"expected": sequence, "actual": event.get("sequence")})
    fail(valid_string(event.get("eventId"), 128, pattern=True), "CORRUPT_JOURNAL", "Event eventId is invalid")
    request_id = event.get("requestId")
    fail(valid_string(request_id, 256, pattern=True), "CORRUPT_JOURNAL", "Event requestId is invalid")
    fail(request_id not in seen_requests, "CORRUPT_JOURNAL", f"Duplicate requestId in journal: {request_id}")
    seen_requests.add(request_id)
    fail(isinstance(event.get("requestFingerprint"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", event["requestFingerprint"]),
         "CORRUPT_JOURNAL", "Event requestFingerprint is invalid")
    parse_time(event.get("occurredAt"), "CORRUPT_JOURNAL")
    validate_actor_record(event.get("actor"), "CORRUPT_JOURNAL")
    event_type = event.get("type")
    fail(event_type in EVENT_COMMANDS, "CORRUPT_JOURNAL", f"Unknown event type: {event_type}")
    fail(EVENT_CAPABILITIES[event_type] in event["actor"]["capabilities"], "CORRUPT_JOURNAL", f"Event actor lacked required capability: {event_type}")
    fail(isinstance(event.get("data"), dict), "CORRUPT_JOURNAL", "Event data must be an object")
    result = event.get("result")
    result_fields = {"ok", "command", "requestId", "revision", "data"}
    fail(isinstance(result, dict) and set(result) == result_fields, "CORRUPT_JOURNAL", "Event result fields are invalid")
    fail(result.get("ok") is True and result.get("command") == EVENT_COMMANDS[event_type]
         and result.get("requestId") == request_id and result.get("revision") == sequence
         and isinstance(result.get("data"), dict), "CORRUPT_JOURNAL", "Event result is invalid")


def read_events(path: Path, recover_tail: bool = False) -> List[Dict[str, Any]]:
    if not path.is_file():
        raise GraphError("NOT_INITIALIZED", f"Missing event journal: {path}")
    try:
        size = path.stat().st_size
        fail(size <= MAX_JOURNAL_BYTES, "CORRUPT_JOURNAL", "Event journal is too large")
        data = path.read_bytes()
    except OSError as exc:
        raise GraphError("IO_ERROR", f"Cannot read event journal: {path}", str(exc)) from exc
    if data and not data.endswith(b"\n"):
        if not recover_tail:
            raise GraphError("CORRUPT_JOURNAL", "Journal ends with an uncommitted partial record")
        committed_length = data.rfind(b"\n") + 1
        try:
            descriptor = os.open(str(path), os.O_WRONLY)
            try:
                os.ftruncate(descriptor, committed_length)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            fsync_directory(path.parent)
        except OSError as exc:
            raise GraphError("IO_ERROR", "Cannot recover partial journal tail", str(exc)) from exc
        data = data[:committed_length]
    fail(bool(data), "CORRUPT_JOURNAL", "Event journal has no committed records")
    events: List[Dict[str, Any]] = []
    seen_requests: Set[str] = set()
    previous_time: Optional[dt.datetime] = None
    for line_number, raw_line in enumerate(data.splitlines(keepends=True), 1):
        fail(raw_line.endswith(b"\n") and len(raw_line) <= MAX_EVENT_BYTES, "CORRUPT_JOURNAL", "Invalid journal record boundary", {"line": line_number})
        try:
            event = json.loads(raw_line.decode("utf-8"), parse_constant=reject_constant)
            validate_event(event, line_number, seen_requests)
        except GraphError:
            raise
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
            raise GraphError("CORRUPT_JOURNAL", "Journal contains invalid JSON", {"line": line_number, "error": str(exc)}) from exc
        occurred = parse_time(event["occurredAt"], "CORRUPT_JOURNAL")
        fail(previous_time is None or occurred >= previous_time, "CORRUPT_JOURNAL", "Event time moved backwards", {"line": line_number})
        previous_time = occurred
        events.append(event)
    return events


def _replay(events: Sequence[Mapping[str, Any]]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    definition: Optional[Dict[str, Any]] = None
    projection: Optional[Dict[str, Any]] = None
    for event in events:
        event_type = event["type"]
        data = event["data"]
        sequence = event["sequence"]
        occurred_at = event["occurredAt"]
        prior_definition = definition
        prior_projection = None if projection is None else json.loads(json.dumps(projection))
        if sequence == 1:
            fail(event_type == "graph.initialized", "CORRUPT_JOURNAL", "First event must be graph.initialized")
        if event_type == "graph.initialized":
            fail(sequence == 1 and definition is None and set(data) == {"definition"}, "CORRUPT_JOURNAL", "graph.initialized data is invalid")
            fail(event["actor"]["type"] in {"operator", "system"}, "CORRUPT_JOURNAL", "Unauthorized graph initialization actor")
            definition = validate_definition(data["definition"], materialized=True)
            projection = blank_projection(definition, occurred_at, sequence)
        else:
            fail(definition is not None and projection is not None, "CORRUPT_JOURNAL", "Event appears before initialization")
            if event_type == "definition.replaced":
                fail(set(data) == {"definition"} and event["actor"]["type"] in {"operator", "system"},
                     "CORRUPT_JOURNAL", "definition.replaced data or actor is invalid")
                replacement = validate_definition(data["definition"], materialized=True)
                fail(replacement["graphId"] == definition["graphId"], "CORRUPT_JOURNAL", "Replacement changed graphId")
                fail(replacement["definitionRevision"] == definition["definitionRevision"] + 1, "CORRUPT_JOURNAL", "Replacement definitionRevision is not monotonic")
                old_nodes = {node["id"]: node for node in definition["nodes"]}
                new_nodes = {node["id"]: node for node in replacement["nodes"]}
                fail(set(old_nodes) <= set(new_nodes), "CORRUPT_JOURNAL", "Replacement removed a historical node ID")
                for node_id, old_node in old_nodes.items():
                    fail(new_nodes[node_id]["kind"] == old_node["kind"], "CORRUPT_JOURNAL", f"Replacement changed node kind: {node_id}")
                    current_state = projection["nodeStates"][node_id]
                    if current_state != old_node["initialState"] or current_state in TERMINAL_STATES[family_for(old_node["kind"])]:
                        old_identity = {key: old_node[key] for key in ("kind", "title", "initialState", "metadata")}
                        new_identity = {key: new_nodes[node_id][key] for key in ("kind", "title", "initialState", "metadata")}
                        fail(old_identity == new_identity, "CORRUPT_JOURNAL", f"Replacement rewrote activated or terminal node: {node_id}")
                        old_edges = [edge for edge in definition["edges"] if edge["from"] == node_id and edge["kind"] in IMMUTABLE_EXECUTION_EDGE_KINDS]
                        new_edges = [edge for edge in replacement["edges"] if edge["from"] == node_id and edge["kind"] in IMMUTABLE_EXECUTION_EDGE_KINDS]
                        fail(old_edges == new_edges, "CORRUPT_JOURNAL", f"Replacement rewrote activated or terminal node edges: {node_id}")
                new_states = dict(projection["nodeStates"])
                for node_id, node in new_nodes.items():
                    if node_id not in new_states:
                        new_states[node_id] = node["initialState"]
                projection["nodeStates"] = new_states
                definition = replacement
                projection["definitionRevision"] = definition["definitionRevision"]
                projection["definitionHash"] = definition_hash(definition)
            elif event_type in {"node.transitioned", "gate.decided"}:
                fail(set(data) == {"nodeId", "from", "to"}, "CORRUPT_JOURNAL", f"{event_type} data is invalid")
                node = find_node(definition, data["nodeId"])
                family = family_for(node["kind"])
                fail(projection["nodeStates"][node["id"]] == data["from"], "CORRUPT_JOURNAL", f"Transition source mismatch: {node['id']}")
                fail(data["to"] in TRANSITIONS[family][data["from"]], "CORRUPT_JOURNAL", f"Impossible transition: {node['id']}")
                if event_type == "gate.decided":
                    fail(family == "gate" and event["actor"]["type"] == "human" and data["to"] in {"approved", "rejected"},
                         "CORRUPT_JOURNAL", "Invalid human gate decision")
                else:
                    fail(family != "gate" and event["actor"]["type"] != "subagent", "CORRUPT_JOURNAL", "Unauthorized generic transition")
                    current_lease = projection["leases"].get(node["id"])
                    if current_lease is None:
                        fail(event["actor"]["type"] in {"operator", "system"}, "CORRUPT_JOURNAL", "Unauthorized unleased transition")
                    else:
                        fail(parse_time(current_lease["expiresAt"], "CORRUPT_JOURNAL") > parse_time(occurred_at, "CORRUPT_JOURNAL"),
                             "CORRUPT_JOURNAL", "Expired lease transitioned a node")
                        fail(current_lease["holder"]["bindingId"] == event["actor"]["bindingId"], "CORRUPT_JOURNAL", "Transition binding did not hold lease")
                    transition_preconditions(definition, projection, node["id"], data["to"])
                projection["nodeStates"][node["id"]] = data["to"]
            elif event_type == "lease.acquired":
                fail(set(data) == {"lease"}, "CORRUPT_JOURNAL", "lease.acquired data is invalid")
                lease = data["lease"]
                validate_lease(lease, "CORRUPT_JOURNAL")
                node = find_node(definition, lease["nodeId"])
                fail(node["kind"] in WORK_KINDS and event["actor"]["type"] in {"lane", "host"}, "CORRUPT_JOURNAL", "Invalid lease acquisition actor or node")
                fail(lease["holder"]["bindingId"] == event["actor"]["bindingId"], "CORRUPT_JOURNAL", "Lease holder binding mismatch")
                recorded_scope = [scope for scope in event["actor"]["leaseScopes"] if scope["scope"] == lease["holder"]["scope"]]
                fail(len(recorded_scope) == 1 and recorded_scope[0]["laneNodeId"] == lease["holder"]["laneNodeId"],
                     "CORRUPT_JOURNAL", "Lease holder scope was not present in recorded actor binding")
                assigned = any(edge["kind"] == "assigned-to" and edge["from"] == node["id"] and edge["to"] == lease["holder"]["laneNodeId"] for edge in definition["edges"])
                fail(assigned, "CORRUPT_JOURNAL", "Lease acquisition violated assignment")
                current = projection["leases"].get(node["id"])
                if current is not None:
                    fail(parse_time(current["expiresAt"], "CORRUPT_JOURNAL") <= parse_time(occurred_at, "CORRUPT_JOURNAL"), "CORRUPT_JOURNAL", "Lease acquired over unexpired lease")
                    execution = node["metadata"].get("execution", {})
                    safe = projection["nodeStates"][node["id"]] in {"pending", "ready", "blocked"}
                    fail(execution.get("idempotent") is True and execution.get("reclaimable") is True and safe,
                         "CORRUPT_JOURNAL", "Unsafe automatic lease reclaim")
                fail(lease["fence"] == projection["leaseFences"].get(node["id"], 0) + 1, "CORRUPT_JOURNAL", "Lease fence is not monotonic")
                fail(lease["acquiredAt"] == occurred_at and lease["renewedAt"] == occurred_at, "CORRUPT_JOURNAL", "Lease acquisition time mismatch")
                projection["leases"][node["id"]] = lease
                projection["leaseFences"][node["id"]] = lease["fence"]
            elif event_type == "lease.renewed":
                fail(set(data) == {"lease"}, "CORRUPT_JOURNAL", "lease.renewed data is invalid")
                lease = data["lease"]
                validate_lease(lease, "CORRUPT_JOURNAL")
                current = projection["leases"].get(lease["nodeId"])
                fail(current is not None and current["leaseId"] == lease["leaseId"] and current["fence"] == lease["fence"], "CORRUPT_JOURNAL", "Renewal does not match current lease")
                fail(current["holder"] == lease["holder"] and current["acquiredAt"] == lease["acquiredAt"], "CORRUPT_JOURNAL", "Renewal changed immutable fields")
                fail(current["holder"]["bindingId"] == event["actor"]["bindingId"] and parse_time(current["expiresAt"], "CORRUPT_JOURNAL") > parse_time(occurred_at, "CORRUPT_JOURNAL"),
                     "CORRUPT_JOURNAL", "Unauthorized or expired renewal")
                fail(lease["renewedAt"] == occurred_at, "CORRUPT_JOURNAL", "Renewal time mismatch")
                projection["leases"][lease["nodeId"]] = lease
            elif event_type == "lease.released":
                fail(set(data) == {"nodeId", "leaseId", "fence"}, "CORRUPT_JOURNAL", "lease.released data is invalid")
                current = projection["leases"].get(data["nodeId"])
                fail(current is not None and current["leaseId"] == data["leaseId"] and current["fence"] == data["fence"], "CORRUPT_JOURNAL", "Release does not match current lease")
                fail(current["holder"]["bindingId"] == event["actor"]["bindingId"] and parse_time(current["expiresAt"], "CORRUPT_JOURNAL") > parse_time(occurred_at, "CORRUPT_JOURNAL"),
                     "CORRUPT_JOURNAL", "Unauthorized or expired release")
                projection["leases"].pop(data["nodeId"])
            elif event_type == "lease.swept":
                fail(set(data) == {"expired"} and event["actor"]["type"] in {"operator", "system", "host"}, "CORRUPT_JOURNAL", "lease.swept data or actor is invalid")
                expected = []
                for node_id, lease in sorted(projection["leases"].items()):
                    if parse_time(lease["expiresAt"], "CORRUPT_JOURNAL") <= parse_time(occurred_at, "CORRUPT_JOURNAL"):
                        node = find_node(definition, node_id)
                        prior_state = projection["nodeStates"][node_id]
                        execution = node["metadata"].get("execution", {})
                        auto_safe = execution.get("idempotent") is True and execution.get("reclaimable") is True and prior_state in {"pending", "ready", "blocked"}
                        target_state = prior_state
                        reconciliation = not auto_safe and prior_state not in TERMINAL_STATES["work"]
                        if reconciliation:
                            target_state = "blocked"
                        expected.append({"nodeId": node_id, "leaseId": lease["leaseId"], "fence": lease["fence"],
                                         "fromState": prior_state, "toState": target_state, "reconciliation": reconciliation})
                fail(data["expired"] == expected, "CORRUPT_JOURNAL", "lease.swept entries do not match expired leases")
                for item in data["expired"]:
                    projection["leases"].pop(item["nodeId"], None)
                    projection["nodeStates"][item["nodeId"]] = item["toState"]
            elif event_type == "replay.repaired":
                fail(set(data) == {"repairedRevision"} and data["repairedRevision"] == sequence - 1
                     and event["actor"]["type"] in {"operator", "system"}, "CORRUPT_JOURNAL", "replay.repaired data or actor is invalid")
        assert definition is not None and projection is not None
        expected_data = expected_result_data(event_type, data, prior_definition, prior_projection)
        fail(event["result"]["data"] == expected_data, "CORRUPT_JOURNAL", f"Event result data mismatch: {event_type}")
        projection["revision"] = sequence
        projection["updatedAt"] = occurred_at
    assert definition is not None and projection is not None
    validate_projection(projection, definition)
    return definition, projection


def replay(events: Sequence[Mapping[str, Any]]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    try:
        return _replay(events)
    except GraphError as exc:
        if exc.code in {"CORRUPT_JOURNAL", "UNKNOWN_VERSION"}:
            raise
        raise GraphError("CORRUPT_JOURNAL", exc.message, exc.details) from exc
    except (KeyError, TypeError, ValueError, RecursionError) as exc:
        raise GraphError("CORRUPT_JOURNAL", "Journal event is semantically invalid", str(exc)) from exc


def fsync_directory(path: Path) -> None:
    try:
        descriptor = os.open(str(path), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}.{uuid.uuid4()}")
    try:
        with temporary.open("wb") as handle:
            handle.write(canonical_bytes(value))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    except OSError as exc:
        with contextlib.suppress(OSError):
            temporary.unlink()
        raise GraphError("IO_ERROR", f"Cannot atomically write {path}", str(exc)) from exc


def append_bytes(path: Path, data: bytes) -> None:
    try:
        descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            written = 0
            while written < len(data):
                count = os.write(descriptor, data[written:])
                fail(count > 0, "IO_ERROR", f"Short journal write: {path}")
                written += count
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        fsync_directory(path.parent)
    except OSError as exc:
        raise GraphError("IO_ERROR", f"Cannot append event journal: {path}", str(exc)) from exc


def host_id() -> str:
    return socket.gethostname() or "unknown-host"


def boot_id() -> str:
    linux_path = Path("/proc/sys/kernel/random/boot_id")
    try:
        value = linux_path.read_text(encoding="utf-8").strip()
        if value:
            return value
    except OSError:
        pass
    try:
        output = subprocess.check_output(["sysctl", "-n", "kern.boottime"], text=True, stderr=subprocess.DEVNULL, timeout=2)
        match = re.search(r"sec\s*=\s*(\d+)", output)
        if match:
            return f"boot-epoch:{match.group(1)}"
    except (OSError, subprocess.SubprocessError):
        pass
    approximate = int((time.time() - time.monotonic()) // 60)
    return f"boot-minute:{approximate}"


def process_start(pid: int) -> str:
    proc_stat = Path(f"/proc/{pid}/stat")
    try:
        raw = proc_stat.read_text(encoding="utf-8")
        closing_parenthesis = raw.rfind(")")
        fields_after_name = raw[closing_parenthesis + 2:].split()
        if closing_parenthesis >= 0 and len(fields_after_name) > 19:
            return f"ticks:{fields_after_name[19]}"
    except OSError:
        pass
    try:
        value = subprocess.check_output(["ps", "-o", "lstart=", "-p", str(pid)], text=True, stderr=subprocess.DEVNULL, timeout=2).strip()
        if value:
            return f"ps:{value}"
    except (OSError, subprocess.SubprocessError):
        pass
    return "unknown"


HOST_ID = host_id()
BOOT_ID = boot_id()


class DirectoryLock:
    def __init__(self, path: Path, timeout: float = 10.0, lease_seconds: float = 30.0):
        self.path = path
        self.timeout = timeout
        self.lease_seconds = lease_seconds
        self.token = str(uuid.uuid4())
        self.pid = os.getpid()
        self.start = process_start(self.pid)
        self.stop_event = threading.Event()
        self.heartbeat_thread: Optional[threading.Thread] = None

    def owner(self) -> Dict[str, Any]:
        now = utc_now()
        return {
            "schemaVersion": LOCK_VERSION,
            "hostId": HOST_ID,
            "bootId": BOOT_ID,
            "pid": self.pid,
            "processStart": self.start,
            "token": self.token,
            "heartbeatAt": format_time(now),
            "expiresAt": format_time(now + dt.timedelta(seconds=self.lease_seconds)),
        }

    def __enter__(self) -> "DirectoryLock":
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                self.path.mkdir(mode=0o700)
                atomic_write_json(self.path / "owner.json", self.owner())
                self.heartbeat_thread = threading.Thread(target=self._heartbeat, daemon=True)
                self.heartbeat_thread.start()
                return self
            except FileExistsError:
                self._break_stale()
                if time.monotonic() >= deadline:
                    raise GraphError("LOCK_TIMEOUT", f"Timed out waiting for graph lock: {self.path}")
                time.sleep(0.025)
            except OSError as exc:
                raise GraphError("IO_ERROR", f"Cannot create graph lock: {self.path}", str(exc)) from exc

    def _heartbeat(self) -> None:
        interval = max(0.1, self.lease_seconds / 3)
        while not self.stop_event.wait(interval):
            try:
                current = read_json_file(self.path / "owner.json", "LOCK_TIMEOUT", "LOCK_TIMEOUT", MAX_BINDING_BYTES)
                if current.get("token") != self.token:
                    return
                atomic_write_json(self.path / "owner.json", self.owner())
            except GraphError:
                return

    def _break_stale(self) -> None:
        try:
            owner = read_json_file(self.path / "owner.json", "LOCK_TIMEOUT", "LOCK_TIMEOUT", MAX_BINDING_BYTES)
            required = {"schemaVersion", "hostId", "bootId", "pid", "processStart", "token", "heartbeatAt", "expiresAt"}
            if set(owner) != required or owner.get("schemaVersion") != LOCK_VERSION:
                return
            expired = parse_time(owner["expiresAt"], "LOCK_TIMEOUT") <= utc_now()
            same_host_boot = owner["hostId"] == HOST_ID and owner["bootId"] == BOOT_ID
            confirmed_dead_or_reused = False
            if same_host_boot:
                try:
                    pid = int(owner["pid"])
                    os.kill(pid, 0)
                    confirmed_dead_or_reused = process_start(pid) != owner["processStart"]
                except (ProcessLookupError, ValueError):
                    confirmed_dead_or_reused = True
                except PermissionError:
                    confirmed_dead_or_reused = False
            if not expired and not confirmed_dead_or_reused:
                return
        except GraphError:
            return
        stale = self.path.with_name(f".lock.stale.{uuid.uuid4()}")
        try:
            os.rename(self.path, stale)
        except OSError:
            return
        shutil.rmtree(stale, ignore_errors=True)

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        self.stop_event.set()
        if self.heartbeat_thread is not None:
            self.heartbeat_thread.join(timeout=1)
        try:
            owner = read_json_file(self.path / "owner.json", "LOCK_TIMEOUT", "LOCK_TIMEOUT", MAX_BINDING_BYTES)
            if owner.get("token") == self.token:
                shutil.rmtree(self.path)
        except GraphError:
            pass


class Store:
    def __init__(self, operator_dir: Path):
        self.operator_dir = operator_dir
        self.graph_dir = operator_dir / "graph"
        self.binding_dir = self.graph_dir / "bindings"
        self.definition_path = self.graph_dir / "definition.json"
        self.projection_path = self.graph_dir / "projection.json"
        self.events_path = self.graph_dir / "events.jsonl"
        self.lock_path = self.graph_dir / ".lock"

    def lock(self) -> DirectoryLock:
        self.graph_dir.mkdir(parents=True, exist_ok=True)
        timeout = 10.0
        if os.environ.get("OPERATOR_GRAPH_TESTING") == "1":
            with contextlib.suppress(ValueError):
                timeout = max(0.05, min(float(os.environ.get("OPERATOR_GRAPH_TEST_LOCK_TIMEOUT", "10")), 10.0))
        return DirectoryLock(self.lock_path, timeout=timeout)

    def has_state(self) -> bool:
        if self.definition_path.exists() or self.projection_path.exists():
            return True
        try:
            return self.events_path.stat().st_size > 0
        except OSError:
            return False

    def load(self, auto_roll_forward: bool = True) -> Tuple[Dict[str, Any], Dict[str, Any], List[Dict[str, Any]]]:
        events = read_events(self.events_path, recover_tail=True)
        replayed_definition, replayed_projection = replay(events)
        try:
            definition = validate_definition(read_json_file(self.definition_path, "NOT_INITIALIZED", "INVALID_STATE", MAX_GRAPH_BYTES), materialized=True)
            raw_projection = read_json_file(self.projection_path, "NOT_INITIALIZED", "INVALID_STATE", MAX_GRAPH_BYTES)
            projection_revision = raw_projection.get("revision") if isinstance(raw_projection, dict) else None
            validate_projection(raw_projection, definition)
            projection = raw_projection
        except GraphError as exc:
            if exc.code == "UNKNOWN_VERSION":
                raise
            if auto_roll_forward and exc.code == "NOT_INITIALIZED":
                self.write_materialized(replayed_definition, replayed_projection)
                return replayed_definition, replayed_projection, events
            try:
                raw_projection = read_json_file(self.projection_path, "NOT_INITIALIZED", "INVALID_STATE", MAX_GRAPH_BYTES)
                projection_revision = raw_projection.get("revision")
            except GraphError:
                projection_revision = None
            if auto_roll_forward and isinstance(projection_revision, int) and projection_revision < replayed_projection["revision"]:
                self.write_materialized(replayed_definition, replayed_projection)
                return replayed_definition, replayed_projection, events
            raise
        if not semantic_equal(definition, replayed_definition) or not semantic_equal(projection, replayed_projection):
            if auto_roll_forward and projection["revision"] < replayed_projection["revision"]:
                self.write_materialized(replayed_definition, replayed_projection)
                return replayed_definition, replayed_projection, events
            raise GraphError("REPLAY_DRIFT", "Materialized graph state differs from deterministic replay", {
                "definitionDrift": not semantic_equal(definition, replayed_definition),
                "projectionDrift": not semantic_equal(projection, replayed_projection),
                "journalRevision": replayed_projection["revision"],
                "projectionRevision": projection.get("revision"),
            })
        return definition, projection, events

    def write_materialized(self, definition: Mapping[str, Any], projection: Mapping[str, Any]) -> None:
        atomic_write_json(self.definition_path, definition)
        atomic_write_json(self.projection_path, projection)


def validate_binding(binding: Mapping[str, Any], expected_id: str) -> Dict[str, Any]:
    require_keys(binding, {"schemaVersion", "bindingId", "subject", "capabilities", "leaseScopes"}, set(), "actor binding", "AUTHORITY_DENIED")
    validate_version(binding.get("schemaVersion"), BINDING_VERSION, "actor binding")
    fail(binding.get("bindingId") == expected_id and valid_binding_id(expected_id), "AUTHORITY_DENIED", "Actor binding ID is invalid")
    subject = binding.get("subject")
    fail(isinstance(subject, dict), "AUTHORITY_DENIED", "Actor binding subject must be an object")
    actor_type = subject.get("type")
    required_subject = {"type", "id"}
    if actor_type == "lane":
        required_subject.add("laneNodeId")
    elif actor_type == "host":
        required_subject.add("hostRunnerId")
    fail(set(subject) == required_subject and actor_type in ACTOR_TYPES, "AUTHORITY_DENIED", "Actor binding subject fields are invalid")
    fail(valid_string(subject.get("id"), 256, pattern=True), "AUTHORITY_DENIED", "Actor binding subject id is invalid")
    if actor_type == "lane":
        fail(valid_string(subject.get("laneNodeId"), 128, pattern=True), "AUTHORITY_DENIED", "Lane binding laneNodeId is invalid")
    if actor_type == "host":
        fail(valid_string(subject.get("hostRunnerId"), 128, pattern=True), "AUTHORITY_DENIED", "Host binding hostRunnerId is invalid")
    capabilities = binding.get("capabilities")
    fail(isinstance(capabilities, list) and capabilities == sorted(set(capabilities)) and set(capabilities) <= CAPABILITIES,
         "AUTHORITY_DENIED", "Actor binding capabilities are invalid")
    scopes = binding.get("leaseScopes")
    fail(isinstance(scopes, list) and len(scopes) <= 1000, "AUTHORITY_DENIED", "Actor binding leaseScopes are invalid")
    seen_scopes: Set[str] = set()
    for scope in scopes:
        fail(isinstance(scope, dict) and set(scope) == {"scope", "laneNodeId"}, "AUTHORITY_DENIED", "Lease scope fields are invalid")
        fail(valid_string(scope.get("scope"), 512, pattern=True), "AUTHORITY_DENIED", "Lease scope is invalid")
        fail(valid_string(scope.get("laneNodeId"), 128, pattern=True), "AUTHORITY_DENIED", "Lease scope laneNodeId is invalid")
        fail(scope["scope"] not in seen_scopes, "AUTHORITY_DENIED", "Duplicate lease scope")
        seen_scopes.add(scope["scope"])
        if actor_type == "lane":
            fail(scope["laneNodeId"] == subject["laneNodeId"], "AUTHORITY_DENIED", "Lane binding scope crosses lane nodes")
    if actor_type not in {"lane", "host"}:
        fail(not scopes, "AUTHORITY_DENIED", "Only lane or host bindings may have lease scopes")
    return dict(binding)


def load_binding(store: Store, args: argparse.Namespace, capability: str) -> Dict[str, Any]:
    binding_id = getattr(args, "actor_binding", None)
    unsafe = getattr(args, "test_only_unsafe_actor_flags", False)
    if unsafe:
        fail(os.environ.get("OPERATOR_GRAPH_TESTING") == "1", "AUTHORITY_DENIED", "Test-only actor flags require OPERATOR_GRAPH_TESTING=1")
        actor_type = getattr(args, "actor_type", None)
        actor_id = getattr(args, "actor_id", None)
        caps = sorted(set(getattr(args, "test_only_capability", []) or []))
        fail(actor_type in ACTOR_TYPES and valid_string(actor_id, 256, pattern=True), "AUTHORITY_DENIED", "Test-only actor identity is invalid")
        subject: Dict[str, Any] = {"type": actor_type, "id": actor_id}
        lane_node = getattr(args, "test_only_lane_node_id", None)
        host_runner = getattr(args, "test_only_host_runner_id", None)
        if actor_type == "lane":
            fail(valid_string(lane_node, 128, pattern=True), "AUTHORITY_DENIED", "Test lane actor requires --test-only-lane-node-id")
            subject["laneNodeId"] = lane_node
        elif actor_type == "host":
            fail(valid_string(host_runner, 128, pattern=True), "AUTHORITY_DENIED", "Test host actor requires --test-only-host-runner-id")
            subject["hostRunnerId"] = host_runner
        scopes = []
        for raw in getattr(args, "test_only_lease_scope", []) or []:
            parts = raw.split("=", 1)
            fail(len(parts) == 2, "USAGE", "Test lease scope must be SCOPE=LANE_NODE")
            scopes.append({"scope": parts[0], "laneNodeId": parts[1]})
        binding = {"schemaVersion": BINDING_VERSION, "bindingId": f"test-{actor_type}-{actor_id}",
                   "subject": subject, "capabilities": caps, "leaseScopes": scopes}
        binding = validate_binding(binding, binding["bindingId"])
    else:
        fail(valid_binding_id(binding_id), "AUTHORITY_DENIED", "--actor-binding is required")
        path = store.binding_dir / f"{binding_id}.json"
        fail(store.binding_dir.is_dir() and not store.binding_dir.is_symlink(), "AUTHORITY_DENIED", "Trusted binding directory is missing or unsafe")
        fail((store.binding_dir.stat().st_mode & 0o022) == 0, "AUTHORITY_DENIED", "Binding directory is group/world writable")
        fail(path.parent.resolve() == store.binding_dir.resolve(), "AUTHORITY_DENIED", "Actor binding path escapes trusted directory")
        fail(path.exists() and not path.is_symlink() and stat.S_ISREG(path.stat().st_mode), "AUTHORITY_DENIED", "Actor binding file is missing or unsafe")
        fail((path.stat().st_mode & 0o022) == 0, "AUTHORITY_DENIED", "Actor binding file is group/world writable")
        binding = read_json_file(path, "AUTHORITY_DENIED", "AUTHORITY_DENIED", MAX_BINDING_BYTES)
        binding = validate_binding(binding, binding_id)
    fail(capability in binding["capabilities"], "AUTHORITY_DENIED", f"Actor binding lacks capability: {capability}")
    binding["bindingHash"] = sha256_value({key: binding[key] for key in ("schemaVersion", "bindingId", "subject", "capabilities", "leaseScopes")})
    return binding


def actor_record(binding: Mapping[str, Any]) -> Dict[str, Any]:
    return {
        "type": binding["subject"]["type"],
        "id": binding["subject"]["id"],
        "bindingId": binding["bindingId"],
        "bindingHash": binding["bindingHash"],
        "capabilities": binding["capabilities"],
        "subject": binding["subject"],
        "leaseScopes": binding["leaseScopes"],
    }


def require_request_id(args: argparse.Namespace) -> str:
    value = args.request_id
    fail(valid_string(value, 256, pattern=True), "USAGE", "request-id is invalid")
    return value


def fingerprint(command: str, binding: Mapping[str, Any], args: argparse.Namespace, intent: Mapping[str, Any]) -> str:
    payload = {
        "command": command,
        "bindingId": binding["bindingId"],
        "bindingHash": binding["bindingHash"],
        "subject": binding["subject"],
        "intent": dict(intent),
        "expectedRevision": getattr(args, "expected_revision", None),
        "testOnlyNow": getattr(args, "test_only_now", None),
    }
    return sha256_value(payload)


def duplicate_result(events: Sequence[Mapping[str, Any]], request_id: str, request_fingerprint: str) -> Optional[Dict[str, Any]]:
    for event in events:
        if event["requestId"] == request_id:
            fail(event["requestFingerprint"] == request_fingerprint, "REQUEST_CONFLICT", "requestId was already used for different intent", {
                "requestId": request_id,
                "originalFingerprint": event["requestFingerprint"],
                "requestedFingerprint": request_fingerprint,
            })
            return dict(event["result"])
    return None


def check_cas(projection: Mapping[str, Any], expected: Optional[int]) -> None:
    if expected is not None and projection["revision"] != expected:
        raise GraphError("REVISION_CONFLICT", "Projection revision does not match expected revision", {
            "expectedRevision": expected, "actualRevision": projection["revision"]
        })


def transaction_time(args: argparse.Namespace, binding: Mapping[str, Any], events: Sequence[Mapping[str, Any]]) -> dt.datetime:
    injected = getattr(args, "test_only_now", None)
    if injected is not None:
        fail(os.environ.get("OPERATOR_GRAPH_TESTING") == "1" and "test-injection" in binding["capabilities"],
             "AUTHORITY_DENIED", "Test-only time injection is not authorized")
        now = parse_time(injected)
    else:
        now = utc_now()
    if events:
        previous = parse_time(events[-1]["occurredAt"], "CORRUPT_JOURNAL")
        fail(now >= previous, "CLOCK_ROLLBACK", "Trusted transaction time moved behind the journal", {
            "previousEventTime": events[-1]["occurredAt"], "transactionTime": format_time(now)
        })
    return now


def fault_mode(args: argparse.Namespace, binding: Mapping[str, Any]) -> Optional[str]:
    value = getattr(args, "test_only_fault", None)
    if value is not None:
        fail(os.environ.get("OPERATOR_GRAPH_TESTING") == "1" and "test-injection" in binding["capabilities"],
             "AUTHORITY_DENIED", "Test-only fault injection is not authorized")
    return value


def make_result(command: str, request_id: str, revision: int, data: Mapping[str, Any]) -> Dict[str, Any]:
    return {"ok": True, "command": command, "requestId": request_id, "revision": revision, "data": dict(data)}


def commit_event(store: Store, events: Sequence[Mapping[str, Any]], event_type: str, data: Mapping[str, Any],
                 binding: Mapping[str, Any], request_id: str, request_fingerprint: str,
                 result_data: Mapping[str, Any], occurred_at: str, fault: Optional[str]) -> Dict[str, Any]:
    sequence = len(events) + 1
    command = EVENT_COMMANDS[event_type]
    result = make_result(command, request_id, sequence, result_data)
    event = {
        "schemaVersion": EVENT_VERSION,
        "sequence": sequence,
        "eventId": str(uuid.uuid4()),
        "requestId": request_id,
        "requestFingerprint": request_fingerprint,
        "occurredAt": occurred_at,
        "actor": actor_record(binding),
        "type": event_type,
        "data": dict(data),
        "result": result,
    }
    encoded = canonical_bytes(event)
    if fault == "partial-tail":
        append_bytes(store.events_path, encoded[:max(1, len(encoded) // 2)])
        raise GraphError("TEST_FAULT", "Injected partial journal tail")
    append_bytes(store.events_path, encoded)
    if fault == "after-event":
        raise GraphError("TEST_FAULT", "Injected crash after committed event")
    replayed_definition, replayed_projection = replay([*events, event])
    if fault == "after-definition":
        atomic_write_json(store.definition_path, replayed_definition)
        raise GraphError("TEST_FAULT", "Injected crash between definition and projection replacement")
    store.write_materialized(replayed_definition, replayed_projection)
    return result


def default_definition(graph_id: str) -> Dict[str, Any]:
    return {"schemaVersion": GRAPH_VERSION, "graphId": graph_id, "definitionRevision": 1, "nodes": [], "edges": []}


def immutable_replacement_checks(definition: Mapping[str, Any], projection: Mapping[str, Any], replacement: Mapping[str, Any]) -> None:
    old_nodes = {node["id"]: node for node in definition["nodes"]}
    new_nodes = {node["id"]: node for node in replacement["nodes"]}
    fail(set(old_nodes) <= set(new_nodes), "INVALID_GRAPH", "Definition replacement cannot remove historical node IDs", {
        "removed": sorted(set(old_nodes) - set(new_nodes))
    })
    for node_id, old_node in old_nodes.items():
        new_node = new_nodes[node_id]
        fail(new_node["kind"] == old_node["kind"], "INVALID_GRAPH", f"Definition replacement cannot change node kind: {node_id}")
        state = projection["nodeStates"][node_id]
        if state != old_node["initialState"] or state in TERMINAL_STATES[family_for(old_node["kind"])]:
            old_identity = {key: old_node[key] for key in ("kind", "title", "initialState", "metadata")}
            new_identity = {key: new_node[key] for key in ("kind", "title", "initialState", "metadata")}
            fail(old_identity == new_identity, "INVALID_GRAPH", f"Definition replacement cannot rewrite activated or terminal node: {node_id}")
            old_edges = [edge for edge in definition["edges"] if edge["from"] == node_id and edge["kind"] in IMMUTABLE_EXECUTION_EDGE_KINDS]
            new_edges = [edge for edge in replacement["edges"] if edge["from"] == node_id and edge["kind"] in IMMUTABLE_EXECUTION_EDGE_KINDS]
            fail(old_edges == new_edges, "INVALID_GRAPH", f"Definition replacement cannot rewrite activated or terminal node edges: {node_id}")


def command_init(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "graph-init")
    fail(binding["subject"]["type"] in {"operator", "system"}, "AUTHORITY_DENIED", "Only operator or system bindings may initialize a graph")
    if args.definition:
        definition = load_input_definition(Path(args.definition))
        definition["definitionRevision"] = 1
    else:
        fail(valid_string(args.graph_id, 128, pattern=True), "USAGE", "graph-id is invalid")
        definition = default_definition(args.graph_id)
    definition = validate_definition(definition, materialized=True)
    intent = {"definitionHash": definition_hash(definition)}
    request_fingerprint = fingerprint("init", binding, args, intent)
    with store.lock():
        if store.has_state():
            current_definition, projection, events = store.load()
            duplicate = duplicate_result(events, request_id, request_fingerprint)
            if duplicate is not None:
                return duplicate
            return {"ok": True, "command": "init", "requestId": request_id, "revision": projection["revision"],
                    "data": {"initialized": False, "alreadyInitialized": True, "graphId": current_definition["graphId"]}}
        events: List[Dict[str, Any]] = []
        now = transaction_time(args, binding, events)
        result_data = {"initialized": True, "alreadyInitialized": False, "graphId": definition["graphId"]}
        return commit_event(store, events, "graph.initialized", {"definition": definition}, binding, request_id,
                            request_fingerprint, result_data, format_time(now), fault_mode(args, binding))


def command_validate(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    if args.definition:
        definition = load_input_definition(Path(args.definition))
        return {"ok": True, "command": "validate", "data": {"valid": True, "graphId": definition["graphId"], "nodes": len(definition["nodes"]), "edges": len(definition["edges"])}}
    with store.lock():
        definition, projection, events = store.load()
        return {"ok": True, "command": "validate", "data": {"valid": True, "graphId": definition["graphId"], "revision": projection["revision"], "events": len(events)}}


def snapshot_data(definition: Mapping[str, Any], projection: Mapping[str, Any], events: Sequence[Mapping[str, Any]]) -> Dict[str, Any]:
    nodes = []
    for node in definition["nodes"]:
        item = dict(node)
        item["state"] = projection["nodeStates"][node["id"]]
        nodes.append(item)
    return {
        "schemaVersion": PROJECTION_VERSION,
        "graphId": definition["graphId"],
        "revision": projection["revision"],
        "definitionRevision": definition["definitionRevision"],
        "definitionHash": projection["definitionHash"],
        "updatedAt": projection["updatedAt"],
        "eventCount": len(events),
        "nodes": nodes,
        "edges": definition["edges"],
        "leases": projection["leases"],
        "leaseFences": projection["leaseFences"],
    }


def command_status(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    with store.lock():
        definition, projection, events = store.load()
        return {"ok": True, "command": args.command, "data": snapshot_data(definition, projection, events)}


def command_replace_definition(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "graph-replace")
    fail(binding["subject"]["type"] in {"operator", "system"}, "AUTHORITY_DENIED", "Only operator or system bindings may replace definitions or priority")
    replacement = load_input_definition(Path(args.definition))
    intent = {"definitionHash": definition_hash(replacement)}
    request_fingerprint = fingerprint("replace-definition", binding, args, intent)
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        fail(replacement["graphId"] == definition["graphId"], "INVALID_GRAPH", "replace-definition cannot change graphId")
        replacement["definitionRevision"] = definition["definitionRevision"] + 1
        replacement = validate_definition(replacement, materialized=True)
        immutable_replacement_checks(definition, projection, replacement)
        now = transaction_time(args, binding, events)
        result_data = {"graphId": replacement["graphId"], "definitionRevision": replacement["definitionRevision"],
                       "nodes": len(replacement["nodes"]), "edges": len(replacement["edges"])}
        return commit_event(store, events, "definition.replaced", {"definition": replacement}, binding, request_id,
                            request_fingerprint, result_data, format_time(now), fault_mode(args, binding))


def require_current_lease(projection: Mapping[str, Any], node_id: str, binding: Mapping[str, Any],
                          lease_id: Optional[str], fence: Optional[int], now: dt.datetime) -> None:
    lease = projection["leases"].get(node_id)
    if lease is None:
        if lease_id is not None or fence is not None:
            raise GraphError("FENCE_STALE", f"No current lease exists for node: {node_id}")
        fail(binding["subject"]["type"] in {"operator", "system"}, "LEASE_REQUIRED", f"Actor requires a valid lease to transition node: {node_id}")
        return
    if lease_id != lease["leaseId"] or fence != lease["fence"]:
        code = "FENCE_STALE" if fence is not None and fence <= lease["fence"] else "LEASE_CONFLICT"
        raise GraphError(code, f"Lease credentials do not match current owner for node: {node_id}", {"currentFence": lease["fence"]})
    fail(parse_time(lease["expiresAt"], "INVALID_STATE") > now, "LEASE_EXPIRED", f"Lease has expired for node: {node_id}")
    fail(lease["holder"]["bindingId"] == binding["bindingId"], "AUTHORITY_DENIED", f"Actor binding does not hold lease for node: {node_id}")


def command_transition(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "transition")
    intent = {"nodeId": args.node_id, "targetState": args.state, "leaseId": args.lease_id, "fence": args.fence}
    request_fingerprint = fingerprint("transition", binding, args, intent)
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        node = find_node(definition, args.node_id)
        family = family_for(node["kind"])
        fail(family != "gate", "AUTHORITY_DENIED", "Human gates must be decided with 'gate decide'")
        fail(not (binding["subject"]["type"] == "subagent" and node["kind"] == "integration"), "AUTHORITY_DENIED", "Subagents cannot integrate")
        current = projection["nodeStates"][args.node_id]
        fail(args.state in TRANSITIONS[family][current], "INVALID_TRANSITION", f"Transition is not allowed for {node['kind']}: {current} -> {args.state}", {"allowed": sorted(TRANSITIONS[family][current])})
        now = transaction_time(args, binding, events)
        require_current_lease(projection, args.node_id, binding, args.lease_id, args.fence, now)
        transition_preconditions(definition, projection, args.node_id, args.state)
        data = {"nodeId": args.node_id, "from": current, "to": args.state}
        return commit_event(store, events, "node.transitioned", data, binding, request_id, request_fingerprint,
                            data, format_time(now), fault_mode(args, binding))


def command_gate_decide(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "gate-decision")
    fail(binding["subject"]["type"] == "human", "AUTHORITY_DENIED", "Only a human binding may decide a human gate")
    intent = {"nodeId": args.node_id, "decision": args.decision}
    request_fingerprint = fingerprint("gate decide", binding, args, intent)
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        node = find_node(definition, args.node_id)
        fail(node["kind"] == "human-gate", "INVALID_GRAPH", f"Node is not a human gate: {args.node_id}")
        current = projection["nodeStates"][args.node_id]
        fail(args.decision in TRANSITIONS["gate"][current], "INVALID_TRANSITION", f"Gate decision is not allowed: {current} -> {args.decision}")
        now = transaction_time(args, binding, events)
        data = {"nodeId": args.node_id, "from": current, "to": args.decision}
        return commit_event(store, events, "gate.decided", data, binding, request_id, request_fingerprint,
                            data, format_time(now), fault_mode(args, binding))


def validate_ttl(value: int) -> None:
    fail(isinstance(value, int) and 1 <= value <= 86400, "USAGE", "ttl-seconds must be between 1 and 86400")


def binding_scope(binding: Mapping[str, Any], holder_scope: str) -> Dict[str, str]:
    fail(valid_string(holder_scope, 512, pattern=True), "USAGE", "holder-scope is required and invalid")
    matches = [scope for scope in binding["leaseScopes"] if scope["scope"] == holder_scope]
    fail(len(matches) == 1, "AUTHORITY_DENIED", "Holder scope is not explicitly bound", {"scope": holder_scope})
    return matches[0]


def command_lease_acquire(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "lease")
    fail(binding["subject"]["type"] in {"lane", "host"}, "AUTHORITY_DENIED", "Only lane or host bindings may acquire ownership leases")
    validate_ttl(args.ttl_seconds)
    scope = binding_scope(binding, args.holder_scope)
    lease_id = args.lease_id or str(uuid.uuid4())
    fail(valid_string(lease_id, 256, pattern=True), "USAGE", "lease-id is invalid")
    intent = {"nodeId": args.node_id, "leaseId": args.lease_id, "holderScope": args.holder_scope, "ttlSeconds": args.ttl_seconds}
    request_fingerprint = fingerprint("lease acquire", binding, args, intent)
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        node = find_node(definition, args.node_id)
        fail(node["kind"] in WORK_KINDS, "AUTHORITY_DENIED", "Only work nodes may be leased")
        assigned = any(edge["kind"] == "assigned-to" and edge["from"] == args.node_id and edge["to"] == scope["laneNodeId"] for edge in definition["edges"])
        fail(assigned, "AUTHORITY_DENIED", "Lease acquisition does not match assigned-to", {"nodeId": args.node_id, "laneNodeId": scope["laneNodeId"]})
        now = transaction_time(args, binding, events)
        current = projection["leases"].get(args.node_id)
        if current is not None and parse_time(current["expiresAt"], "INVALID_STATE") > now:
            raise GraphError("LEASE_CONFLICT", f"Node already has an unexpired lease: {args.node_id}", {"leaseId": current["leaseId"], "fence": current["fence"], "expiresAt": current["expiresAt"]})
        if current is not None:
            execution = node["metadata"].get("execution", {})
            safe = projection["nodeStates"][args.node_id] in {"pending", "ready", "blocked"}
            fail(execution.get("idempotent") is True and execution.get("reclaimable") is True and safe,
                 "RECONCILIATION_REQUIRED", f"Expired lease requires sweep/reconciliation before reassignment: {args.node_id}")
        fence = projection["leaseFences"].get(args.node_id, 0) + 1
        timestamp = format_time(now)
        lease = {
            "schemaVersion": LEASE_VERSION,
            "nodeId": args.node_id,
            "leaseId": lease_id,
            "holder": {"actorType": binding["subject"]["type"], "actorId": binding["subject"]["id"],
                       "bindingId": binding["bindingId"], "scope": scope["scope"], "laneNodeId": scope["laneNodeId"]},
            "acquiredAt": timestamp,
            "renewedAt": timestamp,
            "expiresAt": format_time(now + dt.timedelta(seconds=args.ttl_seconds)),
            "fence": fence,
        }
        validate_lease(lease)
        result_data = {"lease": lease, "reclaimed": current is not None}
        return commit_event(store, events, "lease.acquired", {"lease": lease}, binding, request_id,
                            request_fingerprint, result_data, timestamp, fault_mode(args, binding))


def check_lease_operation(projection: Mapping[str, Any], args: argparse.Namespace, binding: Mapping[str, Any], now: dt.datetime) -> Dict[str, Any]:
    lease = projection["leases"].get(args.node_id)
    fail(lease is not None, "FENCE_STALE", f"No current lease exists for node: {args.node_id}")
    fail(args.lease_id == lease["leaseId"] and args.fence == lease["fence"], "FENCE_STALE", f"Lease credentials are stale for node: {args.node_id}", {"currentFence": lease["fence"]})
    fail(lease["holder"]["bindingId"] == binding["bindingId"], "AUTHORITY_DENIED", f"Actor binding does not hold lease for node: {args.node_id}")
    fail(parse_time(lease["expiresAt"], "INVALID_STATE") > now, "LEASE_EXPIRED", f"Lease has expired for node: {args.node_id}")
    return lease


def command_lease_renew(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "lease")
    validate_ttl(args.ttl_seconds)
    intent = {"nodeId": args.node_id, "leaseId": args.lease_id, "fence": args.fence, "ttlSeconds": args.ttl_seconds}
    request_fingerprint = fingerprint("lease renew", binding, args, intent)
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        now = transaction_time(args, binding, events)
        lease = dict(check_lease_operation(projection, args, binding, now))
        lease["renewedAt"] = format_time(now)
        lease["expiresAt"] = format_time(now + dt.timedelta(seconds=args.ttl_seconds))
        return commit_event(store, events, "lease.renewed", {"lease": lease}, binding, request_id,
                            request_fingerprint, {"lease": lease}, format_time(now), fault_mode(args, binding))


def command_lease_release(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "lease")
    intent = {"nodeId": args.node_id, "leaseId": args.lease_id, "fence": args.fence}
    request_fingerprint = fingerprint("lease release", binding, args, intent)
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        now = transaction_time(args, binding, events)
        lease = check_lease_operation(projection, args, binding, now)
        data = {"nodeId": args.node_id, "leaseId": lease["leaseId"], "fence": lease["fence"]}
        return commit_event(store, events, "lease.released", data, binding, request_id,
                            request_fingerprint, data, format_time(now), fault_mode(args, binding))


def command_lease_sweep(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "sweep")
    fail(binding["subject"]["type"] in {"operator", "system", "host"}, "AUTHORITY_DENIED", "Only operator, system, or host bindings may sweep leases")
    intent: Dict[str, Any] = {}
    request_fingerprint = fingerprint("lease sweep", binding, args, intent)
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        now = transaction_time(args, binding, events)
        expired = []
        for node_id, lease in sorted(projection["leases"].items()):
            if parse_time(lease["expiresAt"], "INVALID_STATE") <= now:
                node = find_node(definition, node_id)
                prior_state = projection["nodeStates"][node_id]
                execution = node["metadata"].get("execution", {})
                auto_safe = execution.get("idempotent") is True and execution.get("reclaimable") is True and prior_state in {"pending", "ready", "blocked"}
                reconciliation = not auto_safe and prior_state not in TERMINAL_STATES["work"]
                target_state = "blocked" if reconciliation else prior_state
                expired.append({"nodeId": node_id, "leaseId": lease["leaseId"], "fence": lease["fence"],
                                "fromState": prior_state, "toState": target_state, "reconciliation": reconciliation})
        data = {"expired": expired}
        return commit_event(store, events, "lease.swept", data, binding, request_id, request_fingerprint,
                            {"expired": expired, "count": len(expired)}, format_time(now), fault_mode(args, binding))


def command_replay_check(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    with store.lock():
        definition, projection, events = store.load(auto_roll_forward=True)
        return {"ok": True, "command": "replay check", "data": {"inSync": True, "revision": projection["revision"], "events": len(events), "graphId": definition["graphId"]}}


def command_replay_repair(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "replay-repair")
    fail(binding["subject"]["type"] in {"operator", "system"}, "AUTHORITY_DENIED", "Only operator or system bindings may repair replay drift")
    intent: Dict[str, Any] = {}
    request_fingerprint = fingerprint("replay repair", binding, args, intent)
    with store.lock():
        events = read_events(store.events_path, recover_tail=True)
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            definition, projection = replay(events)
            store.write_materialized(definition, projection)
            return duplicate
        definition, projection = replay(events)
        check_cas(projection, args.expected_revision)
        now = transaction_time(args, binding, events)
        repaired_revision = projection["revision"]
        return commit_event(store, events, "replay.repaired", {"repairedRevision": repaired_revision}, binding,
                            request_id, request_fingerprint, {"repairedRevision": repaired_revision},
                            format_time(now), fault_mode(args, binding))


def add_mutation_options(parser: argparse.ArgumentParser, cas: bool = True) -> None:
    parser.add_argument("--request-id", required=True)
    if cas:
        parser.add_argument("--expected-revision", type=int)
    parser.add_argument("--actor-binding")
    parser.add_argument("--test-only-now", help=argparse.SUPPRESS)
    parser.add_argument("--test-only-fault", choices=["partial-tail", "after-event", "after-definition"], help=argparse.SUPPRESS)
    parser.add_argument("--test-only-unsafe-actor-flags", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--actor-type", choices=sorted(ACTOR_TYPES), help=argparse.SUPPRESS)
    parser.add_argument("--actor-id", help=argparse.SUPPRESS)
    parser.add_argument("--test-only-capability", action="append", choices=sorted(CAPABILITIES), help=argparse.SUPPRESS)
    parser.add_argument("--test-only-lane-node-id", help=argparse.SUPPRESS)
    parser.add_argument("--test-only-host-runner-id", help=argparse.SUPPRESS)
    parser.add_argument("--test-only-lease-scope", action="append", help=argparse.SUPPRESS)


class JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise GraphError("USAGE", message)


def build_parser() -> argparse.ArgumentParser:
    parser = JSONArgumentParser(prog="operator-graph", description="Operator V5 typed control graph API")
    parser.add_argument("--operator-dir", default=os.environ.get("OPERATOR_DIR"), help="Operator state directory (defaults to OPERATOR_DIR)")
    sub = parser.add_subparsers(dest="command", required=True)

    init = sub.add_parser("init")
    init.add_argument("--definition")
    init.add_argument("--graph-id", default="operator")
    add_mutation_options(init, cas=False)
    init.set_defaults(handler=command_init)

    validate = sub.add_parser("validate")
    validate.add_argument("definition", nargs="?")
    validate.set_defaults(handler=command_validate)
    status = sub.add_parser("status")
    status.set_defaults(handler=command_status)
    snapshot = sub.add_parser("snapshot")
    snapshot.set_defaults(handler=command_status)

    replace = sub.add_parser("replace-definition")
    replace.add_argument("definition")
    add_mutation_options(replace)
    replace.set_defaults(handler=command_replace_definition)

    transition = sub.add_parser("transition")
    transition.add_argument("node_id")
    transition.add_argument("state")
    transition.add_argument("--lease-id")
    transition.add_argument("--fence", type=int)
    add_mutation_options(transition)
    transition.set_defaults(handler=command_transition)

    gate = sub.add_parser("gate")
    gate_sub = gate.add_subparsers(dest="gate_command", required=True)
    decide = gate_sub.add_parser("decide")
    decide.add_argument("node_id")
    decide.add_argument("decision", choices=["approved", "rejected"])
    add_mutation_options(decide)
    decide.set_defaults(handler=command_gate_decide)

    lease = sub.add_parser("lease")
    lease_sub = lease.add_subparsers(dest="lease_command", required=True)
    acquire = lease_sub.add_parser("acquire")
    acquire.add_argument("node_id")
    acquire.add_argument("--lease-id")
    acquire.add_argument("--holder-scope", required=True)
    acquire.add_argument("--ttl-seconds", type=int, default=300)
    add_mutation_options(acquire)
    acquire.set_defaults(handler=command_lease_acquire)
    renew = lease_sub.add_parser("renew")
    renew.add_argument("node_id")
    renew.add_argument("--lease-id", required=True)
    renew.add_argument("--fence", type=int, required=True)
    renew.add_argument("--ttl-seconds", type=int, default=300)
    add_mutation_options(renew)
    renew.set_defaults(handler=command_lease_renew)
    release = lease_sub.add_parser("release")
    release.add_argument("node_id")
    release.add_argument("--lease-id", required=True)
    release.add_argument("--fence", type=int, required=True)
    add_mutation_options(release)
    release.set_defaults(handler=command_lease_release)
    sweep = lease_sub.add_parser("sweep")
    add_mutation_options(sweep)
    sweep.set_defaults(handler=command_lease_sweep)

    replay_parser = sub.add_parser("replay")
    replay_sub = replay_parser.add_subparsers(dest="replay_command", required=True)
    replay_check = replay_sub.add_parser("check")
    replay_check.set_defaults(handler=command_replay_check)
    replay_repair = replay_sub.add_parser("repair")
    add_mutation_options(replay_repair)
    replay_repair.set_defaults(handler=command_replay_repair)
    return parser


def print_json(value: Any, stream: Any = sys.stdout) -> None:
    json.dump(value, stream, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
    stream.write("\n")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
        fail(args.operator_dir is not None and str(args.operator_dir).strip(), "USAGE", "--operator-dir or OPERATOR_DIR is required")
        store = Store(Path(args.operator_dir).expanduser().resolve())
        result = args.handler(store, args)
        print_json(result)
        return 0
    except GraphError as exc:
        payload: Dict[str, Any] = {"ok": False, "error": {"code": exc.code, "message": exc.message}}
        if exc.details is not None:
            payload["error"]["details"] = exc.details
        print_json(payload, sys.stderr)
        return EXIT_CODES.get(exc.code, 1)
    except (OSError, RecursionError, ValueError, TypeError) as exc:
        print_json({"ok": False, "error": {"code": "IO_ERROR", "message": str(exc)}}, sys.stderr)
        return EXIT_CODES["IO_ERROR"]
    except KeyboardInterrupt:
        print_json({"ok": False, "error": {"code": "INTERRUPTED", "message": "Interrupted"}}, sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
