#!/usr/bin/env python3
"""Operator V5 typed control graph runtime.

The event journal is the durable transaction record. definition.json and
projection.json are deterministic, atomically replaced materializations.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import json
import os
import shutil
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Mapping, Optional, Sequence, Set, Tuple


GRAPH_VERSION = "operator.control-graph/v1"
EVENT_VERSION = "operator.control-event/v1"
PROJECTION_VERSION = "operator.control-projection/v1"
LEASE_VERSION = "operator.ownership-lease/v1"

ACTOR_TYPES = {"operator", "lane", "host", "human", "subagent", "system"}
NODE_KINDS = {
    "goal", "feature", "lane", "task", "validation", "human-gate",
    "integration", "feedback",
}
EDGE_KINDS = {
    "contains", "depends-on", "assigned-to", "validated-by", "gated-by",
    "integrates-into", "feedback-for",
}
CONTAINER_KINDS = {"goal", "feature", "lane"}
WORK_KINDS = {"task", "validation", "integration", "feedback"}
GATE_KINDS = {"human-gate"}

STATES_BY_FAMILY = {
    "container": {"planned", "active", "blocked", "completed", "cancelled"},
    "work": {"pending", "ready", "active", "blocked", "completed", "failed", "cancelled"},
    "gate": {"pending", "approved", "rejected", "cancelled"},
}
INITIAL_STATES = {"container": "planned", "work": "pending", "gate": "pending"}
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
    "assigned-to": ({"task", "validation", "integration", "feedback"}, {"lane"}),
    "validated-by": ({"task", "integration"}, {"validation"}),
    "gated-by": ({"goal", "feature", "task", "integration"}, {"human-gate"}),
    "integrates-into": ({"integration"}, {"feature"}),
    "feedback-for": ({"feedback"}, NODE_KINDS - {"feedback"}),
}

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


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def parse_time(value: Optional[str]) -> dt.datetime:
    if value is None:
        return utc_now()
    raw = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = dt.datetime.fromisoformat(raw)
    except ValueError as exc:
        raise GraphError("USAGE", f"Invalid RFC 3339 timestamp: {value}") from exc
    fail(parsed.tzinfo is not None, "USAGE", "Timestamp must include a timezone")
    return parsed.astimezone(dt.timezone.utc)


def format_time(value: dt.datetime) -> str:
    value = value.astimezone(dt.timezone.utc)
    return value.isoformat(timespec="microseconds").replace("+00:00", "Z")


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def semantic_equal(left: Any, right: Any) -> bool:
    return canonical_bytes(left) == canonical_bytes(right)


def require_keys(value: Mapping[str, Any], required: Set[str], optional: Set[str], label: str) -> None:
    missing = required - set(value)
    extra = set(value) - required - optional
    fail(not missing, "INVALID_GRAPH", f"{label} is missing required fields", sorted(missing))
    fail(not extra, "INVALID_GRAPH", f"{label} has unknown fields", sorted(extra))


def family_for(kind: str) -> str:
    if kind in CONTAINER_KINDS:
        return "container"
    if kind in WORK_KINDS:
        return "work"
    return "gate"


def load_json(path: Path, missing_code: str = "NOT_INITIALIZED") -> Dict[str, Any]:
    if not path.is_file():
        raise GraphError(missing_code, f"Missing state file: {path}")
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise GraphError("IO_ERROR", f"Cannot read JSON file: {path}", str(exc)) from exc
    fail(isinstance(value, dict), "INVALID_STATE", f"Expected a JSON object: {path}")
    return value


def load_input_definition(path: Path) -> Dict[str, Any]:
    value = load_json(path, "INVALID_GRAPH")
    return validate_definition(value, materialized=False)


def validate_version(value: Any, expected: str, label: str) -> None:
    fail(isinstance(value, str), "UNKNOWN_VERSION", f"{label} schemaVersion is required")
    fail(value == expected, "UNKNOWN_VERSION", f"Unsupported {label} schemaVersion: {value}", {"expected": expected})


def validate_definition(value: Mapping[str, Any], materialized: bool = True) -> Dict[str, Any]:
    fail(isinstance(value, dict), "INVALID_GRAPH", "Graph definition must be an object")
    require_keys(value, {"schemaVersion", "graphId", "nodes", "edges"}, {"definitionRevision"}, "graph definition")
    validate_version(value.get("schemaVersion"), GRAPH_VERSION, "graph")
    graph_id = value.get("graphId")
    fail(isinstance(graph_id, str) and graph_id.strip() and len(graph_id) <= 128, "INVALID_GRAPH", "graphId must be a nonempty string of at most 128 characters")
    if "definitionRevision" in value:
        fail(isinstance(value["definitionRevision"], int) and not isinstance(value["definitionRevision"], bool) and value["definitionRevision"] >= 1,
             "INVALID_GRAPH", "definitionRevision must be a positive integer")
    elif materialized:
        raise GraphError("INVALID_GRAPH", "Materialized definition is missing definitionRevision")
    nodes = value.get("nodes")
    edges = value.get("edges")
    fail(isinstance(nodes, list), "INVALID_GRAPH", "nodes must be an array")
    fail(isinstance(edges, list), "INVALID_GRAPH", "edges must be an array")

    normalized_nodes: List[Dict[str, Any]] = []
    node_by_id: Dict[str, Dict[str, Any]] = {}
    for index, raw in enumerate(nodes):
        fail(isinstance(raw, dict), "INVALID_GRAPH", f"nodes[{index}] must be an object")
        require_keys(raw, {"id", "kind"}, {"title", "initialState", "priority", "metadata"}, f"nodes[{index}]")
        node_id = raw.get("id")
        kind = raw.get("kind")
        fail(isinstance(node_id, str) and node_id.strip() and len(node_id) <= 128, "INVALID_GRAPH", f"nodes[{index}].id is invalid")
        fail(node_id not in node_by_id, "INVALID_GRAPH", f"Duplicate node id: {node_id}")
        fail(kind in NODE_KINDS, "INVALID_GRAPH", f"Unknown node kind: {kind}")
        family = family_for(kind)
        state = raw.get("initialState", INITIAL_STATES[family])
        fail(state in STATES_BY_FAMILY[family], "INVALID_GRAPH", f"Invalid initialState for {kind}: {state}")
        priority = raw.get("priority", 0)
        fail(isinstance(priority, int) and not isinstance(priority, bool) and 0 <= priority <= 1000,
             "INVALID_GRAPH", f"Invalid priority for node {node_id}")
        title = raw.get("title", node_id)
        fail(isinstance(title, str) and title.strip() and len(title) <= 512, "INVALID_GRAPH", f"Invalid title for node {node_id}")
        metadata = raw.get("metadata", {})
        fail(isinstance(metadata, dict), "INVALID_GRAPH", f"metadata for node {node_id} must be an object")
        normalized = {
            "id": node_id,
            "kind": kind,
            "title": title,
            "initialState": state,
            "priority": priority,
            "metadata": metadata,
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
        fail(isinstance(edge_id, str) and edge_id.strip() and len(edge_id) <= 384, "INVALID_GRAPH", f"Invalid edge id at index {index}")
        fail(edge_id not in edge_ids, "INVALID_GRAPH", f"Duplicate edge id: {edge_id}")
        edge_ids.add(edge_id)
        metadata = raw.get("metadata", {})
        fail(isinstance(metadata, dict), "INVALID_GRAPH", f"metadata for edge {edge_id} must be an object")
        normalized_edges.append({"id": edge_id, "kind": kind, "from": source, "to": target, "metadata": metadata})

    adjacency: Dict[str, List[str]] = {node_id: [] for node_id in node_by_id}
    for edge in normalized_edges:
        if edge["kind"] in {"contains", "depends-on"}:
            adjacency[edge["from"]].append(edge["to"])
    visiting: Set[str] = set()
    visited: Set[str] = set()

    def visit(node_id: str, path: List[str]) -> None:
        if node_id in visiting:
            start = path.index(node_id)
            raise GraphError("INVALID_GRAPH", "contains/depends-on edges must be acyclic", path[start:] + [node_id])
        if node_id in visited:
            return
        visiting.add(node_id)
        path.append(node_id)
        for target_id in sorted(adjacency[node_id]):
            visit(target_id, path)
        path.pop()
        visiting.remove(node_id)
        visited.add(node_id)

    for node_id in sorted(node_by_id):
        visit(node_id, [])

    result: Dict[str, Any] = {
        "schemaVersion": GRAPH_VERSION,
        "graphId": graph_id,
        "nodes": sorted(normalized_nodes, key=lambda item: item["id"]),
        "edges": sorted(normalized_edges, key=lambda item: item["id"]),
    }
    if "definitionRevision" in value:
        result["definitionRevision"] = value["definitionRevision"]
    return result


def definition_hash(definition: Mapping[str, Any]) -> str:
    return "sha256:" + hashlib.sha256(canonical_bytes(definition)).hexdigest()


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


def validate_lease(value: Mapping[str, Any]) -> None:
    fail(isinstance(value, dict), "INVALID_STATE", "Lease must be an object")
    required = {"schemaVersion", "nodeId", "leaseId", "holder", "acquiredAt", "renewedAt", "expiresAt", "fence"}
    fail(set(value) == required, "INVALID_STATE", "Lease fields are invalid", {"required": sorted(required), "actual": sorted(value)})
    validate_version(value.get("schemaVersion"), LEASE_VERSION, "lease")
    fail(isinstance(value.get("nodeId"), str) and value["nodeId"], "INVALID_STATE", "Lease nodeId is invalid")
    fail(isinstance(value.get("leaseId"), str) and value["leaseId"], "INVALID_STATE", "Lease leaseId is invalid")
    holder = value.get("holder")
    fail(isinstance(holder, dict) and set(holder) == {"actorType", "actorId", "scope"}, "INVALID_STATE", "Lease holder is invalid")
    fail(holder.get("actorType") in ACTOR_TYPES, "INVALID_STATE", "Lease holder actorType is invalid")
    fail(isinstance(holder.get("actorId"), str) and holder["actorId"], "INVALID_STATE", "Lease holder actorId is invalid")
    fail(isinstance(holder.get("scope"), str) and holder["scope"], "INVALID_STATE", "Lease holder scope is invalid")
    for field in ("acquiredAt", "renewedAt", "expiresAt"):
        parse_time(value.get(field))
    fail(isinstance(value.get("fence"), int) and not isinstance(value["fence"], bool) and value["fence"] >= 1,
         "INVALID_STATE", "Lease fence is invalid")


def validate_projection(value: Mapping[str, Any], definition: Mapping[str, Any]) -> None:
    required = {"schemaVersion", "graphId", "revision", "definitionRevision", "definitionHash", "updatedAt", "nodeStates", "leases", "leaseFences"}
    fail(isinstance(value, dict) and set(value) == required, "INVALID_STATE", "Projection fields are invalid")
    validate_version(value.get("schemaVersion"), PROJECTION_VERSION, "projection")
    fail(value.get("graphId") == definition["graphId"], "INVALID_STATE", "Projection graphId does not match definition")
    fail(value.get("definitionRevision") == definition["definitionRevision"], "INVALID_STATE", "Projection definitionRevision does not match definition")
    fail(value.get("definitionHash") == definition_hash(definition), "INVALID_STATE", "Projection definitionHash does not match definition")
    fail(isinstance(value.get("revision"), int) and not isinstance(value["revision"], bool) and value["revision"] >= 1,
         "INVALID_STATE", "Projection revision is invalid")
    parse_time(value.get("updatedAt"))
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
        fail(node_id in node_map and isinstance(fence, int) and not isinstance(fence, bool) and fence >= 1,
             "INVALID_STATE", f"Invalid lease fence for node: {node_id}")
        if node_id in leases:
            fail(fence == leases[node_id]["fence"], "INVALID_STATE", f"Lease fence mismatch for node: {node_id}")


def read_events(path: Path) -> List[Dict[str, Any]]:
    if not path.is_file():
        raise GraphError("NOT_INITIALIZED", f"Missing event journal: {path}")
    events: List[Dict[str, Any]] = []
    seen_requests: Set[str] = set()
    try:
        with path.open(encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, 1):
                if not line.endswith("\n"):
                    raise GraphError("CORRUPT_JOURNAL", "Journal ends with an incomplete record", {"line": line_number})
                try:
                    event = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise GraphError("CORRUPT_JOURNAL", "Journal contains invalid JSON", {"line": line_number, "error": str(exc)}) from exc
                validate_event(event, line_number, seen_requests)
                events.append(event)
    except OSError as exc:
        raise GraphError("IO_ERROR", f"Cannot read event journal: {path}", str(exc)) from exc
    fail(bool(events), "CORRUPT_JOURNAL", "Event journal is empty")
    return events


def validate_event(event: Any, sequence: int, seen_requests: Set[str]) -> None:
    required = {"schemaVersion", "sequence", "eventId", "requestId", "occurredAt", "actor", "type", "data", "result"}
    fail(isinstance(event, dict) and set(event) == required, "CORRUPT_JOURNAL", "Event fields are invalid", {"line": sequence})
    validate_version(event.get("schemaVersion"), EVENT_VERSION, "event")
    fail(event.get("sequence") == sequence, "CORRUPT_JOURNAL", "Event sequence is not strict", {"expected": sequence, "actual": event.get("sequence")})
    fail(isinstance(event.get("eventId"), str) and event["eventId"], "CORRUPT_JOURNAL", "Event eventId is invalid")
    request_id = event.get("requestId")
    fail(isinstance(request_id, str) and request_id, "CORRUPT_JOURNAL", "Event requestId is invalid")
    fail(request_id not in seen_requests, "CORRUPT_JOURNAL", f"Duplicate requestId in journal: {request_id}")
    seen_requests.add(request_id)
    parse_time(event.get("occurredAt"))
    actor = event.get("actor")
    fail(isinstance(actor, dict) and set(actor) == {"type", "id"} and actor.get("type") in ACTOR_TYPES and isinstance(actor.get("id"), str) and actor["id"],
         "CORRUPT_JOURNAL", "Event actor is invalid")
    fail(event.get("type") in {"graph.initialized", "definition.replaced", "node.transitioned", "gate.decided", "lease.acquired", "lease.renewed", "lease.released", "lease.swept", "replay.repaired"},
         "CORRUPT_JOURNAL", f"Unknown event type: {event.get('type')}")
    fail(isinstance(event.get("data"), dict), "CORRUPT_JOURNAL", "Event data must be an object")
    result = event.get("result")
    fail(isinstance(result, dict) and result.get("ok") is True and result.get("requestId") == request_id and result.get("revision") == sequence,
         "CORRUPT_JOURNAL", "Event result is invalid")


def replay(events: Sequence[Mapping[str, Any]]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    definition: Optional[Dict[str, Any]] = None
    projection: Optional[Dict[str, Any]] = None
    for event in events:
        event_type = event["type"]
        data = event["data"]
        sequence = event["sequence"]
        occurred_at = event["occurredAt"]
        if sequence == 1:
            fail(event_type == "graph.initialized", "CORRUPT_JOURNAL", "First event must be graph.initialized")
        if event_type == "graph.initialized":
            fail(sequence == 1 and definition is None, "CORRUPT_JOURNAL", "graph.initialized may appear only once as event 1")
            fail(set(data) == {"definition"}, "CORRUPT_JOURNAL", "graph.initialized data is invalid")
            definition = validate_definition(data["definition"], materialized=True)
            projection = blank_projection(definition, occurred_at, sequence)
        else:
            fail(definition is not None and projection is not None, "CORRUPT_JOURNAL", "Event appears before initialization")
            if event_type == "definition.replaced":
                fail(set(data) == {"definition"}, "CORRUPT_JOURNAL", "definition.replaced data is invalid")
                fail(event["actor"]["type"] != "subagent", "CORRUPT_JOURNAL", "Subagent replaced a definition")
                replacement = validate_definition(data["definition"], materialized=True)
                fail(replacement["graphId"] == definition["graphId"], "CORRUPT_JOURNAL", "Replacement changed graphId")
                fail(replacement["definitionRevision"] == definition["definitionRevision"] + 1,
                     "CORRUPT_JOURNAL", "Replacement definitionRevision is not monotonic")
                old_nodes = {node["id"]: node for node in definition["nodes"]}
                replacement_nodes = {node["id"]: node for node in replacement["nodes"]}
                for node_id in projection["leases"]:
                    fail(node_id in replacement_nodes and replacement_nodes[node_id]["kind"] == old_nodes[node_id]["kind"],
                         "CORRUPT_JOURNAL", f"Replacement removed or changed a leased node: {node_id}")
                new_states: Dict[str, str] = {}
                for node in replacement["nodes"]:
                    old = old_nodes.get(node["id"])
                    if old is not None and old["kind"] == node["kind"]:
                        new_states[node["id"]] = projection["nodeStates"][node["id"]]
                    else:
                        new_states[node["id"]] = node["initialState"]
                new_ids = set(new_states)
                projection["nodeStates"] = new_states
                projection["leases"] = {key: value for key, value in projection["leases"].items() if key in new_ids}
                projection["leaseFences"] = {key: value for key, value in projection["leaseFences"].items() if key in new_ids}
                definition = replacement
                projection["graphId"] = definition["graphId"]
                projection["definitionRevision"] = definition["definitionRevision"]
                projection["definitionHash"] = definition_hash(definition)
            elif event_type in {"node.transitioned", "gate.decided"}:
                fail(set(data) == {"nodeId", "from", "to"}, "CORRUPT_JOURNAL", f"{event_type} data is invalid")
                node_id = data["nodeId"]
                fail(node_id in projection["nodeStates"], "CORRUPT_JOURNAL", f"Transition references unknown node: {node_id}")
                fail(projection["nodeStates"][node_id] == data["from"], "CORRUPT_JOURNAL", f"Transition source state mismatch for {node_id}")
                node = next(item for item in definition["nodes"] if item["id"] == node_id)
                family = family_for(node["kind"])
                fail(data["to"] in TRANSITIONS[family][data["from"]], "CORRUPT_JOURNAL", f"Impossible transition in journal for {node_id}")
                if event_type == "gate.decided":
                    fail(family == "gate" and event["actor"]["type"] == "human" and data["to"] in {"approved", "rejected"},
                         "CORRUPT_JOURNAL", f"Invalid human gate decision for {node_id}")
                else:
                    fail(family != "gate", "CORRUPT_JOURNAL", f"Human gate used generic transition: {node_id}")
                    fail(not (event["actor"]["type"] == "subagent" and node["kind"] == "integration"),
                         "CORRUPT_JOURNAL", "Subagent integrated a node")
                    current_lease = projection["leases"].get(node_id)
                    if current_lease is None:
                        fail(event["actor"]["type"] in {"operator", "system", "human"},
                             "CORRUPT_JOURNAL", f"Unleased transition used an unauthorized actor: {node_id}")
                    else:
                        fail(parse_time(current_lease["expiresAt"]) > parse_time(occurred_at),
                             "CORRUPT_JOURNAL", f"Expired lease transitioned node: {node_id}")
                        fail(current_lease["holder"]["actorType"] == event["actor"]["type"] and current_lease["holder"]["actorId"] == event["actor"]["id"],
                             "CORRUPT_JOURNAL", f"Transition actor does not hold lease: {node_id}")
                projection["nodeStates"][node_id] = data["to"]
            elif event_type == "lease.acquired":
                fail(set(data) == {"lease"}, "CORRUPT_JOURNAL", f"{event_type} data is invalid")
                lease = data["lease"]
                validate_lease(lease)
                node_id = lease["nodeId"]
                fail(node_id in projection["nodeStates"], "CORRUPT_JOURNAL", f"Lease references unknown node: {node_id}")
                node = next(item for item in definition["nodes"] if item["id"] == node_id)
                fail(node["kind"] != "human-gate", "CORRUPT_JOURNAL", "Human gate was leased")
                fail(event["actor"]["type"] != "subagent", "CORRUPT_JOURNAL", "Subagent acquired a lease")
                fail(lease["holder"]["actorType"] == event["actor"]["type"] and lease["holder"]["actorId"] == event["actor"]["id"],
                     "CORRUPT_JOURNAL", "Lease holder does not match acquire actor")
                current = projection["leases"].get(node_id)
                fail(current is None or parse_time(current["expiresAt"]) <= parse_time(occurred_at),
                     "CORRUPT_JOURNAL", f"Lease acquired while another lease was unexpired: {node_id}")
                fail(lease["fence"] == projection["leaseFences"].get(node_id, 0) + 1,
                     "CORRUPT_JOURNAL", f"Lease fence is not monotonic for node: {node_id}")
                fail(lease["acquiredAt"] == occurred_at and lease["renewedAt"] == occurred_at and parse_time(lease["expiresAt"]) > parse_time(occurred_at),
                     "CORRUPT_JOURNAL", f"Lease acquisition timestamps are invalid for node: {node_id}")
                projection["leases"][node_id] = lease
                projection["leaseFences"][node_id] = lease["fence"]
            elif event_type == "lease.renewed":
                fail(set(data) == {"lease"}, "CORRUPT_JOURNAL", "lease.renewed data is invalid")
                lease = data["lease"]
                validate_lease(lease)
                node_id = lease["nodeId"]
                current = projection["leases"].get(node_id)
                fail(current is not None and current["leaseId"] == lease["leaseId"] and current["fence"] == lease["fence"],
                     "CORRUPT_JOURNAL", f"Renewal does not match current lease: {node_id}")
                fail(current["holder"] == lease["holder"] and current["acquiredAt"] == lease["acquiredAt"],
                     "CORRUPT_JOURNAL", f"Renewal changed immutable lease fields: {node_id}")
                fail(event["actor"]["type"] != "subagent" and lease["holder"]["actorType"] == event["actor"]["type"] and lease["holder"]["actorId"] == event["actor"]["id"],
                     "CORRUPT_JOURNAL", f"Renewal actor does not hold lease: {node_id}")
                fail(parse_time(current["expiresAt"]) > parse_time(occurred_at) and lease["renewedAt"] == occurred_at and parse_time(lease["expiresAt"]) > parse_time(occurred_at),
                     "CORRUPT_JOURNAL", f"Lease renewal timestamps are invalid for node: {node_id}")
                projection["leases"][node_id] = lease
                projection["leaseFences"][node_id] = lease["fence"]
            elif event_type == "lease.released":
                fail(set(data) == {"nodeId", "leaseId", "fence"}, "CORRUPT_JOURNAL", "lease.released data is invalid")
                current = projection["leases"].get(data["nodeId"])
                fail(current is not None and current["leaseId"] == data["leaseId"] and current["fence"] == data["fence"],
                     "CORRUPT_JOURNAL", f"Release does not match current lease: {data['nodeId']}")
                fail(event["actor"]["type"] != "subagent" and current["holder"]["actorType"] == event["actor"]["type"] and current["holder"]["actorId"] == event["actor"]["id"],
                     "CORRUPT_JOURNAL", f"Release actor does not hold lease: {data['nodeId']}")
                fail(parse_time(current["expiresAt"]) > parse_time(occurred_at), "CORRUPT_JOURNAL", f"Expired lease was released: {data['nodeId']}")
                projection["leases"].pop(data["nodeId"], None)
                projection["leaseFences"][data["nodeId"]] = data["fence"]
            elif event_type == "lease.swept":
                fail(set(data) == {"expired"}, "CORRUPT_JOURNAL", "lease.swept data is invalid")
                fail(isinstance(data["expired"], list), "CORRUPT_JOURNAL", "lease.swept expired must be an array")
                fail(event["actor"]["type"] in {"operator", "system", "host"}, "CORRUPT_JOURNAL", "Unauthorized lease sweep actor")
                expected_expired = [
                    {"nodeId": node_id, "leaseId": lease["leaseId"], "fence": lease["fence"]}
                    for node_id, lease in sorted(projection["leases"].items())
                    if parse_time(lease["expiresAt"]) <= parse_time(occurred_at)
                ]
                fail(data["expired"] == expected_expired, "CORRUPT_JOURNAL", "lease.swept entries do not match expired leases")
                for item in data["expired"]:
                    fail(isinstance(item, dict) and set(item) == {"nodeId", "leaseId", "fence"}, "CORRUPT_JOURNAL", "lease.swept entry is invalid")
                    projection["leases"].pop(item["nodeId"], None)
                    projection["leaseFences"][item["nodeId"]] = item["fence"]
            elif event_type == "replay.repaired":
                fail(set(data) == {"repairedRevision"}, "CORRUPT_JOURNAL", "replay.repaired data is invalid")
                fail(data["repairedRevision"] == sequence - 1, "CORRUPT_JOURNAL", "replay.repaired revision is invalid")
                fail(event["actor"]["type"] in {"operator", "system"}, "CORRUPT_JOURNAL", "Unauthorized replay repair actor")
        assert projection is not None
        projection["revision"] = sequence
        projection["updatedAt"] = occurred_at
    assert definition is not None and projection is not None
    validate_projection(projection, definition)
    return definition, projection


class DirectoryLock:
    def __init__(self, path: Path, timeout: float = 10.0):
        self.path = path
        self.timeout = timeout
        self.token = str(uuid.uuid4())

    def __enter__(self) -> "DirectoryLock":
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                self.path.mkdir(mode=0o700)
                owner = {"pid": os.getpid(), "token": self.token, "createdAt": format_time(utc_now())}
                atomic_write_json(self.path / "owner.json", owner)
                return self
            except FileExistsError:
                self._break_stale()
                if time.monotonic() >= deadline:
                    raise GraphError("LOCK_TIMEOUT", f"Timed out waiting for graph lock: {self.path}")
                time.sleep(0.025)

    def _break_stale(self) -> None:
        owner_path = self.path / "owner.json"
        try:
            with owner_path.open(encoding="utf-8") as handle:
                owner = json.load(handle)
            pid = int(owner["pid"])
            created = parse_time(owner["createdAt"])
            age = (utc_now() - created).total_seconds()
            alive = True
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                alive = False
            except PermissionError:
                alive = True
            if alive or age < 30:
                return
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError, GraphError):
            try:
                age = time.time() - self.path.stat().st_mtime
            except OSError:
                return
            if age < 30:
                return
        stale = self.path.with_name(f".lock.stale.{uuid.uuid4()}")
        try:
            os.rename(self.path, stale)
        except OSError:
            return
        shutil.rmtree(stale, ignore_errors=True)

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        try:
            with (self.path / "owner.json").open(encoding="utf-8") as handle:
                owner = json.load(handle)
            if owner.get("token") == self.token:
                shutil.rmtree(self.path)
        except OSError:
            pass


def fsync_directory(path: Path) -> None:
    try:
        fd = os.open(str(path), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.tmp.{os.getpid()}.{uuid.uuid4()}")
    try:
        with temp.open("wb") as handle:
            handle.write(canonical_bytes(value))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
        fsync_directory(path.parent)
    except OSError as exc:
        with contextlib.suppress(OSError):
            temp.unlink()
        raise GraphError("IO_ERROR", f"Cannot atomically write {path}", str(exc)) from exc


def append_event(path: Path, event: Mapping[str, Any]) -> None:
    data = canonical_bytes(event)
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
    try:
        fd = os.open(str(path), flags, 0o600)
        try:
            written = 0
            while written < len(data):
                written += os.write(fd, data[written:])
            os.fsync(fd)
        finally:
            os.close(fd)
        fsync_directory(path.parent)
    except OSError as exc:
        raise GraphError("IO_ERROR", f"Cannot append event journal: {path}", str(exc)) from exc


class Store:
    def __init__(self, operator_dir: Path):
        self.operator_dir = operator_dir
        self.graph_dir = operator_dir / "graph"
        self.definition_path = self.graph_dir / "definition.json"
        self.projection_path = self.graph_dir / "projection.json"
        self.events_path = self.graph_dir / "events.jsonl"
        self.lock_path = self.graph_dir / ".lock"

    def lock(self) -> DirectoryLock:
        self.graph_dir.mkdir(parents=True, exist_ok=True)
        return DirectoryLock(self.lock_path)

    def exists(self) -> bool:
        return any(path.exists() for path in (self.definition_path, self.projection_path, self.events_path))

    def load(self, require_match: bool = True) -> Tuple[Dict[str, Any], Dict[str, Any], List[Dict[str, Any]]]:
        definition = validate_definition(load_json(self.definition_path), materialized=True)
        projection = load_json(self.projection_path)
        validate_projection(projection, definition)
        events = read_events(self.events_path)
        replayed_definition, replayed_projection = replay(events)
        if require_match and (not semantic_equal(definition, replayed_definition) or not semantic_equal(projection, replayed_projection)):
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


def actor_from_args(args: argparse.Namespace) -> Dict[str, str]:
    actor_type = args.actor_type
    actor_id = args.actor_id
    fail(actor_type in ACTOR_TYPES, "USAGE", f"Unknown actor type: {actor_type}")
    fail(isinstance(actor_id, str) and actor_id.strip(), "USAGE", "actor-id must be nonempty")
    return {"type": actor_type, "id": actor_id}


def require_request_id(args: argparse.Namespace) -> str:
    value = args.request_id
    fail(isinstance(value, str) and value.strip() and len(value) <= 256, "USAGE", "request-id must be nonempty and at most 256 characters")
    return value


def duplicate_result(events: Sequence[Mapping[str, Any]], request_id: str) -> Optional[Dict[str, Any]]:
    for event in events:
        if event["requestId"] == request_id:
            return dict(event["result"])
    return None


def check_cas(projection: Mapping[str, Any], expected: Optional[int]) -> None:
    if expected is not None and projection["revision"] != expected:
        raise GraphError("REVISION_CONFLICT", "Projection revision does not match expected revision", {
            "expectedRevision": expected, "actualRevision": projection["revision"]
        })


def make_result(command: str, request_id: str, revision: int, data: Mapping[str, Any]) -> Dict[str, Any]:
    return {"ok": True, "command": command, "requestId": request_id, "revision": revision, "data": dict(data)}


def commit_event(store: Store, definition: Dict[str, Any], projection: Dict[str, Any], events: Sequence[Mapping[str, Any]],
                 event_type: str, data: Mapping[str, Any], actor: Mapping[str, str], request_id: str,
                 command: str, result_data: Mapping[str, Any], occurred_at: str) -> Dict[str, Any]:
    sequence = len(events) + 1
    result = make_result(command, request_id, sequence, result_data)
    event = {
        "schemaVersion": EVENT_VERSION,
        "sequence": sequence,
        "eventId": str(uuid.uuid4()),
        "requestId": request_id,
        "occurredAt": occurred_at,
        "actor": {"type": actor["type"], "id": actor["id"]},
        "type": event_type,
        "data": dict(data),
        "result": result,
    }
    append_event(store.events_path, event)
    replayed_definition, replayed_projection = replay([*events, event])
    store.write_materialized(replayed_definition, replayed_projection)
    return result


def default_definition(graph_id: str) -> Dict[str, Any]:
    return {"schemaVersion": GRAPH_VERSION, "graphId": graph_id, "definitionRevision": 1, "nodes": [], "edges": []}


def command_init(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    actor = actor_from_args(args)
    with store.lock():
        if store.exists():
            definition, projection, events = store.load()
            duplicate = duplicate_result(events, request_id)
            if duplicate is not None:
                return duplicate
            return {"ok": True, "command": "init", "requestId": request_id, "revision": projection["revision"],
                    "data": {"initialized": False, "alreadyInitialized": True, "graphId": definition["graphId"]}}
        if args.definition:
            definition = load_input_definition(Path(args.definition))
            definition["definitionRevision"] = 1
        else:
            definition = default_definition(args.graph_id)
        definition = validate_definition(definition, materialized=True)
        occurred_at = format_time(parse_time(args.now))
        sequence = 1
        result_data = {"initialized": True, "alreadyInitialized": False, "graphId": definition["graphId"]}
        result = make_result("init", request_id, sequence, result_data)
        event = {
            "schemaVersion": EVENT_VERSION, "sequence": sequence, "eventId": str(uuid.uuid4()),
            "requestId": request_id, "occurredAt": occurred_at, "actor": actor,
            "type": "graph.initialized", "data": {"definition": definition}, "result": result,
        }
        append_event(store.events_path, event)
        replayed_definition, projection = replay([event])
        store.write_materialized(replayed_definition, projection)
        return result


def command_validate(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    if args.definition:
        definition = load_input_definition(Path(args.definition))
        return {"ok": True, "command": "validate", "data": {"valid": True, "graphId": definition["graphId"], "nodes": len(definition["nodes"]), "edges": len(definition["edges"])}}
    with store.lock():
        definition, projection, events = store.load()
        return {"ok": True, "command": "validate", "data": {"valid": True, "graphId": definition["graphId"], "revision": projection["revision"], "events": len(events)}}


def command_status(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    with store.lock():
        definition, projection, events = store.load()
        nodes = {node["id"]: {"kind": node["kind"], "state": projection["nodeStates"][node["id"]], "priority": node["priority"]} for node in definition["nodes"]}
        return {"ok": True, "command": "status", "data": {
            "graphId": definition["graphId"], "revision": projection["revision"],
            "definitionRevision": definition["definitionRevision"], "eventCount": len(events),
            "nodes": nodes, "leases": projection["leases"], "leaseFences": projection["leaseFences"],
        }}


def command_replace_definition(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    actor = actor_from_args(args)
    fail(actor["type"] != "subagent", "AUTHORITY_DENIED", "Subagents cannot replace definitions or change priority")
    replacement = load_input_definition(Path(args.definition))
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        fail(replacement["graphId"] == definition["graphId"], "INVALID_GRAPH", "replace-definition cannot change graphId")
        current_nodes = {node["id"]: node for node in definition["nodes"]}
        replacement_nodes = {node["id"]: node for node in replacement["nodes"]}
        for node_id in projection["leases"]:
            fail(node_id in replacement_nodes and replacement_nodes[node_id]["kind"] == current_nodes[node_id]["kind"],
                 "LEASE_CONFLICT", f"Cannot remove or change the kind of leased node: {node_id}")
        replacement["definitionRevision"] = definition["definitionRevision"] + 1
        replacement = validate_definition(replacement, materialized=True)
        occurred_at = format_time(parse_time(args.now))
        result_data = {"graphId": replacement["graphId"], "definitionRevision": replacement["definitionRevision"],
                       "nodes": len(replacement["nodes"]), "edges": len(replacement["edges"])}
        return commit_event(store, definition, projection, events, "definition.replaced", {"definition": replacement}, actor,
                            request_id, "replace-definition", result_data, occurred_at)


def find_node(definition: Mapping[str, Any], node_id: str) -> Dict[str, Any]:
    for node in definition["nodes"]:
        if node["id"] == node_id:
            return node
    raise GraphError("INVALID_GRAPH", f"Unknown node: {node_id}")


def require_current_lease(projection: Mapping[str, Any], node_id: str, actor: Mapping[str, str],
                          lease_id: Optional[str], fence: Optional[int], now: dt.datetime) -> None:
    lease = projection["leases"].get(node_id)
    if lease is None:
        if lease_id is not None or fence is not None:
            raise GraphError("FENCE_STALE", f"No current lease exists for node: {node_id}")
        fail(actor["type"] in {"operator", "system", "human"}, "LEASE_REQUIRED", f"Actor requires a valid lease to transition node: {node_id}")
        return
    if lease_id != lease["leaseId"] or fence != lease["fence"]:
        code = "FENCE_STALE" if fence is not None and fence <= lease["fence"] else "LEASE_CONFLICT"
        raise GraphError(code, f"Lease credentials do not match the current owner for node: {node_id}", {"currentFence": lease["fence"]})
    fail(parse_time(lease["expiresAt"]) > now, "LEASE_EXPIRED", f"Lease has expired for node: {node_id}")
    holder = lease["holder"]
    fail(holder["actorType"] == actor["type"] and holder["actorId"] == actor["id"],
         "AUTHORITY_DENIED", f"Actor does not hold the lease for node: {node_id}")


def command_transition(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    actor = actor_from_args(args)
    now = parse_time(args.now)
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        node = find_node(definition, args.node_id)
        family = family_for(node["kind"])
        fail(family != "gate", "AUTHORITY_DENIED", "Human gates must be decided with 'gate decide'")
        fail(not (actor["type"] == "subagent" and node["kind"] == "integration"), "AUTHORITY_DENIED", "Subagents cannot integrate")
        current = projection["nodeStates"][args.node_id]
        fail(args.state in TRANSITIONS[family][current], "INVALID_TRANSITION", f"Transition is not allowed for {node['kind']}: {current} -> {args.state}", {
            "allowed": sorted(TRANSITIONS[family][current])
        })
        require_current_lease(projection, args.node_id, actor, args.lease_id, args.fence, now)
        occurred_at = format_time(now)
        data = {"nodeId": args.node_id, "from": current, "to": args.state}
        return commit_event(store, definition, projection, events, "node.transitioned", data, actor, request_id,
                            "transition", data, occurred_at)


def command_gate_decide(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    actor = actor_from_args(args)
    fail(actor["type"] == "human", "AUTHORITY_DENIED", "Only a human actor may decide a human gate")
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        node = find_node(definition, args.node_id)
        fail(node["kind"] == "human-gate", "INVALID_GRAPH", f"Node is not a human gate: {args.node_id}")
        current = projection["nodeStates"][args.node_id]
        target = args.decision
        fail(target in TRANSITIONS["gate"][current], "INVALID_TRANSITION", f"Gate decision is not allowed: {current} -> {target}")
        occurred_at = format_time(parse_time(args.now))
        data = {"nodeId": args.node_id, "from": current, "to": target}
        return commit_event(store, definition, projection, events, "gate.decided", data, actor, request_id,
                            "gate decide", data, occurred_at)


def validate_ttl(value: int) -> None:
    fail(isinstance(value, int) and 1 <= value <= 86400, "USAGE", "ttl-seconds must be between 1 and 86400")


def command_lease_acquire(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    actor = actor_from_args(args)
    fail(actor["type"] != "subagent", "AUTHORITY_DENIED", "Subagents cannot acquire ownership leases")
    validate_ttl(args.ttl_seconds)
    now = parse_time(args.now)
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        node = find_node(definition, args.node_id)
        fail(node["kind"] != "human-gate", "AUTHORITY_DENIED", "Human gates cannot be leased")
        current = projection["leases"].get(args.node_id)
        if current is not None and parse_time(current["expiresAt"]) > now:
            raise GraphError("LEASE_CONFLICT", f"Node already has an unexpired lease: {args.node_id}", {
                "leaseId": current["leaseId"], "fence": current["fence"], "expiresAt": current["expiresAt"]
            })
        fence = projection["leaseFences"].get(args.node_id, 0) + 1
        lease_id = args.lease_id or str(uuid.uuid4())
        fail(isinstance(lease_id, str) and lease_id.strip(), "USAGE", "lease-id must be nonempty")
        timestamp = format_time(now)
        lease = {
            "schemaVersion": LEASE_VERSION, "nodeId": args.node_id, "leaseId": lease_id,
            "holder": {"actorType": actor["type"], "actorId": actor["id"], "scope": args.holder_scope or args.node_id},
            "acquiredAt": timestamp, "renewedAt": timestamp,
            "expiresAt": format_time(now + dt.timedelta(seconds=args.ttl_seconds)), "fence": fence,
        }
        validate_lease(lease)
        return commit_event(store, definition, projection, events, "lease.acquired", {"lease": lease}, actor,
                            request_id, "lease acquire", {"lease": lease, "reclaimed": current is not None}, timestamp)


def check_lease_operation(projection: Mapping[str, Any], args: argparse.Namespace, actor: Mapping[str, str], now: dt.datetime,
                          require_unexpired: bool = True) -> Dict[str, Any]:
    lease = projection["leases"].get(args.node_id)
    fail(lease is not None, "FENCE_STALE", f"No current lease exists for node: {args.node_id}")
    if args.lease_id != lease["leaseId"] or args.fence != lease["fence"]:
        raise GraphError("FENCE_STALE", f"Lease credentials are stale for node: {args.node_id}", {"currentFence": lease["fence"]})
    holder = lease["holder"]
    fail(holder["actorType"] == actor["type"] and holder["actorId"] == actor["id"], "AUTHORITY_DENIED", f"Actor does not hold lease for node: {args.node_id}")
    if require_unexpired:
        fail(parse_time(lease["expiresAt"]) > now, "LEASE_EXPIRED", f"Lease has expired for node: {args.node_id}")
    return lease


def command_lease_renew(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    actor = actor_from_args(args)
    fail(actor["type"] != "subagent", "AUTHORITY_DENIED", "Subagents cannot renew ownership leases")
    validate_ttl(args.ttl_seconds)
    now = parse_time(args.now)
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        lease = dict(check_lease_operation(projection, args, actor, now))
        lease["renewedAt"] = format_time(now)
        lease["expiresAt"] = format_time(now + dt.timedelta(seconds=args.ttl_seconds))
        return commit_event(store, definition, projection, events, "lease.renewed", {"lease": lease}, actor,
                            request_id, "lease renew", {"lease": lease}, format_time(now))


def command_lease_release(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    actor = actor_from_args(args)
    fail(actor["type"] != "subagent", "AUTHORITY_DENIED", "Subagents cannot release ownership leases")
    now = parse_time(args.now)
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        lease = check_lease_operation(projection, args, actor, now, require_unexpired=True)
        data = {"nodeId": args.node_id, "leaseId": lease["leaseId"], "fence": lease["fence"]}
        return commit_event(store, definition, projection, events, "lease.released", data, actor,
                            request_id, "lease release", data, format_time(now))


def command_lease_sweep(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    actor = actor_from_args(args)
    fail(actor["type"] in {"operator", "system", "host"}, "AUTHORITY_DENIED", "Only operator, system, or host actors may sweep leases")
    now = parse_time(args.now)
    with store.lock():
        definition, projection, events = store.load()
        duplicate = duplicate_result(events, request_id)
        if duplicate is not None:
            return duplicate
        check_cas(projection, args.expected_revision)
        expired = []
        for node_id, lease in sorted(projection["leases"].items()):
            if parse_time(lease["expiresAt"]) <= now:
                expired.append({"nodeId": node_id, "leaseId": lease["leaseId"], "fence": lease["fence"]})
        return commit_event(store, definition, projection, events, "lease.swept", {"expired": expired}, actor,
                            request_id, "lease sweep", {"expired": expired, "count": len(expired)}, format_time(now))


def command_replay_check(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    with store.lock():
        definition = validate_definition(load_json(store.definition_path), materialized=True)
        projection = load_json(store.projection_path)
        validate_projection(projection, definition)
        events = read_events(store.events_path)
        replayed_definition, replayed_projection = replay(events)
        definition_drift = not semantic_equal(definition, replayed_definition)
        projection_drift = not semantic_equal(projection, replayed_projection)
        if definition_drift or projection_drift:
            raise GraphError("REPLAY_DRIFT", "Materialized graph state differs from deterministic replay", {
                "definitionDrift": definition_drift, "projectionDrift": projection_drift,
                "journalRevision": replayed_projection["revision"], "projectionRevision": projection.get("revision"),
            })
        return {"ok": True, "command": "replay check", "data": {"inSync": True, "revision": projection["revision"], "events": len(events)}}


def command_replay_repair(store: Store, args: argparse.Namespace) -> Dict[str, Any]:
    request_id = require_request_id(args)
    actor = actor_from_args(args)
    fail(actor["type"] in {"operator", "system"}, "AUTHORITY_DENIED", "Only operator or system actors may repair replay drift")
    with store.lock():
        events = read_events(store.events_path)
        duplicate = duplicate_result(events, request_id)
        if duplicate is not None:
            return duplicate
        definition, projection = replay(events)
        if args.expected_revision is not None and projection["revision"] != args.expected_revision:
            raise GraphError("REVISION_CONFLICT", "Journal revision does not match expected revision", {
                "expectedRevision": args.expected_revision, "actualRevision": projection["revision"]
            })
        occurred_at = format_time(parse_time(args.now))
        repaired_revision = projection["revision"]
        return commit_event(store, definition, projection, events, "replay.repaired", {"repairedRevision": repaired_revision}, actor,
                            request_id, "replay repair", {"repairedRevision": repaired_revision}, occurred_at)


def add_actor_options(parser: argparse.ArgumentParser, default_type: str = "operator") -> None:
    parser.add_argument("--actor-type", choices=sorted(ACTOR_TYPES), default=default_type)
    parser.add_argument("--actor-id", default=default_type)


def add_mutation_options(parser: argparse.ArgumentParser, default_type: str = "operator", cas: bool = True) -> None:
    parser.add_argument("--request-id", required=True)
    if cas:
        parser.add_argument("--expected-revision", type=int)
    parser.add_argument("--now", help="RFC 3339 transaction time; primarily for deterministic automation")
    add_actor_options(parser, default_type)


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
    add_mutation_options(decide, default_type="human")
    decide.set_defaults(handler=command_gate_decide)

    lease = sub.add_parser("lease")
    lease_sub = lease.add_subparsers(dest="lease_command", required=True)
    acquire = lease_sub.add_parser("acquire")
    acquire.add_argument("node_id")
    acquire.add_argument("--lease-id")
    acquire.add_argument("--holder-scope")
    acquire.add_argument("--ttl-seconds", type=int, default=300)
    add_mutation_options(acquire, default_type="lane")
    acquire.set_defaults(handler=command_lease_acquire)
    renew = lease_sub.add_parser("renew")
    renew.add_argument("node_id")
    renew.add_argument("--lease-id", required=True)
    renew.add_argument("--fence", type=int, required=True)
    renew.add_argument("--ttl-seconds", type=int, default=300)
    add_mutation_options(renew, default_type="lane")
    renew.set_defaults(handler=command_lease_renew)
    release = lease_sub.add_parser("release")
    release.add_argument("node_id")
    release.add_argument("--lease-id", required=True)
    release.add_argument("--fence", type=int, required=True)
    add_mutation_options(release, default_type="lane")
    release.set_defaults(handler=command_lease_release)
    sweep = lease_sub.add_parser("sweep")
    add_mutation_options(sweep, default_type="system")
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
    json.dump(value, stream, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
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
    except OSError as exc:
        print_json({"ok": False, "error": {"code": "IO_ERROR", "message": str(exc)}}, sys.stderr)
        return EXIT_CODES["IO_ERROR"]
    except KeyboardInterrupt:
        print_json({"ok": False, "error": {"code": "INTERRUPTED", "message": "Interrupted"}}, sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
