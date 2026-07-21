#!/usr/bin/env python3
"""Operator V5 typed control graph runtime.

The journal is authoritative. Definition and projection files are deterministic
materializations updated under one host-aware transaction lock.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import ctypes
import ctypes.util
import datetime as dt
import hashlib
import heapq
import json
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
AUTHORITY_VERSION = "operator.authority-key/v1"
LOCK_VERSION = "operator.graph-lock/v1"
SNAPSHOT_VERSION = "operator.control-snapshot/v1"
PROOF_REQUEST_VERSION = "operator.mutation-proof-request/v1"
PROOF_EVENT_VERSION = "operator.mutation-event-proof/v1"
PROOF_CHALLENGE_VERSION = "operator.proof-challenge/v1"
PROOF_RESPONSE_VERSION = "operator.proof-response/v1"
CANONICAL_JSON_VERSION = "Operator Canonical JSON v1"

ACTOR_TYPES = {"operator", "lane", "host", "human", "subagent", "system"}
CAPABILITIES = {
    "graph-init", "graph-replace", "gate-decision", "lease", "transition",
    "sweep", "lease-resolve", "replay-repair",
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
    "lease.resolved": "lease resolve",
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
    "lease.resolved": "lease-resolve",
    "replay.repaired": "replay-repair",
}

MAX_GRAPH_BYTES = 4 * 1024 * 1024
MAX_BINDING_BYTES = 64 * 1024
MAX_JOURNAL_BYTES = 256 * 1024 * 1024
MAX_EVENT_BYTES = 8 * 1024 * 1024
MAX_PROOF_AUTH_CHALLENGE_BYTES = MAX_BINDING_BYTES
MAX_PROOF_EVENT_CHALLENGE_BYTES = MAX_EVENT_BYTES + MAX_BINDING_BYTES
MAX_PROOF_RESPONSE_BYTES = 4 * 1024
PROOF_EVENT_EOF_TIMEOUT_SECONDS = 1.0
MAX_FORWARD_CLOCK_SKEW_SECONDS = 5.0
OWNERLESS_LOCK_GRACE_SECONDS = 2.0
MAX_NODES = 10000
MAX_EDGES = 50000
MAX_METADATA_BYTES = 64 * 1024
MAX_JSON_DEPTH = 32
MAX_CANONICAL_ENVELOPE_DEPTH = 8
MAX_CANONICAL_DEPTH = MAX_JSON_DEPTH + MAX_CANONICAL_ENVELOPE_DEPTH
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
    "JOURNAL_FULL": 24,
    "CLOCK_SKEW": 25,
    "CLOCK_UNAVAILABLE": 26,
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


def has_surrogate(value: str) -> bool:
    return any(0xD800 <= ord(character) <= 0xDFFF for character in value)


def valid_string(value: Any, maximum: int, pattern: bool = False) -> bool:
    return (
        isinstance(value, str)
        and bool(value.strip())
        and len(value) <= maximum
        and not has_control(value)
        and not has_surrogate(value)
        and (not pattern or ID_PATTERN.fullmatch(value) is not None)
    )


def valid_binding_id(value: Any) -> bool:
    return isinstance(value, str) and len(value) <= 128 and BINDING_ID_PATTERN.fullmatch(value) is not None


def validate_json_value(value: Any, label: str, maximum_depth: int = MAX_JSON_DEPTH,
                        code: str = "INVALID_GRAPH") -> None:
    stack: List[Tuple[Any, int]] = [(value, 1)]
    count = 0
    while stack:
        current, depth = stack.pop()
        count += 1
        fail(count <= MAX_JSON_ITEMS, code, f"{label} contains too many values")
        fail(depth <= maximum_depth, code, f"{label} exceeds maximum depth {maximum_depth}")
        if isinstance(current, float):
            fail(False, code, f"{label} contains a floating-point number; {CANONICAL_JSON_VERSION} permits integers only")
        elif isinstance(current, str):
            fail(not has_control(current) and not has_surrogate(current), code,
                 f"{label} contains control characters or a Unicode surrogate")
        elif isinstance(current, dict):
            for key, item in current.items():
                fail(isinstance(key, str) and not has_control(key) and not has_surrogate(key), code,
                     f"{label} contains an invalid object key")
                stack.append((item, depth + 1))
        elif isinstance(current, list):
            for item in current:
                stack.append((item, depth + 1))
        else:
            fail(current is None or isinstance(current, (bool, int)), code,
                 f"{label} contains an unsupported JSON value")


def reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number: {value}")


def reject_float_number(value: str) -> None:
    raise ValueError(f"floating-point JSON number is not canonical: {value}")


def parse_canonical_integer(value: str) -> int:
    if value == "-0":
        raise ValueError("negative zero is not a canonical JSON integer")
    return int(value)


def reject_duplicate_object_pairs(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    value: Dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON object key: {key}")
        value[key] = item
    return value


def parse_json_bytes(data: bytes, path: Path, error_code: str) -> Dict[str, Any]:
    try:
        text = data.decode("utf-8")
        value = json.loads(text, parse_constant=reject_constant, parse_float=reject_float_number,
                           parse_int=parse_canonical_integer,
                           object_pairs_hook=reject_duplicate_object_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise GraphError(error_code, f"Invalid JSON: {path}", str(exc)) from exc
    fail(isinstance(value, dict), error_code, f"Expected a JSON object: {path}")
    validate_json_value(value, f"JSON file {path}", code=error_code)
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
    validate_json_value(value, "canonical JSON value", maximum_depth=MAX_CANONICAL_DEPTH)
    try:
        text = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
    except (TypeError, ValueError, UnicodeEncodeError, RecursionError) as exc:
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
        fail(state == INITIAL_STATES[family], "INVALID_GRAPH",
             f"New {kind} nodes must begin at transactional default state: {INITIAL_STATES[family]}")
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
            source_family = family_for(node_by_id[source]["kind"])
            actual_targets = set().union(*TRANSITIONS[source_family].values())
            fail(isinstance(protected, list) and bool(protected) and len(protected) == len(set(protected)),
                 "INVALID_GRAPH", f"gated-by edge {edge_id} requires unique protectedTransitions")
            fail(all(isinstance(item, str) and item in actual_targets for item in protected),
                 "INVALID_GRAPH", f"gated-by edge {edge_id} has an invalid protected transition")
            if node_by_id[source]["kind"] == "integration":
                fail({"ready", "active", "completed"} <= set(protected), "INVALID_GRAPH",
                     f"integration gated-by edge {edge_id} must protect ready, active, and completed")
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


def blank_projection(definition: Mapping[str, Any], occurred_at: str, sequence: int,
                     actor: Mapping[str, Any]) -> Dict[str, Any]:
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
        "executionStarted": {},
        "reconciliations": {},
        "bindingGenerations": {},
        "authorityKeyId": actor["keyId"],
        "authorityHash": actor["authorityHash"],
    }


def validate_lease(value: Mapping[str, Any], code: str = "INVALID_STATE") -> None:
    required = {"schemaVersion", "nodeId", "leaseId", "holder", "acquiredAt", "renewedAt", "expiresAt", "fence", "clock"}
    fail(isinstance(value, dict) and set(value) == required, code, "Lease fields are invalid")
    validate_version(value.get("schemaVersion"), LEASE_VERSION, "lease")
    fail(valid_string(value.get("nodeId"), 128, pattern=True), code, "Lease nodeId is invalid")
    fail(valid_string(value.get("leaseId"), 256, pattern=True), code, "Lease leaseId is invalid")
    holder = value.get("holder")
    holder_fields = {"actorType", "actorId", "bindingId", "bindingGeneration", "bindingHash", "scope", "laneNodeId"}
    fail(isinstance(holder, dict) and set(holder) == holder_fields, code, "Lease holder is invalid")
    fail(holder.get("actorType") in {"lane", "host"}, code, "Lease holder actorType is invalid")
    fail(valid_string(holder.get("actorId"), 256, pattern=True), code, "Lease holder actorId is invalid")
    fail(valid_binding_id(holder.get("bindingId")), code, "Lease holder bindingId is invalid")
    fail(isinstance(holder.get("bindingGeneration"), int) and not isinstance(holder["bindingGeneration"], bool)
         and holder["bindingGeneration"] >= 1, code, "Lease holder bindingGeneration is invalid")
    fail(isinstance(holder.get("bindingHash"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", holder["bindingHash"]),
         code, "Lease holder bindingHash is invalid")
    fail(valid_string(holder.get("scope"), 512, pattern=True), code, "Lease holder scope is invalid")
    fail(valid_string(holder.get("laneNodeId"), 128, pattern=True), code, "Lease holder laneNodeId is invalid")
    acquired = parse_time(value.get("acquiredAt"), code)
    renewed = parse_time(value.get("renewedAt"), code)
    expires = parse_time(value.get("expiresAt"), code)
    fail(acquired <= renewed < expires, code, "Lease timestamps are not ordered")
    fail(isinstance(value.get("fence"), int) and not isinstance(value["fence"], bool) and value["fence"] >= 1,
         code, "Lease fence is invalid")
    clock = value.get("clock")
    fail(isinstance(clock, dict) and set(clock) == {"hostId", "bootId", "monotonicSource", "acquiredMonotonicNs", "expiresMonotonicNs"},
         code, "Lease clock is invalid")
    fail(valid_string(clock.get("hostId"), 256) and valid_string(clock.get("bootId"), 256)
         and clock.get("monotonicSource") in {"linux-proc-uptime", "macos-mach-continuous"},
         code, "Lease clock identity is invalid")
    fail(all(isinstance(clock.get(key), int) and not isinstance(clock[key], bool) and clock[key] >= 0
             for key in ("acquiredMonotonicNs", "expiresMonotonicNs")), code, "Lease monotonic clock is invalid")
    fail(clock["expiresMonotonicNs"] > clock["acquiredMonotonicNs"], code, "Lease monotonic expiry is not ordered")


def validate_projection(value: Mapping[str, Any], definition: Mapping[str, Any]) -> None:
    required = {"schemaVersion", "graphId", "revision", "definitionRevision", "definitionHash", "updatedAt", "nodeStates", "leases", "leaseFences", "executionStarted", "reconciliations", "bindingGenerations", "authorityKeyId", "authorityHash"}
    fail(isinstance(value, dict) and set(value) == required, "INVALID_STATE", "Projection fields are invalid")
    validate_version(value.get("schemaVersion"), PROJECTION_VERSION, "projection")
    fail(value.get("graphId") == definition["graphId"], "INVALID_STATE", "Projection graphId does not match definition")
    fail(value.get("definitionRevision") == definition["definitionRevision"], "INVALID_STATE", "Projection definitionRevision does not match definition")
    fail(value.get("definitionHash") == definition_hash(definition), "INVALID_STATE", "Projection definitionHash does not match definition")
    fail(isinstance(value.get("revision"), int) and not isinstance(value["revision"], bool) and value["revision"] >= 1,
         "INVALID_STATE", "Projection revision is invalid")
    parse_time(value.get("updatedAt"), "INVALID_STATE")
    fail(valid_string(value.get("authorityKeyId"), 128, pattern=True), "INVALID_STATE", "Projection authorityKeyId is invalid")
    fail(isinstance(value.get("authorityHash"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", value["authorityHash"]),
         "INVALID_STATE", "Projection authorityHash is invalid")
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
    started = value.get("executionStarted")
    fail(isinstance(started, dict), "INVALID_STATE", "Projection executionStarted must be an object")
    for node_id, marker in started.items():
        fail(node_id in node_map and node_map[node_id]["kind"] in WORK_KINDS, "INVALID_STATE", f"Execution marker references invalid node: {node_id}")
        fail(isinstance(marker, dict) and set(marker) == {"revision", "occurredAt"}
             and isinstance(marker.get("revision"), int) and marker["revision"] >= 1, "INVALID_STATE", f"Execution marker is invalid: {node_id}")
        parse_time(marker.get("occurredAt"), "INVALID_STATE")
    reconciliations = value.get("reconciliations")
    fail(isinstance(reconciliations, dict), "INVALID_STATE", "Projection reconciliations must be an object")
    for node_id, record in reconciliations.items():
        fail(node_id in node_map and isinstance(record, dict), "INVALID_STATE", f"Reconciliation references invalid node: {node_id}")
        required_record = {"leaseId", "fence", "reason", "requiredAt", "priorState"}
        fail(set(record) == required_record and valid_string(record.get("leaseId"), 256, pattern=True)
             and isinstance(record.get("fence"), int) and record["fence"] >= 1
             and record.get("reason") in {"expired-unsafe", "binding-rotated", "clock-recovery"}
             and record.get("priorState") in STATES_BY_FAMILY["work"], "INVALID_STATE", f"Reconciliation record is invalid: {node_id}")
        parse_time(record.get("requiredAt"), "INVALID_STATE")
    generations = value.get("bindingGenerations")
    fail(isinstance(generations, dict), "INVALID_STATE", "Projection bindingGenerations must be an object")
    for binding_id, record in generations.items():
        fail(valid_binding_id(binding_id) and isinstance(record, dict) and set(record) == {"generation", "bindingHash"},
             "INVALID_STATE", f"Binding generation record is invalid: {binding_id}")
        fail(isinstance(record.get("generation"), int) and record["generation"] >= 1
             and isinstance(record.get("bindingHash"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", record["bindingHash"]),
             "INVALID_STATE", f"Binding generation value is invalid: {binding_id}")


def find_node(definition: Mapping[str, Any], node_id: str) -> Dict[str, Any]:
    for node in definition["nodes"]:
        if node["id"] == node_id:
            return node
    raise GraphError("INVALID_GRAPH", f"Unknown node: {node_id}")


def is_success_terminal(definition: Mapping[str, Any], projection: Mapping[str, Any], node_id: str) -> bool:
    node = find_node(definition, node_id)
    return projection["nodeStates"][node_id] in SUCCESS_TERMINAL[family_for(node["kind"])]


def valid_generated_lease_id(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        return False
    return parsed.version == 4 and str(parsed) == value


def validate_replayed_ttl(value: Any) -> int:
    fail(isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= 86400,
         "CORRUPT_JOURNAL", "Lease event ttlSeconds is outside 1..86400")
    return value


def transition_preconditions(definition: Mapping[str, Any], projection: Mapping[str, Any], node_id: str,
                             target_state: str) -> None:
    node = find_node(definition, node_id)
    edges = definition["edges"]
    if target_state in {"ready", "active", "completed"}:
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
    required = {"type", "id", "bindingId", "bindingGeneration", "bindingHash", "capabilityHash",
                "projectId", "graphId", "issuedAt", "expiresAt", "keyId", "signature", "capabilities", "subject",
                "leaseScopes", "proofKey", "authorityHash"}
    fail(isinstance(actor, dict) and set(actor) == required, code, "Event actor is invalid")
    fail(actor.get("type") in ACTOR_TYPES, code, "Event actor type is invalid")
    fail(valid_string(actor.get("id"), 256, pattern=True), code, "Event actor id is invalid")
    fail(valid_binding_id(actor.get("bindingId")), code, "Event actor bindingId is invalid")
    fail(isinstance(actor.get("bindingGeneration"), int) and not isinstance(actor["bindingGeneration"], bool)
         and actor["bindingGeneration"] >= 1, code, "Event actor bindingGeneration is invalid")
    fail(isinstance(actor.get("bindingHash"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", actor["bindingHash"]), code, "Event actor bindingHash is invalid")
    fail(isinstance(actor.get("capabilityHash"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", actor["capabilityHash"]), code, "Event actor capabilityHash is invalid")
    fail(isinstance(actor.get("authorityHash"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", actor["authorityHash"]),
         code, "Event actor authorityHash is invalid")
    for key in ("projectId", "graphId", "keyId"):
        fail(valid_string(actor.get(key), 128, pattern=True), code, f"Event actor {key} is invalid")
    fail(isinstance(actor.get("signature"), str) and 1 <= len(actor["signature"]) <= 2048
         and re.fullmatch(r"[A-Za-z0-9_-]+", actor["signature"]), code, "Event actor signature is invalid")
    issued = parse_time(actor.get("issuedAt"), code)
    expires = parse_time(actor.get("expiresAt"), code)
    fail(issued < expires, code, "Event actor validity interval is invalid")
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
    validate_proof_key(actor.get("proofKey"), code)
    recorded_binding = {
        "schemaVersion": BINDING_VERSION, "bindingId": actor["bindingId"],
        "generation": actor["bindingGeneration"], "projectId": actor["projectId"], "graphId": actor["graphId"],
        "issuedAt": actor["issuedAt"], "expiresAt": actor["expiresAt"], "subject": actor["subject"],
        "capabilities": actor["capabilities"], "leaseScopes": actor["leaseScopes"], "proofKey": actor["proofKey"],
    }
    fail(actor["bindingHash"] == sha256_value(recorded_binding), code, "Event actor bindingHash does not match authorization snapshot")
    fail(actor["capabilityHash"] == sha256_value(capability_payload(recorded_binding)), code,
         "Event actor capabilityHash does not match authorization snapshot")


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
    if event_type == "lease.resolved":
        return dict(data)
    if event_type == "replay.repaired":
        return {"repairedRevision": data["repairedRevision"]}
    raise GraphError("CORRUPT_JOURNAL", f"Unknown event type: {event_type}")


def validate_event(event: Any, sequence: int, seen_requests: Set[str], seen_event_ids: Set[str]) -> None:
    required = {"schemaVersion", "sequence", "eventId", "requestId", "requestFingerprint", "occurredAt", "clock",
                "actor", "type", "intent", "expectedRevision", "data", "result", "proof"}
    fail(isinstance(event, dict) and set(event) == required, "CORRUPT_JOURNAL", "Event fields are invalid", {"line": sequence})
    validate_version(event.get("schemaVersion"), EVENT_VERSION, "event")
    fail(event.get("sequence") == sequence, "CORRUPT_JOURNAL", "Event sequence is not strict", {"expected": sequence, "actual": event.get("sequence")})
    fail(valid_string(event.get("eventId"), 128, pattern=True), "CORRUPT_JOURNAL", "Event eventId is invalid")
    fail(event["eventId"] not in seen_event_ids, "CORRUPT_JOURNAL", f"Duplicate eventId in journal: {event['eventId']}")
    seen_event_ids.add(event["eventId"])
    request_id = event.get("requestId")
    fail(valid_string(request_id, 256, pattern=True), "CORRUPT_JOURNAL", "Event requestId is invalid")
    fail(request_id not in seen_requests, "CORRUPT_JOURNAL", f"Duplicate requestId in journal: {request_id}")
    seen_requests.add(request_id)
    fail(isinstance(event.get("requestFingerprint"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", event["requestFingerprint"]),
         "CORRUPT_JOURNAL", "Event requestFingerprint is invalid")
    parse_time(event.get("occurredAt"), "CORRUPT_JOURNAL")
    clock = event.get("clock")
    fail(isinstance(clock, dict) and set(clock) == {"hostId", "bootId", "monotonicSource", "monotonicNs"}
         and valid_string(clock.get("hostId"), 256) and valid_string(clock.get("bootId"), 256)
         and clock.get("monotonicSource") in {"linux-proc-uptime", "macos-mach-continuous"}
         and isinstance(clock.get("monotonicNs"), int) and not isinstance(clock["monotonicNs"], bool)
         and clock["monotonicNs"] >= 0, "CORRUPT_JOURNAL", "Event clock is invalid")
    validate_actor_record(event.get("actor"), "CORRUPT_JOURNAL")
    event_type = event.get("type")
    fail(event_type in EVENT_COMMANDS, "CORRUPT_JOURNAL", f"Unknown event type: {event_type}")
    fail(EVENT_CAPABILITIES[event_type] in event["actor"]["capabilities"], "CORRUPT_JOURNAL", f"Event actor lacked required capability: {event_type}")
    fail(isinstance(event.get("intent"), dict), "CORRUPT_JOURNAL", "Event intent must be an object")
    fail(event.get("expectedRevision") is None or (isinstance(event["expectedRevision"], int)
         and not isinstance(event["expectedRevision"], bool) and event["expectedRevision"] >= 1),
         "CORRUPT_JOURNAL", "Event expectedRevision is invalid")
    recorded_authorization = recorded_authorization_payload(event)
    validate_authorization_payload(recorded_authorization, "CORRUPT_JOURNAL")
    expected_fingerprint = sha256_value(recorded_authorization)
    fail(event["requestFingerprint"] == expected_fingerprint, "CORRUPT_JOURNAL", "Event request fingerprint does not match canonical intent")
    fail(isinstance(event.get("data"), dict), "CORRUPT_JOURNAL", "Event data must be an object")
    result = event.get("result")
    result_fields = {"ok", "command", "requestId", "revision", "data"}
    fail(isinstance(result, dict) and set(result) == result_fields, "CORRUPT_JOURNAL", "Event result fields are invalid")
    fail(result.get("ok") is True and result.get("command") == EVENT_COMMANDS[event_type]
         and result.get("requestId") == request_id and result.get("revision") == sequence
         and isinstance(result.get("data"), dict), "CORRUPT_JOURNAL", "Event result is invalid")
    validate_event_proof(event)


def read_events(path: Path, recover_tail: bool = False) -> List[Dict[str, Any]]:
    if not path.is_file():
        raise GraphError("NOT_INITIALIZED", f"Missing event journal: {path}")
    try:
        size = path.stat().st_size
        fail(size <= MAX_JOURNAL_BYTES + MAX_EVENT_BYTES, "CORRUPT_JOURNAL", "Event journal exceeds recoverable size")
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
    fail(len(data) <= MAX_JOURNAL_BYTES, "CORRUPT_JOURNAL", "Committed event journal is too large")
    fail(bool(data), "CORRUPT_JOURNAL", "Event journal has no committed records")
    events: List[Dict[str, Any]] = []
    seen_requests: Set[str] = set()
    seen_event_ids: Set[str] = set()
    previous_time: Optional[dt.datetime] = None
    for line_number, raw_line in enumerate(data.splitlines(keepends=True), 1):
        fail(raw_line.endswith(b"\n") and len(raw_line) <= MAX_EVENT_BYTES, "CORRUPT_JOURNAL", "Invalid journal record boundary", {"line": line_number})
        try:
            event = json.loads(raw_line.decode("utf-8"), parse_constant=reject_constant,
                               parse_float=reject_float_number, parse_int=parse_canonical_integer,
                               object_pairs_hook=reject_duplicate_object_pairs)
            validate_json_value(event, f"journal event {line_number}",
                                maximum_depth=MAX_CANONICAL_DEPTH, code="CORRUPT_JOURNAL")
            validate_event(event, line_number, seen_requests, seen_event_ids)
        except GraphError:
            raise
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
            raise GraphError("CORRUPT_JOURNAL", "Journal contains invalid JSON", {"line": line_number, "error": str(exc)}) from exc
        occurred = parse_time(event["occurredAt"], "CORRUPT_JOURNAL")
        fail(previous_time is None or occurred >= previous_time, "CORRUPT_JOURNAL", "Event time moved backwards", {"line": line_number})
        if (events and event["clock"]["hostId"] == events[-1]["clock"]["hostId"]
                and event["clock"]["bootId"] == events[-1]["clock"]["bootId"]
                and event["clock"]["monotonicSource"] == events[-1]["clock"]["monotonicSource"]):
            monotonic_delta = (event["clock"]["monotonicNs"] - events[-1]["clock"]["monotonicNs"]) / 1_000_000_000
            fail(monotonic_delta >= 0, "CORRUPT_JOURNAL", "Event monotonic clock moved backwards", {"line": line_number})
            wall_delta = (occurred - previous_time).total_seconds() if previous_time is not None else 0
            fail(wall_delta <= monotonic_delta + MAX_FORWARD_CLOCK_SKEW_SECONDS, "CORRUPT_JOURNAL",
                 "Event wall clock exceeded bounded forward skew", {"line": line_number})
        previous_time = occurred
        events.append(event)
    return events


def _replay(events: Sequence[Mapping[str, Any]], authority: Optional[Mapping[str, Any]] = None) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    definition: Optional[Dict[str, Any]] = None
    projection: Optional[Dict[str, Any]] = None
    for event in events:
        event_type = event["type"]
        data = event["data"]
        sequence = event["sequence"]
        occurred_at = event["occurredAt"]
        prior_definition = definition
        prior_projection = None if projection is None else json.loads(json.dumps(projection))
        occurred = parse_time(occurred_at, "CORRUPT_JOURNAL")
        if authority is not None:
            fail(event["actor"]["projectId"] == authority["projectId"]
                 and event["actor"]["graphId"] == authority["graphId"]
                 and event["actor"]["keyId"] == authority["keyId"]
                 and event["actor"]["authorityHash"] == sha256_value(authority),
                 "CORRUPT_JOURNAL", "Event authorization does not match the trust anchor")
            recorded_payload = {
                "schemaVersion": BINDING_VERSION, "bindingId": event["actor"]["bindingId"],
                "generation": event["actor"]["bindingGeneration"], "projectId": event["actor"]["projectId"],
                "graphId": event["actor"]["graphId"], "issuedAt": event["actor"]["issuedAt"],
                "expiresAt": event["actor"]["expiresAt"], "subject": event["actor"]["subject"],
                "capabilities": event["actor"]["capabilities"], "leaseScopes": event["actor"]["leaseScopes"],
                "proofKey": event["actor"]["proofKey"],
            }
            try:
                verify_rsa_signature(recorded_payload, event["actor"]["signature"],
                                     authority["publicKey"]["n"], authority["publicKey"]["e"])
            except GraphError as exc:
                raise GraphError("CORRUPT_JOURNAL", "Event actor signature verification failed", exc.details) from exc
        fail(parse_time(event["actor"]["issuedAt"], "CORRUPT_JOURNAL") <= occurred
             < parse_time(event["actor"]["expiresAt"], "CORRUPT_JOURNAL"),
             "CORRUPT_JOURNAL", "Event occurred outside actor binding validity")
        fail(event["expectedRevision"] is None or event["expectedRevision"] == sequence - 1,
             "CORRUPT_JOURNAL", "Event CAS evidence does not match prior revision")
        if sequence == 1:
            fail(event_type == "graph.initialized", "CORRUPT_JOURNAL", "First event must be graph.initialized")
        if event_type == "graph.initialized":
            fail(sequence == 1 and definition is None and set(data) == {"definition"}, "CORRUPT_JOURNAL", "graph.initialized data is invalid")
            fail(event["actor"]["type"] in {"operator", "system"}, "CORRUPT_JOURNAL", "Unauthorized graph initialization actor")
            definition = validate_definition(data["definition"], materialized=True)
            fail(event["actor"]["graphId"] == definition["graphId"], "CORRUPT_JOURNAL", "Initialization authority graph mismatch")
            projection = blank_projection(definition, occurred_at, sequence, event["actor"])
        else:
            fail(definition is not None and projection is not None, "CORRUPT_JOURNAL", "Event appears before initialization")
            fail(event["actor"]["graphId"] == definition["graphId"]
                 and event["actor"]["projectId"] == events[0]["actor"]["projectId"]
                 and event["actor"]["authorityHash"] == projection["authorityHash"]
                 and event["actor"]["keyId"] == projection["authorityKeyId"],
                 "CORRUPT_JOURNAL", "Event authority project or graph mismatch")
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
                    if node_id in projection["executionStarted"] or current_state != old_node["initialState"] or current_state in TERMINAL_STATES[family_for(old_node["kind"])]:
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
                        fail(not lease_clock_expired(current_lease, event["clock"], "CORRUPT_JOURNAL"),
                             "CORRUPT_JOURNAL", "Expired lease transitioned a node")
                        fail(current_lease["holder"]["bindingId"] == event["actor"]["bindingId"]
                             and current_lease["holder"]["bindingGeneration"] == event["actor"]["bindingGeneration"]
                             and current_lease["holder"]["bindingHash"] == event["actor"]["bindingHash"],
                             "CORRUPT_JOURNAL", "Transition binding did not hold lease")
                    transition_preconditions(definition, projection, node["id"], data["to"])
                projection["nodeStates"][node["id"]] = data["to"]
            elif event_type == "lease.acquired":
                fail(set(data) == {"lease"}, "CORRUPT_JOURNAL", "lease.acquired data is invalid")
                lease = data["lease"]
                validate_lease(lease, "CORRUPT_JOURNAL")
                node = find_node(definition, lease["nodeId"])
                fail(node["kind"] in WORK_KINDS and event["actor"]["type"] in {"lane", "host"}, "CORRUPT_JOURNAL", "Invalid lease acquisition actor or node")
                fail(projection["nodeStates"][node["id"]] not in TERMINAL_STATES["work"],
                     "CORRUPT_JOURNAL", "Lease was acquired on terminal work")
                intent = event["intent"]
                fail(set(intent) == {"nodeId", "leaseId", "holderScope", "ttlSeconds"}
                     and intent["nodeId"] == node["id"] and intent["holderScope"] == lease["holder"]["scope"],
                     "CORRUPT_JOURNAL", "Lease acquisition intent does not match the lease")
                ttl_seconds = validate_replayed_ttl(intent["ttlSeconds"])
                if intent["leaseId"] is None:
                    fail(valid_generated_lease_id(lease["leaseId"]), "CORRUPT_JOURNAL",
                         "Generated lease ID is not a canonical UUIDv4")
                else:
                    fail(intent["leaseId"] == lease["leaseId"], "CORRUPT_JOURNAL",
                         "Requested lease ID does not match the lease")
                recorded_scope = [scope for scope in event["actor"]["leaseScopes"] if scope["scope"] == intent["holderScope"]]
                fail(len(recorded_scope) == 1 and recorded_scope[0]["laneNodeId"] == lease["holder"]["laneNodeId"],
                     "CORRUPT_JOURNAL", "Lease holder scope was not present in recorded actor binding")
                expected_holder = {
                    "actorType": event["actor"]["type"], "actorId": event["actor"]["id"],
                    "bindingId": event["actor"]["bindingId"],
                    "bindingGeneration": event["actor"]["bindingGeneration"],
                    "bindingHash": event["actor"]["bindingHash"], "scope": intent["holderScope"],
                    "laneNodeId": recorded_scope[0]["laneNodeId"],
                }
                fail(lease["holder"] == expected_holder, "CORRUPT_JOURNAL",
                     "Lease holder identity diverges from the signed actor and intent")
                assigned = any(edge["kind"] == "assigned-to" and edge["from"] == node["id"] and edge["to"] == lease["holder"]["laneNodeId"] for edge in definition["edges"])
                fail(assigned, "CORRUPT_JOURNAL", "Lease acquisition violated assignment")
                current = projection["leases"].get(node["id"])
                if current is not None:
                    fail(lease_clock_expired(current, event["clock"], "CORRUPT_JOURNAL"), "CORRUPT_JOURNAL", "Lease acquired over unexpired lease")
                    execution = node["metadata"].get("execution", {})
                    safe = projection["nodeStates"][node["id"]] in {"pending", "ready", "blocked"}
                    fail(execution.get("idempotent") is True and execution.get("reclaimable") is True and safe,
                         "CORRUPT_JOURNAL", "Unsafe automatic lease reclaim")
                fail(lease["fence"] == projection["leaseFences"].get(node["id"], 0) + 1, "CORRUPT_JOURNAL", "Lease fence is not monotonic")
                fail(lease["acquiredAt"] == occurred_at and lease["renewedAt"] == occurred_at, "CORRUPT_JOURNAL", "Lease acquisition time mismatch")
                fail(lease["clock"]["hostId"] == event["clock"]["hostId"] and lease["clock"]["bootId"] == event["clock"]["bootId"]
                     and lease["clock"]["monotonicSource"] == event["clock"]["monotonicSource"]
                     and lease["clock"]["acquiredMonotonicNs"] == event["clock"]["monotonicNs"]
                     and lease["clock"]["expiresMonotonicNs"] == event["clock"]["monotonicNs"] + ttl_seconds * 1_000_000_000,
                     "CORRUPT_JOURNAL", "Lease acquisition clock mismatch")
                fail(lease["expiresAt"] == format_time(occurred + dt.timedelta(seconds=ttl_seconds)),
                     "CORRUPT_JOURNAL", "Lease acquisition wall expiry does not match ttlSeconds")
                fail(node["id"] not in projection["reconciliations"], "CORRUPT_JOURNAL", "Lease acquired while reconciliation was required")
                projection["leases"][node["id"]] = lease
                projection["leaseFences"][node["id"]] = lease["fence"]
                projection["executionStarted"].setdefault(node["id"], {"revision": sequence, "occurredAt": occurred_at})
            elif event_type == "lease.renewed":
                fail(set(data) == {"lease"}, "CORRUPT_JOURNAL", "lease.renewed data is invalid")
                lease = data["lease"]
                validate_lease(lease, "CORRUPT_JOURNAL")
                current = projection["leases"].get(lease["nodeId"])
                fail(current is not None and current["leaseId"] == lease["leaseId"] and current["fence"] == lease["fence"], "CORRUPT_JOURNAL", "Renewal does not match current lease")
                intent = event["intent"]
                fail(set(intent) == {"nodeId", "leaseId", "fence", "ttlSeconds"}
                     and intent["nodeId"] == current["nodeId"] and intent["leaseId"] == current["leaseId"]
                     and intent["fence"] == current["fence"],
                     "CORRUPT_JOURNAL", "Lease renewal intent does not match the current lease")
                ttl_seconds = validate_replayed_ttl(intent["ttlSeconds"])
                fail(event["actor"]["type"] in {"lane", "host"}, "CORRUPT_JOURNAL", "Invalid lease renewal actor")
                recorded_scope = [scope for scope in event["actor"]["leaseScopes"] if scope["scope"] == current["holder"]["scope"]]
                expected_holder = {
                    "actorType": event["actor"]["type"], "actorId": event["actor"]["id"],
                    "bindingId": event["actor"]["bindingId"],
                    "bindingGeneration": event["actor"]["bindingGeneration"],
                    "bindingHash": event["actor"]["bindingHash"], "scope": current["holder"]["scope"],
                    "laneNodeId": current["holder"]["laneNodeId"],
                }
                fail(len(recorded_scope) == 1 and recorded_scope[0]["laneNodeId"] == current["holder"]["laneNodeId"]
                     and current["holder"] == expected_holder,
                     "CORRUPT_JOURNAL", "Lease renewal actor does not match the holder")
                fail(current["holder"]["bindingId"] == event["actor"]["bindingId"]
                     and current["holder"]["bindingGeneration"] == event["actor"]["bindingGeneration"]
                     and current["holder"]["bindingHash"] == event["actor"]["bindingHash"]
                     and not lease_clock_expired(current, event["clock"], "CORRUPT_JOURNAL"),
                     "CORRUPT_JOURNAL", "Unauthorized or expired renewal")
                expected_lease = json.loads(json.dumps(current))
                expected_lease["renewedAt"] = occurred_at
                expected_lease["expiresAt"] = format_time(occurred + dt.timedelta(seconds=ttl_seconds))
                expected_lease["clock"]["expiresMonotonicNs"] = event["clock"]["monotonicNs"] + ttl_seconds * 1_000_000_000
                fail(lease == expected_lease, "CORRUPT_JOURNAL",
                     "Renewal changed immutable fields or expiry outside live command semantics")
                projection["leases"][lease["nodeId"]] = lease
            elif event_type == "lease.released":
                fail(set(data) == {"nodeId", "leaseId", "fence"}, "CORRUPT_JOURNAL", "lease.released data is invalid")
                current = projection["leases"].get(data["nodeId"])
                fail(current is not None and current["leaseId"] == data["leaseId"] and current["fence"] == data["fence"], "CORRUPT_JOURNAL", "Release does not match current lease")
                fail(current["holder"]["bindingId"] == event["actor"]["bindingId"]
                     and current["holder"]["bindingGeneration"] == event["actor"]["bindingGeneration"]
                     and current["holder"]["bindingHash"] == event["actor"]["bindingHash"]
                     and not lease_clock_expired(current, event["clock"], "CORRUPT_JOURNAL"),
                     "CORRUPT_JOURNAL", "Unauthorized or expired release")
                projection["leases"].pop(data["nodeId"])
            elif event_type == "lease.swept":
                fail(set(data) == {"expired"} and event["actor"]["type"] in {"operator", "system", "host"}, "CORRUPT_JOURNAL", "lease.swept data or actor is invalid")
                expected = []
                for node_id, lease in sorted(projection["leases"].items()):
                    if lease_clock_expired(lease, event["clock"], "CORRUPT_JOURNAL"):
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
                    if item["reconciliation"]:
                        projection["reconciliations"][item["nodeId"]] = {
                            "leaseId": item["leaseId"], "fence": item["fence"], "reason": "expired-unsafe",
                            "requiredAt": occurred_at, "priorState": item["fromState"],
                        }
            elif event_type == "lease.resolved":
                fail(set(data) == {"nodeId", "leaseId", "fence", "action", "fromState", "toState", "reason", "evidence"}
                     and event["actor"]["type"] in {"operator", "system", "human"},
                     "CORRUPT_JOURNAL", "lease.resolved data or actor is invalid")
                fail(data["action"] in {"retry", "cancel", "complete"}, "CORRUPT_JOURNAL", "Unknown reconciliation action")
                fail(data["reason"] in {"expired-unsafe", "binding-rotated", "clock-recovery"}, "CORRUPT_JOURNAL", "Unknown reconciliation reason")
                current_lease = projection["leases"].get(data["nodeId"])
                record = projection["reconciliations"].get(data["nodeId"])
                if record is None and current_lease is not None:
                    record = {"leaseId": current_lease["leaseId"], "fence": current_lease["fence"],
                              "reason": data["reason"], "requiredAt": occurred_at,
                              "priorState": projection["nodeStates"][data["nodeId"]]}
                fail(record is not None and record["leaseId"] == data["leaseId"] and record["fence"] == data["fence"],
                     "CORRUPT_JOURNAL", "Resolution does not match reconciliation")
                fail(record["reason"] == data["reason"], "CORRUPT_JOURNAL", "Resolution reason does not match reconciliation")
                evidence = data["evidence"]
                fail(isinstance(evidence, dict), "CORRUPT_JOURNAL", "Resolution evidence is invalid")
                fail(data["fromState"] == projection["nodeStates"][data["nodeId"]], "CORRUPT_JOURNAL", "Resolution source state mismatch")
                expected_to = ("blocked" if data["fromState"] == "active" else data["fromState"]) if data["action"] == "retry" else ("cancelled" if data["action"] == "cancel" else "completed")
                fail(data["toState"] == expected_to, "CORRUPT_JOURNAL", "Resolution target state mismatch")
                if data["reason"] == "expired-unsafe":
                    fail(data["nodeId"] in projection["reconciliations"], "CORRUPT_JOURNAL",
                         "Expired-unsafe resolution lacked persisted reconciliation")
                    fail(evidence == {"kind": "persisted-reconciliation", "requiredAt": record["requiredAt"]},
                         "CORRUPT_JOURNAL", "Expired-unsafe resolution evidence is invalid")
                if data["reason"] == "binding-rotated":
                    fail(current_lease is not None and set(evidence) == {"kind", "currentBinding"}
                         and evidence.get("kind") == "binding-rotation" and authority is not None,
                         "CORRUPT_JOURNAL", "Binding-rotation resolution evidence is invalid")
                    replacement = validate_binding(evidence["currentBinding"], current_lease["holder"]["bindingId"], authority)
                    fail(replacement["generation"] > current_lease["holder"]["bindingGeneration"]
                         and replacement["bindingHash"] != current_lease["holder"]["bindingHash"],
                         "CORRUPT_JOURNAL", "Binding-rotation resolution lacked a real rotation")
                    fail(parse_time(replacement["issuedAt"], "CORRUPT_JOURNAL") <= occurred,
                         "CORRUPT_JOURNAL", "Binding-rotation evidence was not issued at resolution time")
                if data["reason"] == "clock-recovery":
                    fail(current_lease is not None and (
                        current_lease["clock"]["hostId"] != event["clock"]["hostId"]
                        or current_lease["clock"]["bootId"] != event["clock"]["bootId"]
                        or current_lease["clock"]["monotonicSource"] != event["clock"]["monotonicSource"]),
                        "CORRUPT_JOURNAL", "Clock-recovery resolution lacked a clock discontinuity")
                    fail(evidence == {"kind": "clock-discontinuity", "leaseClock": current_lease["clock"],
                                      "eventClock": event["clock"]},
                         "CORRUPT_JOURNAL", "Clock-recovery resolution evidence is invalid")
                if data["action"] == "complete":
                    transition_preconditions(definition, projection, data["nodeId"], "completed")
                projection["leases"].pop(data["nodeId"], None)
                projection["reconciliations"].pop(data["nodeId"], None)
                projection["nodeStates"][data["nodeId"]] = data["toState"]
            elif event_type == "replay.repaired":
                fail(set(data) == {"repairedRevision"} and data["repairedRevision"] == sequence - 1
                     and event["actor"]["type"] in {"operator", "system"}, "CORRUPT_JOURNAL", "replay.repaired data or actor is invalid")
        assert definition is not None and projection is not None
        expected_data = expected_result_data(event_type, data, prior_definition, prior_projection)
        fail(event["result"]["data"] == expected_data, "CORRUPT_JOURNAL", f"Event result data mismatch: {event_type}")
        projection["revision"] = sequence
        projection["updatedAt"] = occurred_at
        observed = projection["bindingGenerations"].get(event["actor"]["bindingId"])
        if observed is not None:
            fail(event["actor"]["bindingGeneration"] >= observed["generation"], "CORRUPT_JOURNAL", "Rotated actor binding was replayed")
            if event["actor"]["bindingGeneration"] == observed["generation"]:
                fail(event["actor"]["bindingHash"] == observed["bindingHash"], "CORRUPT_JOURNAL", "Actor binding generation changed content")
        projection["bindingGenerations"][event["actor"]["bindingId"]] = {
            "generation": event["actor"]["bindingGeneration"], "bindingHash": event["actor"]["bindingHash"],
        }
    assert definition is not None and projection is not None
    validate_projection(projection, definition)
    return definition, projection


def replay(events: Sequence[Mapping[str, Any]], authority: Optional[Mapping[str, Any]] = None) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    try:
        return _replay(events, authority)
    except GraphError as exc:
        if exc.code in {"CORRUPT_JOURNAL", "UNKNOWN_VERSION"}:
            raise
        raise GraphError("CORRUPT_JOURNAL", exc.message, exc.details) from exc
    except (KeyError, TypeError, ValueError, RecursionError) as exc:
        raise GraphError("CORRUPT_JOURNAL", "Journal event is semantically invalid", str(exc)) from exc


def lease_clock_expired(lease: Mapping[str, Any], clock: Mapping[str, Any], code: str = "INVALID_STATE") -> bool:
    lease_clock = lease["clock"]
    fail(clock["hostId"] == lease_clock["hostId"] and clock["bootId"] == lease_clock["bootId"]
         and clock["monotonicSource"] == lease_clock["monotonicSource"],
         code, "Lease expiry requires explicit recovery after host or boot change")
    return clock["monotonicNs"] >= lease_clock["expiresMonotonicNs"]


def fsync_directory(path: Path) -> None:
    try:
        descriptor = os.open(str(path), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write_json(path: Path, value: Any, before_replace: Optional[Any] = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}.{uuid.uuid4()}")
    try:
        with temporary.open("wb") as handle:
            handle.write(canonical_bytes(value))
            handle.flush()
            os.fsync(handle.fileno())
        if before_replace is not None:
            before_replace()
        os.replace(temporary, path)
        fsync_directory(path.parent)
    except GraphError:
        with contextlib.suppress(OSError):
            temporary.unlink()
        raise
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


class MachTimebaseInfo(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def macos_continuous_time_ns() -> int:
    try:
        library_name = ctypes.util.find_library("System") or "/usr/lib/libSystem.B.dylib"
        library = ctypes.CDLL(library_name, use_errno=True)
        continuous = library.mach_continuous_time
        continuous.argtypes = []
        continuous.restype = ctypes.c_uint64
        timebase = library.mach_timebase_info
        timebase.argtypes = [ctypes.POINTER(MachTimebaseInfo)]
        timebase.restype = ctypes.c_int
        info = MachTimebaseInfo()
        fail(timebase(ctypes.byref(info)) == 0 and info.numer > 0 and info.denom > 0,
             "CLOCK_UNAVAILABLE", "macOS continuous clock timebase is unavailable")
        return int(continuous()) * int(info.numer) // int(info.denom)
    except GraphError:
        raise
    except (AttributeError, OSError, TypeError, ValueError) as exc:
        raise GraphError("CLOCK_UNAVAILABLE", "macOS mach_continuous_time is unavailable", str(exc)) from exc


def host_monotonic_sample() -> Tuple[str, int]:
    if sys.platform.startswith("linux"):
        linux_uptime = Path("/proc/uptime")
        try:
            value = int(float(linux_uptime.read_text(encoding="utf-8").split()[0]) * 1_000_000_000)
            fail(value >= 0, "CLOCK_UNAVAILABLE", "Linux boot-relative uptime is invalid")
            return "linux-proc-uptime", value
        except GraphError:
            raise
        except (OSError, ValueError, IndexError) as exc:
            raise GraphError("CLOCK_UNAVAILABLE", "Linux /proc/uptime is unavailable", str(exc)) from exc
    if sys.platform == "darwin":
        return "macos-mach-continuous", macos_continuous_time_ns()
    raise GraphError("CLOCK_UNAVAILABLE", "No persisted cross-process monotonic clock is available on this platform")


def host_monotonic_ns() -> int:
    return host_monotonic_sample()[1]


class DirectoryLock:
    def __init__(self, path: Path, timeout: float = 10.0, lease_seconds: float = 30.0):
        self.path = path
        self.timeout = timeout
        self.lease_seconds = lease_seconds
        self.token = str(uuid.uuid4())
        self.epoch = time.monotonic_ns()
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
            "epoch": self.epoch,
            "heartbeatAt": format_time(now),
            "expiresAt": format_time(now + dt.timedelta(seconds=self.lease_seconds)),
        }

    def __enter__(self) -> "DirectoryLock":
        deadline = time.monotonic() + self.timeout
        while True:
            created = False
            try:
                self.path.mkdir(mode=0o700)
                created = True
                atomic_write_json(self.path / "owner.json", self.owner())
                self.heartbeat_thread = threading.Thread(target=self._heartbeat, daemon=True)
                self.heartbeat_thread.start()
                return self
            except FileExistsError:
                self._break_stale()
                if time.monotonic() >= deadline:
                    raise GraphError("LOCK_TIMEOUT", f"Timed out waiting for graph lock: {self.path}")
                time.sleep(0.025)
            except GraphError:
                if created:
                    with contextlib.suppress(OSError):
                        shutil.rmtree(self.path)
                raise
            except OSError as exc:
                if created:
                    with contextlib.suppress(OSError):
                        shutil.rmtree(self.path)
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
            required = {"schemaVersion", "hostId", "bootId", "pid", "processStart", "token", "epoch", "heartbeatAt", "expiresAt"}
            if set(owner) != required or owner.get("schemaVersion") != LOCK_VERSION:
                raise GraphError("LOCK_TIMEOUT", "Malformed graph lock owner")
            same_host_boot = owner["hostId"] == HOST_ID and owner["bootId"] == BOOT_ID
            if not same_host_boot:
                return
            confirmed_dead_or_reused = False
            try:
                pid = int(owner["pid"])
                os.kill(pid, 0)
                confirmed_dead_or_reused = process_start(pid) != owner["processStart"]
            except (ProcessLookupError, ValueError):
                confirmed_dead_or_reused = True
            except PermissionError:
                confirmed_dead_or_reused = False
            if not confirmed_dead_or_reused:
                return
        except GraphError:
            try:
                age = time.time() - self.path.stat().st_mtime
            except OSError:
                return
            if age < OWNERLESS_LOCK_GRACE_SECONDS:
                return
        stale = self.path.with_name(f".lock.stale.{uuid.uuid4()}")
        try:
            os.rename(self.path, stale)
        except OSError:
            return
        shutil.rmtree(stale, ignore_errors=True)

    def assert_owned(self) -> None:
        owner = read_json_file(self.path / "owner.json", "LOCK_TIMEOUT", "LOCK_TIMEOUT", MAX_BINDING_BYTES)
        fail(owner.get("token") == self.token and owner.get("epoch") == self.epoch
             and owner.get("hostId") == HOST_ID and owner.get("bootId") == BOOT_ID
             and owner.get("pid") == self.pid and owner.get("processStart") == self.start,
             "LOCK_TIMEOUT", "Graph transaction lock ownership was lost")

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
        self.authority_path = self.operator_dir / "authority" / "control-graph-public-key.json"
        self.definition_path = self.graph_dir / "definition.json"
        self.projection_path = self.graph_dir / "projection.json"
        self.events_path = self.graph_dir / "events.jsonl"
        self.lock_path = self.graph_dir / ".lock"
        self.active_lock: Optional[DirectoryLock] = None

    def lock(self) -> DirectoryLock:
        self.graph_dir.mkdir(parents=True, exist_ok=True)
        return StoreLock(self, DirectoryLock(self.lock_path, timeout=10.0))

    def assert_lock(self) -> None:
        fail(self.active_lock is not None, "IO_ERROR", "Graph transaction lock is not held")
        self.active_lock.assert_owned()

    def load_authority(self) -> Dict[str, Any]:
        fail(self.authority_path.exists() and not self.authority_path.is_symlink()
             and stat.S_ISREG(self.authority_path.stat().st_mode), "AUTHORITY_DENIED", "Authority trust anchor is missing or unsafe")
        return validate_authority(read_json_file(self.authority_path, "AUTHORITY_DENIED", "AUTHORITY_DENIED", MAX_BINDING_BYTES))

    def has_state(self) -> bool:
        if self.definition_path.exists() or self.projection_path.exists():
            return True
        try:
            return self.events_path.stat().st_size > 0
        except OSError:
            return False

    def load(self, auto_roll_forward: bool = True) -> Tuple[Dict[str, Any], Dict[str, Any], List[Dict[str, Any]]]:
        events = read_events(self.events_path, recover_tail=True)
        replayed_definition, replayed_projection = replay(events, self.load_authority())
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
        self.assert_lock()
        atomic_write_json(self.definition_path, definition, self.assert_lock)
        self.assert_lock()
        atomic_write_json(self.projection_path, projection, self.assert_lock)


class StoreLock:
    def __init__(self, store: Store, lock: DirectoryLock):
        self.store = store
        self.lock = lock

    def __enter__(self) -> DirectoryLock:
        self.lock.__enter__()
        self.store.active_lock = self.lock
        return self.lock

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        self.store.active_lock = None
        self.lock.__exit__(exc_type, exc, traceback)


def binding_payload(binding: Mapping[str, Any]) -> Dict[str, Any]:
    return {key: binding[key] for key in (
        "schemaVersion", "bindingId", "generation", "projectId", "graphId", "issuedAt", "expiresAt",
        "subject", "capabilities", "leaseScopes", "proofKey",
    )}


def capability_payload(binding: Mapping[str, Any]) -> Dict[str, Any]:
    return {key: binding[key] for key in ("subject", "capabilities", "leaseScopes", "proofKey")}


def decode_base64url(value: Any, code: str = "AUTHORITY_DENIED", label: str = "Capability") -> bytes:
    fail(isinstance(value, str) and 1 <= len(value) <= 2048 and not has_control(value),
         code, f"{label} signature is invalid")
    try:
        return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except (ValueError, TypeError) as exc:
        raise GraphError(code, f"{label} signature is invalid") from exc


def verify_rsa_signature(payload: Mapping[str, Any], signature: str, modulus_hex: str, exponent: int,
                         code: str = "AUTHORITY_DENIED", label: str = "Capability") -> None:
    try:
        modulus = int(modulus_hex, 16)
    except (TypeError, ValueError) as exc:
        raise GraphError(code, f"{label} public key is invalid") from exc
    fail(modulus.bit_length() >= 1024 and modulus.bit_length() <= 8192 and exponent in {3, 65537},
         code, f"{label} public key is invalid")
    encoded_signature = decode_base64url(signature, code, label)
    width = (modulus.bit_length() + 7) // 8
    fail(len(encoded_signature) == width, code, f"{label} signature has the wrong size")
    decoded = pow(int.from_bytes(encoded_signature, "big"), exponent, modulus).to_bytes(width, "big")
    digest_info = bytes.fromhex("3031300d060960864801650304020105000420") + hashlib.sha256(canonical_bytes(payload)).digest()
    expected = b"\x00\x01" + b"\xff" * (width - len(digest_info) - 3) + b"\x00" + digest_info
    fail(decoded == expected, code, f"{label} signature verification failed")


def validate_proof_key(value: Any, code: str = "AUTHORITY_DENIED") -> Dict[str, Any]:
    fail(isinstance(value, dict) and set(value) == {"keyId", "algorithm", "publicKey"},
         code, "Actor proof key fields are invalid")
    fail(valid_string(value.get("keyId"), 128, pattern=True) and value.get("algorithm") == "RS256",
         code, "Actor proof key metadata is invalid")
    public_key = value.get("publicKey")
    fail(isinstance(public_key, dict) and set(public_key) == {"n", "e"}
         and isinstance(public_key.get("n"), str) and re.fullmatch(r"[0-9a-f]+", public_key["n"])
         and isinstance(public_key.get("e"), int), code, "Actor proof public key is invalid")
    try:
        modulus = int(public_key["n"], 16)
    except ValueError as exc:
        raise GraphError(code, "Actor proof public key is invalid") from exc
    fail(1024 <= modulus.bit_length() <= 8192 and public_key["e"] in {3, 65537},
         code, "Actor proof public key is invalid")
    return dict(value)


def validate_authority(value: Mapping[str, Any]) -> Dict[str, Any]:
    validate_json_value(value, "authority trust anchor", code="AUTHORITY_DENIED")
    required = {"schemaVersion", "projectId", "graphId", "keyId", "canonicalHostId", "algorithm", "publicKey"}
    fail(isinstance(value, dict) and set(value) == required, "AUTHORITY_DENIED", "Authority trust anchor fields are invalid")
    fail(value.get("schemaVersion") == AUTHORITY_VERSION, "AUTHORITY_DENIED", "Unsupported authority trust anchor version")
    for key in ("projectId", "graphId", "keyId"):
        fail(valid_string(value.get(key), 128, pattern=True), "AUTHORITY_DENIED", f"Authority {key} is invalid")
    fail(valid_string(value.get("canonicalHostId"), 256), "AUTHORITY_DENIED", "Authority canonicalHostId is invalid")
    fail(value.get("algorithm") == "RS256", "AUTHORITY_DENIED", "Authority algorithm is unsupported")
    public_key = value.get("publicKey")
    fail(isinstance(public_key, dict) and set(public_key) == {"n", "e"}
         and isinstance(public_key.get("n"), str) and re.fullmatch(r"[0-9a-f]+", public_key["n"])
         and isinstance(public_key.get("e"), int), "AUTHORITY_DENIED", "Authority public key is invalid")
    return dict(value)


def validate_binding(binding: Mapping[str, Any], expected_id: str, authority: Mapping[str, Any]) -> Dict[str, Any]:
    validate_json_value(binding, "actor binding", code="AUTHORITY_DENIED")
    required = {"schemaVersion", "bindingId", "generation", "projectId", "graphId", "issuedAt", "expiresAt",
                "subject", "capabilities", "leaseScopes", "proofKey", "signature"}
    require_keys(binding, required, set(), "actor binding", "AUTHORITY_DENIED")
    fail(binding.get("schemaVersion") == BINDING_VERSION, "AUTHORITY_DENIED", "Unsupported actor binding version")
    fail(binding.get("bindingId") == expected_id and valid_binding_id(expected_id), "AUTHORITY_DENIED", "Actor binding ID is invalid")
    fail(isinstance(binding.get("generation"), int) and not isinstance(binding["generation"], bool)
         and binding["generation"] >= 1, "AUTHORITY_DENIED", "Actor binding generation is invalid")
    fail(binding.get("projectId") == authority["projectId"], "AUTHORITY_DENIED", "Actor binding belongs to a different project")
    fail(binding.get("graphId") == authority["graphId"], "AUTHORITY_DENIED", "Actor binding belongs to a different graph")
    issued = parse_time(binding.get("issuedAt"), "AUTHORITY_DENIED")
    expires = parse_time(binding.get("expiresAt"), "AUTHORITY_DENIED")
    fail(issued < expires, "AUTHORITY_DENIED", "Actor binding validity interval is invalid")
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
    validate_proof_key(binding.get("proofKey"))
    signature = binding.get("signature")
    fail(isinstance(signature, dict) and set(signature) == {"keyId", "algorithm", "value"}
         and signature.get("keyId") == authority["keyId"] and signature.get("algorithm") == authority["algorithm"],
         "AUTHORITY_DENIED", "Actor binding signature metadata is invalid")
    verify_rsa_signature(binding_payload(binding), signature.get("value"), authority["publicKey"]["n"], authority["publicKey"]["e"])
    result = dict(binding)
    result["bindingHash"] = sha256_value(binding_payload(binding))
    result["capabilityHash"] = sha256_value(capability_payload(binding))
    result["authorityHash"] = sha256_value(authority)
    return result


def load_binding(store: Store, args: argparse.Namespace, capability: str) -> Dict[str, Any]:
    binding_id = getattr(args, "actor_binding", None)
    fail(valid_binding_id(binding_id), "AUTHORITY_DENIED", "--actor-binding is required")
    authority = store.load_authority()
    fail(authority["canonicalHostId"] == HOST_ID, "AUTHORITY_DENIED",
         "Mutations must run on the authority's canonical host", {"canonicalHostId": authority["canonicalHostId"], "localHostId": HOST_ID})
    path = store.binding_dir / f"{binding_id}.json"
    fail(path.parent.resolve() == store.binding_dir.resolve(), "AUTHORITY_DENIED", "Actor binding path escapes binding directory")
    fail(path.exists() and not path.is_symlink() and stat.S_ISREG(path.stat().st_mode), "AUTHORITY_DENIED", "Actor binding document is missing or unsafe")
    binding = read_json_file(path, "AUTHORITY_DENIED", "AUTHORITY_DENIED", MAX_BINDING_BYTES)
    binding = validate_binding(binding, binding_id, authority)
    now = utc_now()
    fail(parse_time(binding["issuedAt"], "AUTHORITY_DENIED") <= now < parse_time(binding["expiresAt"], "AUTHORITY_DENIED"),
         "AUTHORITY_DENIED", "Actor binding is not currently valid")
    fail(capability in binding["capabilities"], "AUTHORITY_DENIED", f"Actor binding lacks capability: {capability}")
    return binding


def load_binding_by_id(store: Store, binding_id: str) -> Dict[str, Any]:
    fail(valid_binding_id(binding_id), "AUTHORITY_DENIED", "Actor binding ID is invalid")
    authority = store.load_authority()
    path = store.binding_dir / f"{binding_id}.json"
    fail(path.parent.resolve() == store.binding_dir.resolve() and path.exists() and not path.is_symlink()
         and stat.S_ISREG(path.stat().st_mode), "AUTHORITY_DENIED", "Actor binding document is missing or unsafe")
    return validate_binding(read_json_file(path, "AUTHORITY_DENIED", "AUTHORITY_DENIED", MAX_BINDING_BYTES),
                            binding_id, authority)


def actor_record(binding: Mapping[str, Any]) -> Dict[str, Any]:
    return {
        "type": binding["subject"]["type"],
        "id": binding["subject"]["id"],
        "bindingId": binding["bindingId"],
        "bindingGeneration": binding["generation"],
        "bindingHash": binding["bindingHash"],
        "capabilityHash": binding["capabilityHash"],
        "projectId": binding["projectId"],
        "graphId": binding["graphId"],
        "issuedAt": binding["issuedAt"],
        "expiresAt": binding["expiresAt"],
        "keyId": binding["signature"]["keyId"],
        "signature": binding["signature"]["value"],
        "capabilities": binding["capabilities"],
        "subject": binding["subject"],
        "leaseScopes": binding["leaseScopes"],
        "proofKey": binding["proofKey"],
        "authorityHash": binding["authorityHash"],
    }


class ProofChannel:
    """Full-duplex inherited socket to a caller-owned signing broker."""

    def __init__(self, descriptor: Any):
        fail(isinstance(descriptor, int) and not isinstance(descriptor, bool) and 3 <= descriptor <= 1024,
             "AUTHORITY_DENIED", "A caller proof broker socket is required via --proof-fd")
        try:
            self.socket = socket.socket(fileno=os.dup(descriptor))
            fail(self.socket.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) == socket.SOCK_STREAM,
                 "AUTHORITY_DENIED", "Caller proof descriptor must be a connected stream socket")
            self.socket.settimeout(5.0)
            self.next_phase = "authorize"
            self.proof_key_id: Optional[str] = None
        except GraphError:
            raise
        except OSError as exc:
            raise GraphError("AUTHORITY_DENIED", "Caller proof broker socket is unavailable", str(exc)) from exc

    def sign(self, phase: str, payload: Mapping[str, Any], proof_key: Mapping[str, Any]) -> str:
        fail(phase == self.next_phase, "AUTHORITY_DENIED", "Caller proof phase is duplicate or out of order")
        if self.proof_key_id is None:
            self.proof_key_id = proof_key["keyId"]
        fail(proof_key["keyId"] == self.proof_key_id, "AUTHORITY_DENIED",
             "Caller proof key changed within one mutation session")
        challenge = {"schemaVersion": PROOF_CHALLENGE_VERSION, "operation": "sign", "phase": phase,
                     "proofKeyId": proof_key["keyId"], "payload": dict(payload)}
        encoded = canonical_bytes(challenge)
        challenge_limit = (MAX_PROOF_AUTH_CHALLENGE_BYTES if phase == "authorize"
                           else MAX_PROOF_EVENT_CHALLENGE_BYTES)
        fail(len(encoded) <= challenge_limit, "AUTHORITY_DENIED", "Caller proof challenge is too large", {
            "phase": phase, "maximumBytes": challenge_limit, "actualBytes": len(encoded),
        })
        try:
            self.socket.sendall(encoded)
            response = bytearray()
            while not response.endswith(b"\n"):
                chunk = self.socket.recv(4096)
                fail(bool(chunk), "AUTHORITY_DENIED", "Caller proof broker closed without a response")
                response.extend(chunk)
                fail(len(response) <= MAX_PROOF_RESPONSE_BYTES, "AUTHORITY_DENIED", "Caller proof response is too large")
            value = json.loads(bytes(response).decode("utf-8"), parse_constant=reject_constant,
                               parse_float=reject_float_number, parse_int=parse_canonical_integer,
                               object_pairs_hook=reject_duplicate_object_pairs)
            validate_json_value(value, "caller proof broker response", code="AUTHORITY_DENIED")
        except GraphError:
            raise
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise GraphError("AUTHORITY_DENIED", "Caller proof broker response is invalid", str(exc)) from exc
        fail(isinstance(value, dict) and set(value) == {"schemaVersion", "phase", "proofKeyId", "signature"}
             and value.get("schemaVersion") == PROOF_RESPONSE_VERSION and value.get("phase") == phase
             and value.get("proofKeyId") == proof_key["keyId"],
             "AUTHORITY_DENIED", "Caller proof broker response does not match the challenge")
        signature = value.get("signature")
        verify_rsa_signature(payload, signature, proof_key["publicKey"]["n"], proof_key["publicKey"]["e"],
                             "AUTHORITY_DENIED", "Caller proof")
        if phase == "event":
            self.socket.settimeout(PROOF_EVENT_EOF_TIMEOUT_SECONDS)
            try:
                extra = self.socket.recv(1)
            except socket.timeout as exc:
                raise GraphError("AUTHORITY_DENIED", "Caller proof broker did not close its event response stream") from exc
            fail(extra == b"", "AUTHORITY_DENIED", "Caller proof broker sent bytes after its event response")
        self.next_phase = "event" if phase == "authorize" else "complete"
        return signature

    def close(self) -> None:
        with contextlib.suppress(OSError):
            self.socket.close()


def authorization_payload(command: str, binding: Mapping[str, Any], request_id: str,
                          intent: Mapping[str, Any], expected_revision: Optional[int]) -> Dict[str, Any]:
    return {
        "schemaVersion": PROOF_REQUEST_VERSION,
        "command": command,
        "requestId": request_id,
        "bindingId": binding["bindingId"],
        "bindingGeneration": binding["generation"],
        "bindingHash": binding["bindingHash"],
        "intent": dict(intent),
        "expectedRevision": expected_revision,
    }


def recorded_authorization_payload(event: Mapping[str, Any]) -> Dict[str, Any]:
    actor = event["actor"]
    return {
        "schemaVersion": PROOF_REQUEST_VERSION,
        "command": EVENT_COMMANDS[event["type"]],
        "requestId": event["requestId"],
        "bindingId": actor["bindingId"],
        "bindingGeneration": actor["bindingGeneration"],
        "bindingHash": actor["bindingHash"],
        "intent": event["intent"],
        "expectedRevision": event["expectedRevision"],
    }


def event_proof_payload(event_without_proof: Mapping[str, Any]) -> Dict[str, Any]:
    return {"schemaVersion": PROOF_EVENT_VERSION, "event": dict(event_without_proof)}


def validate_authorization_payload(value: Any, code: str) -> None:
    required = {"schemaVersion", "command", "requestId", "bindingId", "bindingGeneration",
                "bindingHash", "intent", "expectedRevision"}
    fail(isinstance(value, dict) and set(value) == required and value.get("schemaVersion") == PROOF_REQUEST_VERSION,
         code, "Canonical mutation authorization fields are invalid")
    command = value.get("command")
    fail(command in set(EVENT_COMMANDS.values()), code, "Canonical mutation command is invalid")
    fail(valid_string(value.get("requestId"), 256, pattern=True) and valid_binding_id(value.get("bindingId")),
         code, "Canonical mutation request or binding ID is invalid")
    fail(isinstance(value.get("bindingGeneration"), int) and not isinstance(value["bindingGeneration"], bool)
         and value["bindingGeneration"] >= 1, code, "Canonical mutation binding generation is invalid")
    fail(isinstance(value.get("bindingHash"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", value["bindingHash"]),
         code, "Canonical mutation binding hash is invalid")
    expected_revision = value.get("expectedRevision")
    fail(expected_revision is None or (isinstance(expected_revision, int) and not isinstance(expected_revision, bool)
         and expected_revision >= 1), code, "Canonical mutation CAS revision is invalid")
    fail(command != "init" or expected_revision is None, code, "Initialization cannot carry a CAS revision")
    intent = value.get("intent")
    fail(isinstance(intent, dict), code, "Canonical mutation intent is invalid")
    expected_fields = {
        "init": {"definitionHash"}, "replace-definition": {"definitionHash"},
        "transition": {"nodeId", "targetState", "leaseId", "fence"},
        "gate decide": {"nodeId", "decision"},
        "lease acquire": {"nodeId", "leaseId", "holderScope", "ttlSeconds"},
        "lease renew": {"nodeId", "leaseId", "fence", "ttlSeconds"},
        "lease release": {"nodeId", "leaseId", "fence"},
        "lease sweep": set(), "lease resolve": {"nodeId", "leaseId", "fence", "action", "reason"},
        "replay repair": set(),
    }
    fail(set(intent) == expected_fields[command], code, "Canonical mutation intent fields are invalid")
    if "definitionHash" in intent:
        fail(isinstance(intent["definitionHash"], str) and re.fullmatch(r"sha256:[0-9a-f]{64}", intent["definitionHash"]),
             code, "Canonical definition hash is invalid")
    if "nodeId" in intent:
        fail(valid_string(intent["nodeId"], 128, pattern=True), code, "Canonical mutation node ID is invalid")
    if "leaseId" in intent:
        fail(intent["leaseId"] is None or valid_string(intent["leaseId"], 256, pattern=True),
             code, "Canonical mutation lease ID is invalid")
    if "fence" in intent:
        fail(intent["fence"] is None or (isinstance(intent["fence"], int) and not isinstance(intent["fence"], bool)
             and intent["fence"] >= 1), code, "Canonical mutation fence is invalid")
    if "holderScope" in intent:
        fail(valid_string(intent["holderScope"], 512, pattern=True), code, "Canonical holder scope is invalid")
    if "ttlSeconds" in intent:
        fail(isinstance(intent["ttlSeconds"], int) and not isinstance(intent["ttlSeconds"], bool)
             and 1 <= intent["ttlSeconds"] <= 86400, code, "Canonical lease TTL is invalid")
    if "targetState" in intent:
        fail(intent["targetState"] in set().union(*STATES_BY_FAMILY.values()), code, "Canonical target state is invalid")
    if "decision" in intent:
        fail(intent["decision"] in {"approved", "rejected"}, code, "Canonical gate decision is invalid")
    if "action" in intent:
        fail(intent["action"] in {"retry", "cancel", "complete"}, code, "Canonical resolution action is invalid")
    if "reason" in intent:
        fail(intent["reason"] in {"expired-unsafe", "binding-rotated", "clock-recovery"},
             code, "Canonical resolution reason is invalid")


def validate_event_proof(event: Mapping[str, Any]) -> None:
    proof = event.get("proof")
    fail(isinstance(proof, dict) and set(proof) == {"schemaVersion", "proofKeyId", "algorithm",
         "authorizationSignature", "eventSignature"} and proof.get("schemaVersion") == PROOF_EVENT_VERSION
         and proof.get("proofKeyId") == event["actor"]["proofKey"]["keyId"] and proof.get("algorithm") == "RS256",
         "CORRUPT_JOURNAL", "Event caller proof fields are invalid")
    proof_key = event["actor"]["proofKey"]
    verify_rsa_signature(recorded_authorization_payload(event), proof.get("authorizationSignature"),
                         proof_key["publicKey"]["n"], proof_key["publicKey"]["e"],
                         "CORRUPT_JOURNAL", "Caller authorization proof")
    unsigned = {key: value for key, value in event.items() if key != "proof"}
    verify_rsa_signature(event_proof_payload(unsigned), proof.get("eventSignature"),
                         proof_key["publicKey"]["n"], proof_key["publicKey"]["e"],
                         "CORRUPT_JOURNAL", "Caller event proof")


def require_request_id(args: argparse.Namespace) -> str:
    value = args.request_id
    fail(valid_string(value, 256, pattern=True), "USAGE", "request-id is invalid")
    return value


def fingerprint(command: str, binding: Mapping[str, Any], args: argparse.Namespace, intent: Mapping[str, Any]) -> str:
    payload = authorization_payload(command, binding, args.request_id, intent,
                                    getattr(args, "expected_revision", None))
    validate_authorization_payload(payload, "AUTHORITY_DENIED")
    channel = ProofChannel(getattr(args, "proof_fd", None))
    try:
        signature = channel.sign("authorize", payload, binding["proofKey"])
    except Exception:
        channel.close()
        raise
    fail(isinstance(binding, dict), "AUTHORITY_DENIED", "Actor binding is not mutable authorization state")
    setattr(args, "_proof_channel", channel)
    binding["_proofChannel"] = channel
    binding["_authorizationSignature"] = signature
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


def check_binding_generation(binding: Mapping[str, Any], projection: Mapping[str, Any]) -> None:
    observed = projection["bindingGenerations"].get(binding["bindingId"])
    if observed is None:
        return
    fail(binding["generation"] >= observed["generation"], "AUTHORITY_DENIED", "Actor binding generation has been rotated")
    if binding["generation"] == observed["generation"]:
        fail(binding["bindingHash"] == observed["bindingHash"], "AUTHORITY_DENIED",
             "Actor binding content changed without a generation increment")


def transaction_time(events: Sequence[Mapping[str, Any]]) -> Tuple[dt.datetime, Dict[str, Any]]:
    now = utc_now()
    source, monotonic_ns = host_monotonic_sample()
    clock = {"hostId": HOST_ID, "bootId": BOOT_ID, "monotonicSource": source, "monotonicNs": monotonic_ns}
    if events:
        previous = parse_time(events[-1]["occurredAt"], "CORRUPT_JOURNAL")
        fail(now >= previous, "CLOCK_ROLLBACK", "Trusted transaction time moved behind the journal", {
            "previousEventTime": events[-1]["occurredAt"], "transactionTime": format_time(now)
        })
        previous_clock = events[-1]["clock"]
        if (previous_clock["hostId"] == HOST_ID and previous_clock["bootId"] == BOOT_ID
                and previous_clock["monotonicSource"] == source):
            monotonic_delta = (clock["monotonicNs"] - previous_clock["monotonicNs"]) / 1_000_000_000
            fail(monotonic_delta >= 0, "CLOCK_ROLLBACK", "Trusted monotonic clock moved backwards", {
                "previousMonotonicNs": previous_clock["monotonicNs"], "transactionMonotonicNs": clock["monotonicNs"]})
            fail((now - previous).total_seconds() <= monotonic_delta + MAX_FORWARD_CLOCK_SKEW_SECONDS,
                 "CLOCK_SKEW", "Trusted wall clock exceeded bounded forward skew")
    return now, clock


def make_result(command: str, request_id: str, revision: int, data: Mapping[str, Any]) -> Dict[str, Any]:
    return {"ok": True, "command": command, "requestId": request_id, "revision": revision, "data": dict(data)}


def commit_event(store: Store, events: Sequence[Mapping[str, Any]], event_type: str, data: Mapping[str, Any],
                 binding: Mapping[str, Any], request_id: str, request_fingerprint: str,
                 result_data: Mapping[str, Any], occurred_at: str, clock: Mapping[str, Any],
                 intent: Mapping[str, Any], expected_revision: Optional[int]) -> Dict[str, Any]:
    sequence = len(events) + 1
    occurred = parse_time(occurred_at, "INVALID_STATE")
    fail(parse_time(binding["issuedAt"], "AUTHORITY_DENIED") <= occurred
         < parse_time(binding["expiresAt"], "AUTHORITY_DENIED"),
         "AUTHORITY_DENIED", "Actor binding expired before the transaction committed")
    command = EVENT_COMMANDS[event_type]
    result = make_result(command, request_id, sequence, result_data)
    event = {
        "schemaVersion": EVENT_VERSION,
        "sequence": sequence,
        "eventId": str(uuid.uuid4()),
        "requestId": request_id,
        "requestFingerprint": request_fingerprint,
        "occurredAt": occurred_at,
        "clock": dict(clock),
        "actor": actor_record(binding),
        "type": event_type,
        "intent": dict(intent),
        "expectedRevision": expected_revision,
        "data": dict(data),
        "result": result,
    }
    channel = binding.get("_proofChannel")
    fail(isinstance(channel, ProofChannel), "AUTHORITY_DENIED", "Caller proof channel is missing at commit")
    try:
        event_signature = channel.sign("event", event_proof_payload(event), binding["proofKey"])
    finally:
        channel.close()
    event["proof"] = {
        "schemaVersion": PROOF_EVENT_VERSION,
        "proofKeyId": binding["proofKey"]["keyId"],
        "algorithm": "RS256",
        "authorizationSignature": binding["_authorizationSignature"],
        "eventSignature": event_signature,
    }
    encoded = canonical_bytes(event)
    fail(len(encoded) <= MAX_EVENT_BYTES, "INVALID_STATE", "Event exceeds maximum journal record size")
    store.assert_lock()
    try:
        committed_size = store.events_path.stat().st_size
    except FileNotFoundError:
        committed_size = 0
    except OSError as exc:
        raise GraphError("IO_ERROR", "Cannot preflight event journal size", str(exc)) from exc
    fail(committed_size + len(encoded) <= MAX_JOURNAL_BYTES, "JOURNAL_FULL",
         "Event journal is full; offline checkpoint/rotation is required")
    replayed_definition, replayed_projection = replay([*events, event], store.load_authority())
    store.assert_lock()
    append_bytes(store.events_path, encoded)
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
        if node_id in projection["executionStarted"] or state != old_node["initialState"] or state in TERMINAL_STATES[family_for(old_node["kind"])]:
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
    fail(definition["graphId"] == binding["graphId"], "AUTHORITY_DENIED", "Initialization definition does not match authority graph")
    intent = {"definitionHash": definition_hash(definition)}
    request_fingerprint = fingerprint("init", binding, args, intent)
    with store.lock():
        if store.has_state():
            current_definition, projection, events = store.load()
            check_binding_generation(binding, projection)
            duplicate = duplicate_result(events, request_id, request_fingerprint)
            if duplicate is not None:
                return duplicate
            return {"ok": True, "command": "init", "requestId": request_id, "revision": projection["revision"],
                    "data": {"initialized": False, "alreadyInitialized": True, "graphId": current_definition["graphId"]}}
        events: List[Dict[str, Any]] = []
        now, clock = transaction_time(events)
        result_data = {"initialized": True, "alreadyInitialized": False, "graphId": definition["graphId"]}
        return commit_event(store, events, "graph.initialized", {"definition": definition}, binding, request_id,
                            request_fingerprint, result_data, format_time(now), clock, intent, None)


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
        "schemaVersion": SNAPSHOT_VERSION,
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
        "executionStarted": projection["executionStarted"],
        "reconciliations": projection["reconciliations"],
        "bindingGenerations": projection["bindingGenerations"],
        "authorityKeyId": projection["authorityKeyId"],
        "authorityHash": projection["authorityHash"],
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
        check_binding_generation(binding, projection)
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        fail(replacement["graphId"] == definition["graphId"], "INVALID_GRAPH", "replace-definition cannot change graphId")
        replacement["definitionRevision"] = definition["definitionRevision"] + 1
        replacement = validate_definition(replacement, materialized=True)
        immutable_replacement_checks(definition, projection, replacement)
        now, clock = transaction_time(events)
        result_data = {"graphId": replacement["graphId"], "definitionRevision": replacement["definitionRevision"],
                       "nodes": len(replacement["nodes"]), "edges": len(replacement["edges"])}
        return commit_event(store, events, "definition.replaced", {"definition": replacement}, binding, request_id,
                            request_fingerprint, result_data, format_time(now), clock, intent, args.expected_revision)


def require_current_lease(projection: Mapping[str, Any], node_id: str, binding: Mapping[str, Any],
                          lease_id: Optional[str], fence: Optional[int], clock: Mapping[str, Any]) -> None:
    lease = projection["leases"].get(node_id)
    if lease is None:
        if lease_id is not None or fence is not None:
            raise GraphError("FENCE_STALE", f"No current lease exists for node: {node_id}")
        fail(binding["subject"]["type"] in {"operator", "system"}, "LEASE_REQUIRED", f"Actor requires a valid lease to transition node: {node_id}")
        return
    if lease_id != lease["leaseId"] or fence != lease["fence"]:
        code = "FENCE_STALE" if fence is not None and fence <= lease["fence"] else "LEASE_CONFLICT"
        raise GraphError(code, f"Lease credentials do not match current owner for node: {node_id}", {"currentFence": lease["fence"]})
    fail(not lease_clock_expired(lease, clock, "RECONCILIATION_REQUIRED"), "LEASE_EXPIRED", f"Lease has expired for node: {node_id}")
    fail(lease["holder"]["bindingId"] == binding["bindingId"]
         and lease["holder"]["bindingGeneration"] == binding["generation"]
         and lease["holder"]["bindingHash"] == binding["bindingHash"], "AUTHORITY_DENIED",
         f"Actor binding generation does not hold lease for node: {node_id}")


def command_transition(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "transition")
    intent = {"nodeId": args.node_id, "targetState": args.state, "leaseId": args.lease_id, "fence": args.fence}
    request_fingerprint = fingerprint("transition", binding, args, intent)
    with store.lock():
        definition, projection, events = store.load()
        check_binding_generation(binding, projection)
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
        now, clock = transaction_time(events)
        require_current_lease(projection, args.node_id, binding, args.lease_id, args.fence, clock)
        transition_preconditions(definition, projection, args.node_id, args.state)
        data = {"nodeId": args.node_id, "from": current, "to": args.state}
        return commit_event(store, events, "node.transitioned", data, binding, request_id, request_fingerprint,
                            data, format_time(now), clock, intent, args.expected_revision)


def command_gate_decide(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "gate-decision")
    fail(binding["subject"]["type"] == "human", "AUTHORITY_DENIED", "Only a human binding may decide a human gate")
    intent = {"nodeId": args.node_id, "decision": args.decision}
    request_fingerprint = fingerprint("gate decide", binding, args, intent)
    with store.lock():
        definition, projection, events = store.load()
        check_binding_generation(binding, projection)
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        node = find_node(definition, args.node_id)
        fail(node["kind"] == "human-gate", "INVALID_GRAPH", f"Node is not a human gate: {args.node_id}")
        current = projection["nodeStates"][args.node_id]
        fail(args.decision in TRANSITIONS["gate"][current], "INVALID_TRANSITION", f"Gate decision is not allowed: {current} -> {args.decision}")
        now, clock = transaction_time(events)
        data = {"nodeId": args.node_id, "from": current, "to": args.decision}
        return commit_event(store, events, "gate.decided", data, binding, request_id, request_fingerprint,
                            data, format_time(now), clock, intent, args.expected_revision)


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
        check_binding_generation(binding, projection)
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        node = find_node(definition, args.node_id)
        fail(node["kind"] in WORK_KINDS, "AUTHORITY_DENIED", "Only work nodes may be leased")
        fail(projection["nodeStates"][args.node_id] not in TERMINAL_STATES["work"], "INVALID_STATE", "Terminal work cannot be leased")
        fail(args.node_id not in projection["reconciliations"], "RECONCILIATION_REQUIRED",
             f"Node requires explicit lease resolution before reassignment: {args.node_id}")
        assigned = any(edge["kind"] == "assigned-to" and edge["from"] == args.node_id and edge["to"] == scope["laneNodeId"] for edge in definition["edges"])
        fail(assigned, "AUTHORITY_DENIED", "Lease acquisition does not match assigned-to", {"nodeId": args.node_id, "laneNodeId": scope["laneNodeId"]})
        now, clock = transaction_time(events)
        current = projection["leases"].get(args.node_id)
        if current is not None and not lease_clock_expired(current, clock, "RECONCILIATION_REQUIRED"):
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
                       "bindingId": binding["bindingId"], "bindingGeneration": binding["generation"],
                       "bindingHash": binding["bindingHash"], "scope": scope["scope"], "laneNodeId": scope["laneNodeId"]},
            "acquiredAt": timestamp,
            "renewedAt": timestamp,
            "expiresAt": format_time(now + dt.timedelta(seconds=args.ttl_seconds)),
            "fence": fence,
            "clock": {"hostId": clock["hostId"], "bootId": clock["bootId"],
                      "monotonicSource": clock["monotonicSource"],
                      "acquiredMonotonicNs": clock["monotonicNs"],
                      "expiresMonotonicNs": clock["monotonicNs"] + args.ttl_seconds * 1_000_000_000},
        }
        validate_lease(lease)
        result_data = {"lease": lease, "reclaimed": current is not None}
        return commit_event(store, events, "lease.acquired", {"lease": lease}, binding, request_id,
                            request_fingerprint, result_data, timestamp, clock, intent, args.expected_revision)


def check_lease_operation(projection: Mapping[str, Any], args: argparse.Namespace, binding: Mapping[str, Any], clock: Mapping[str, Any]) -> Dict[str, Any]:
    lease = projection["leases"].get(args.node_id)
    fail(lease is not None, "FENCE_STALE", f"No current lease exists for node: {args.node_id}")
    fail(args.lease_id == lease["leaseId"] and args.fence == lease["fence"], "FENCE_STALE", f"Lease credentials are stale for node: {args.node_id}", {"currentFence": lease["fence"]})
    fail(lease["holder"]["bindingId"] == binding["bindingId"]
         and lease["holder"]["bindingGeneration"] == binding["generation"]
         and lease["holder"]["bindingHash"] == binding["bindingHash"], "RECONCILIATION_REQUIRED",
         f"Lease holder binding was rotated for node: {args.node_id}")
    fail(not lease_clock_expired(lease, clock, "RECONCILIATION_REQUIRED"), "LEASE_EXPIRED", f"Lease has expired for node: {args.node_id}")
    return lease


def command_lease_renew(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "lease")
    validate_ttl(args.ttl_seconds)
    intent = {"nodeId": args.node_id, "leaseId": args.lease_id, "fence": args.fence, "ttlSeconds": args.ttl_seconds}
    request_fingerprint = fingerprint("lease renew", binding, args, intent)
    with store.lock():
        definition, projection, events = store.load()
        check_binding_generation(binding, projection)
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        now, clock = transaction_time(events)
        lease = dict(check_lease_operation(projection, args, binding, clock))
        lease["renewedAt"] = format_time(now)
        lease["expiresAt"] = format_time(now + dt.timedelta(seconds=args.ttl_seconds))
        lease["clock"] = dict(lease["clock"])
        lease["clock"]["expiresMonotonicNs"] = clock["monotonicNs"] + args.ttl_seconds * 1_000_000_000
        return commit_event(store, events, "lease.renewed", {"lease": lease}, binding, request_id,
                            request_fingerprint, {"lease": lease}, format_time(now), clock, intent, args.expected_revision)


def command_lease_release(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "lease")
    intent = {"nodeId": args.node_id, "leaseId": args.lease_id, "fence": args.fence}
    request_fingerprint = fingerprint("lease release", binding, args, intent)
    with store.lock():
        definition, projection, events = store.load()
        check_binding_generation(binding, projection)
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        now, clock = transaction_time(events)
        lease = check_lease_operation(projection, args, binding, clock)
        data = {"nodeId": args.node_id, "leaseId": lease["leaseId"], "fence": lease["fence"]}
        return commit_event(store, events, "lease.released", data, binding, request_id,
                            request_fingerprint, data, format_time(now), clock, intent, args.expected_revision)


def command_lease_sweep(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "sweep")
    fail(binding["subject"]["type"] in {"operator", "system", "host"}, "AUTHORITY_DENIED", "Only operator, system, or host bindings may sweep leases")
    intent: Dict[str, Any] = {}
    request_fingerprint = fingerprint("lease sweep", binding, args, intent)
    with store.lock():
        definition, projection, events = store.load()
        check_binding_generation(binding, projection)
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        now, clock = transaction_time(events)
        expired = []
        for node_id, lease in sorted(projection["leases"].items()):
            if lease_clock_expired(lease, clock, "RECONCILIATION_REQUIRED"):
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
                            {"expired": expired, "count": len(expired)}, format_time(now), clock, intent, args.expected_revision)


def command_lease_resolve(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    binding = load_binding(store, args, "lease-resolve")
    fail(binding["subject"]["type"] in {"operator", "system", "human"}, "AUTHORITY_DENIED",
         "Only operator, system, or human bindings may resolve lease reconciliation")
    intent = {"nodeId": args.node_id, "leaseId": args.lease_id, "fence": args.fence,
              "action": args.action, "reason": args.reason}
    request_fingerprint = fingerprint("lease resolve", binding, args, intent)
    with store.lock():
        definition, projection, events = store.load()
        check_binding_generation(binding, projection)
        duplicate = duplicate_result(events, request_id, request_fingerprint)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        node = find_node(definition, args.node_id)
        fail(node["kind"] in WORK_KINDS, "INVALID_GRAPH", "Only work nodes have lease reconciliation")
        current_lease = projection["leases"].get(args.node_id)
        record = projection["reconciliations"].get(args.node_id)
        now, clock = transaction_time(events)
        evidence: Dict[str, Any]
        if record is None:
            fail(current_lease is not None and args.reason in {"binding-rotated", "clock-recovery"},
                 "RECONCILIATION_REQUIRED", "Node has no reconciliation requiring resolution")
            if args.reason == "binding-rotated":
                holder = current_lease["holder"]
                replacement_binding = load_binding_by_id(store, holder["bindingId"])
                fail(replacement_binding["generation"] > holder["bindingGeneration"]
                     and replacement_binding["bindingHash"] != holder["bindingHash"],
                     "RECONCILIATION_REQUIRED", "Lease holder binding has not actually rotated")
                fail(parse_time(replacement_binding["issuedAt"], "AUTHORITY_DENIED") <= now,
                     "RECONCILIATION_REQUIRED", "Replacement binding is future-dated and not yet rotation evidence")
                evidence = {"kind": "binding-rotation", "currentBinding": {
                    **binding_payload(replacement_binding), "signature": replacement_binding["signature"],
                }}
            else:
                lease_clock = current_lease["clock"]
                fail(lease_clock["hostId"] != clock["hostId"] or lease_clock["bootId"] != clock["bootId"]
                     or lease_clock["monotonicSource"] != clock["monotonicSource"],
                     "RECONCILIATION_REQUIRED", "Lease clock has no discontinuity requiring recovery")
                evidence = {"kind": "clock-discontinuity", "leaseClock": dict(lease_clock), "eventClock": dict(clock)}
            record = {"leaseId": current_lease["leaseId"], "fence": current_lease["fence"]}
        else:
            fail(args.reason == record["reason"], "RECONCILIATION_REQUIRED", "Resolution reason does not match persisted reconciliation")
            evidence = {"kind": "persisted-reconciliation", "requiredAt": record["requiredAt"]}
        fail(args.lease_id == record["leaseId"] and args.fence == record["fence"], "FENCE_STALE",
             "Resolution lease credentials are stale")
        current = projection["nodeStates"][args.node_id]
        fail(current not in TERMINAL_STATES["work"], "INVALID_STATE", "Terminal work does not require lease resolution")
        target = ("blocked" if current == "active" else current) if args.action == "retry" else (
            "cancelled" if args.action == "cancel" else "completed")
        if args.action == "complete":
            transition_preconditions(definition, projection, args.node_id, "completed")
        data = {"nodeId": args.node_id, "leaseId": args.lease_id, "fence": args.fence,
                "action": args.action, "fromState": current, "toState": target, "reason": args.reason,
                "evidence": evidence}
        return commit_event(store, events, "lease.resolved", data, binding, request_id, request_fingerprint,
                            data, format_time(now), clock, intent, args.expected_revision)


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
            definition, projection = replay(events, store.load_authority())
            store.write_materialized(definition, projection)
            return duplicate
        definition, projection = replay(events, store.load_authority())
        check_binding_generation(binding, projection)
        check_cas(projection, args.expected_revision)
        now, clock = transaction_time(events)
        repaired_revision = projection["revision"]
        return commit_event(store, events, "replay.repaired", {"repairedRevision": repaired_revision}, binding,
                            request_id, request_fingerprint, {"repairedRevision": repaired_revision},
                            format_time(now), clock, intent, args.expected_revision)


def add_mutation_options(parser: argparse.ArgumentParser, cas: bool = True) -> None:
    parser.add_argument("--request-id", required=True)
    if cas:
        parser.add_argument("--expected-revision", type=int)
    parser.add_argument("--actor-binding")
    parser.add_argument("--proof-fd", type=int, help="inherited full-duplex caller proof broker socket")


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
    resolve = lease_sub.add_parser("resolve")
    resolve.add_argument("node_id")
    resolve.add_argument("action", choices=["retry", "cancel", "complete"])
    resolve.add_argument("--lease-id", required=True)
    resolve.add_argument("--fence", type=int, required=True)
    resolve.add_argument("--reason", required=True, choices=["expired-unsafe", "binding-rotated", "clock-recovery"])
    add_mutation_options(resolve)
    resolve.set_defaults(handler=command_lease_resolve)

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
    args: Optional[argparse.Namespace] = None
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
    finally:
        channel = getattr(args, "_proof_channel", None) if args is not None else None
        if isinstance(channel, ProofChannel):
            channel.close()


if __name__ == "__main__":
    raise SystemExit(main())
