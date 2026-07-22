#!/usr/bin/env bash
set -euo pipefail

IFS= read -r -d '' OPERATOR_SCHEDULER_PROGRAM <<'PY' || true
from __future__ import annotations

import argparse
import datetime as dt
import heapq
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple


SNAPSHOT_VERSION = "operator.control-snapshot/v1"
LEASE_VERSION = "operator.ownership-lease/v1"
CLOCK_VERSION = "operator.scheduler-clock/v1"
FRONTIER_VERSION = "operator.scheduler-frontier/v1"
STATUS_VERSION = "operator.scheduler-status/v1"
MAX_INPUT_BYTES = 32 * 1024 * 1024
MAX_ITEMS = 200000
MAX_DEPTH = 40
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+\-]*$")
BINDING_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]*$")
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")

NODE_KINDS = {
    "goal", "feature", "lane", "task", "validation", "human-gate",
    "integration", "feedback",
}
WORK_KINDS = {"task", "validation", "integration", "feedback"}
CONTAINER_KINDS = {"goal", "feature", "lane"}
EDGE_KINDS = {
    "contains", "depends-on", "assigned-to", "validated-by", "gated-by",
    "integrates-into", "feedback-for",
}
ENDPOINTS = {
    "contains": (CONTAINER_KINDS, NODE_KINDS - {"goal"}),
    "depends-on": (NODE_KINDS - {"human-gate"}, NODE_KINDS),
    "assigned-to": (WORK_KINDS, {"lane"}),
    "validated-by": ({"task", "integration"}, {"validation"}),
    "gated-by": ({"goal", "feature", "task", "integration"}, {"human-gate"}),
    "integrates-into": ({"integration"}, {"feature"}),
    "feedback-for": ({"feedback"}, NODE_KINDS - {"feedback"}),
}
STATES = {
    "container": {"planned", "active", "blocked", "completed", "cancelled"},
    "work": {"pending", "ready", "active", "blocked", "completed", "failed", "cancelled"},
    "gate": {"pending", "approved", "rejected", "cancelled"},
}
INITIAL = {"container": "planned", "work": "pending", "gate": "pending"}
SUCCESS = {"container": "completed", "work": "completed", "gate": "approved"}
SCHEDULABLE_STATES = {"pending", "ready"}
CLAIM_KINDS = ("files", "contracts", "resources", "lanes")


class SchedulerError(Exception):
    def __init__(self, code: str, message: str, details: Any = None, exit_code: int = 5):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details
        self.exit_code = exit_code


def fail(condition: bool, code: str, message: str, details: Any = None) -> None:
    if not condition:
        raise SchedulerError(code, message, details)


def family(kind: str) -> str:
    if kind in CONTAINER_KINDS:
        return "container"
    if kind in WORK_KINDS:
        return "work"
    return "gate"


def strict_pairs(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate object key: {key}")
        result[key] = value
    return result


def reject_float(raw: str) -> None:
    raise ValueError(f"floating-point JSON number is not canonical: {raw}")


def parse_integer(raw: str) -> int:
    if raw == "-0":
        raise ValueError("negative zero is not a canonical JSON integer")
    return int(raw)


def reject_constant(raw: str) -> None:
    raise ValueError(f"non-finite JSON number: {raw}")


def valid_text(value: Any, maximum: int, identifier: bool = False) -> bool:
    return (
        isinstance(value, str)
        and 1 <= len(value) <= maximum
        and bool(value.strip())
        and not any(ord(ch) < 32 or 127 <= ord(ch) <= 159 or 0xD800 <= ord(ch) <= 0xDFFF for ch in value)
        and (not identifier or ID_RE.fullmatch(value) is not None)
    )


def valid_binding_id(value: Any) -> bool:
    return isinstance(value, str) and len(value) <= 128 and BINDING_ID_RE.fullmatch(value) is not None


def require_exact(value: Any, required: Set[str], label: str, code: str = "INVALID_SNAPSHOT") -> Mapping[str, Any]:
    fail(isinstance(value, dict), code, f"{label} must be an object")
    actual = set(value)
    fail(actual == required, code, f"{label} fields are invalid", {
        "missing": sorted(required - actual), "unknown": sorted(actual - required),
    })
    return value


def parse_time(value: Any, label: str) -> dt.datetime:
    fail(isinstance(value, str) and len(value) <= 64, "INVALID_SNAPSHOT", f"{label} must be an RFC 3339 timestamp")
    raw = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = dt.datetime.fromisoformat(raw)
    except (ValueError, OverflowError) as exc:
        raise SchedulerError("INVALID_SNAPSHOT", f"{label} is not a valid RFC 3339 timestamp") from exc
    fail(parsed.tzinfo is not None, "INVALID_SNAPSHOT", f"{label} must include a timezone")
    return parsed.astimezone(dt.timezone.utc)


def validate_json_domain(root: Any, code: str = "INVALID_SNAPSHOT") -> None:
    stack: List[Tuple[Any, int]] = [(root, 1)]
    items = 0
    while stack:
        value, depth = stack.pop()
        fail(depth <= MAX_DEPTH, code, "JSON input exceeds the maximum depth")
        items += 1
        fail(items <= MAX_ITEMS, code, "JSON input exceeds the maximum item count")
        if isinstance(value, str):
            fail(not any(ord(ch) < 32 or 127 <= ord(ch) <= 159 or 0xD800 <= ord(ch) <= 0xDFFF for ch in value),
                 code, "JSON input contains a non-canonical string")
        elif isinstance(value, dict):
            for key, item in value.items():
                fail(isinstance(key, str), code, "JSON object key is not a string")
                stack.append((key, depth + 1))
                stack.append((item, depth + 1))
        elif isinstance(value, list):
            stack.extend((item, depth + 1) for item in value)
        elif value is not None and not isinstance(value, (bool, int)):
            raise SchedulerError(code, "JSON input contains a non-canonical value")


def read_input(path: str) -> Mapping[str, Any]:
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1) if path == "-" else Path(path).read_bytes()
    except OSError as exc:
        raise SchedulerError("INPUT_ERROR", f"cannot read scheduler snapshot: {exc}", exit_code=3) from exc
    fail(len(raw) <= MAX_INPUT_BYTES, "INVALID_SNAPSHOT", f"snapshot exceeds {MAX_INPUT_BYTES} bytes")
    try:
        value = json.loads(
            raw.decode("utf-8"), parse_float=reject_float, parse_int=parse_integer,
            parse_constant=reject_constant, object_pairs_hook=strict_pairs,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise SchedulerError("INVALID_SNAPSHOT", f"invalid canonical snapshot JSON: {exc}") from exc
    validate_json_domain(value)
    fail(isinstance(value, dict), "INVALID_SNAPSHOT", "scheduler input must be a JSON object")
    if value.get("schemaVersion") == SNAPSHOT_VERSION:
        return value
    if value.get("ok") is True:
        require_exact(value, {"ok", "command", "data"}, "graph CLI envelope")
        fail(isinstance(value.get("command"), str) and value["command"] in {"status", "snapshot"},
             "INVALID_SNAPSHOT", "graph CLI envelope command must be status or snapshot")
        data = value.get("data")
        fail(isinstance(data, dict), "INVALID_SNAPSHOT", "graph CLI envelope data must be an object")
        return data
    version = value.get("schemaVersion")
    if isinstance(version, str):
        raise SchedulerError("UNKNOWN_SNAPSHOT_VERSION", f"unsupported snapshot schemaVersion: {version}", {"expected": SNAPSHOT_VERSION}, 4)
    raise SchedulerError("INVALID_SNAPSHOT", "input is neither a control snapshot nor a successful graph status/snapshot envelope")


def read_clock(path: Optional[str]) -> Optional[Dict[str, Any]]:
    if path is None:
        return None
    try:
        raw = sys.stdin.buffer.read(4097) if path == "-" else Path(path).read_bytes()
    except OSError as exc:
        raise SchedulerError("TRUSTED_CLOCK_INVALID", f"cannot read trusted current clock: {exc}", exit_code=3) from exc
    fail(len(raw) <= 4096, "TRUSTED_CLOCK_INVALID", "trusted current clock exceeds 4096 bytes")
    try:
        value = json.loads(
            raw.decode("utf-8"), parse_float=reject_float, parse_int=parse_integer,
            parse_constant=reject_constant, object_pairs_hook=strict_pairs,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise SchedulerError("TRUSTED_CLOCK_INVALID", f"invalid canonical trusted current clock JSON: {exc}") from exc
    validate_json_domain(value, "TRUSTED_CLOCK_INVALID")
    clock = require_exact(value, {"schemaVersion", "hostId", "bootId", "monotonicSource", "monotonicNs"},
                          "trusted current clock", "TRUSTED_CLOCK_INVALID")
    fail(clock.get("schemaVersion") == CLOCK_VERSION, "TRUSTED_CLOCK_INVALID",
         f"unsupported trusted current clock schemaVersion: {clock.get('schemaVersion')}", {"expected": CLOCK_VERSION})
    fail(valid_text(clock.get("hostId"), 256) and valid_text(clock.get("bootId"), 256),
         "TRUSTED_CLOCK_INVALID", "trusted current clock identity is invalid")
    fail(isinstance(clock.get("monotonicSource"), str)
         and clock["monotonicSource"] in {"linux-proc-uptime", "macos-mach-continuous"},
         "TRUSTED_CLOCK_INVALID", "trusted current clock monotonicSource is invalid")
    fail(isinstance(clock.get("monotonicNs"), int) and not isinstance(clock["monotonicNs"], bool)
         and clock["monotonicNs"] >= 0, "TRUSTED_CLOCK_INVALID", "trusted current clock monotonicNs is invalid")
    return dict(clock)


def validate_scheduler_metadata(node: Mapping[str, Any]) -> Dict[str, List[str]]:
    metadata = node["metadata"]
    execution = metadata.get("execution")
    if execution is not None:
        require_exact(execution, {"idempotent", "reclaimable"}, f"execution metadata for node {node['id']}")
        fail(all(isinstance(execution[key], bool) for key in execution), "INVALID_NODE",
             f"execution metadata for node {node['id']} must contain booleans")
    scheduler = metadata.get("scheduler", {})
    fail(isinstance(scheduler, dict), "INVALID_NODE", f"scheduler metadata for node {node['id']} must be an object")
    allowed = {"claims"}
    fail(set(scheduler) <= allowed, "INVALID_NODE", f"scheduler metadata for node {node['id']} has unknown fields", sorted(set(scheduler) - allowed))
    raw_claims = scheduler.get("claims", {})
    fail(isinstance(raw_claims, dict) and set(raw_claims) <= set(CLAIM_KINDS), "INVALID_NODE",
         f"scheduler claims for node {node['id']} are invalid")
    claims: Dict[str, List[str]] = {kind: [] for kind in CLAIM_KINDS}
    for kind, values in raw_claims.items():
        fail(isinstance(values, list), "INVALID_NODE",
             f"scheduler {kind} claims for node {node['id']} must be an array")
        fail(all(valid_text(item, 1024) for item in values), "INVALID_NODE",
             f"scheduler {kind} claims for node {node['id']} contain an invalid value")
        fail(len(values) == len(set(values)), "INVALID_NODE",
             f"scheduler {kind} claims for node {node['id']} must be unique")
        claims[kind] = sorted(values)
    return claims


def validate_lease(node_id: str, value: Any, revision: int, updated_at: dt.datetime) -> None:
    lease = require_exact(value, {
        "schemaVersion", "nodeId", "leaseId", "holder", "acquiredAt", "renewedAt",
        "expiresAt", "fence", "clock",
    }, f"lease for node {node_id}")
    fail(lease.get("schemaVersion") == LEASE_VERSION, "UNKNOWN_SNAPSHOT_VERSION", "unsupported ownership lease version")
    fail(lease.get("nodeId") == node_id and valid_text(node_id, 128, True), "INVALID_SNAPSHOT", f"lease key does not match nodeId: {node_id}")
    fail(valid_text(lease.get("leaseId"), 256, True), "INVALID_SNAPSHOT", f"leaseId is invalid for node {node_id}")
    fail(isinstance(lease.get("fence"), int) and not isinstance(lease["fence"], bool) and lease["fence"] >= 1,
         "INVALID_SNAPSHOT", f"lease fence is invalid for node {node_id}")
    acquired = parse_time(lease.get("acquiredAt"), f"lease acquiredAt for {node_id}")
    renewed = parse_time(lease.get("renewedAt"), f"lease renewedAt for {node_id}")
    expires = parse_time(lease.get("expiresAt"), f"lease expiresAt for {node_id}")
    fail(acquired <= renewed < expires and acquired <= updated_at, "INVALID_SNAPSHOT", f"lease timestamps are invalid for node {node_id}")
    holder = require_exact(lease.get("holder"), {
        "actorType", "actorId", "bindingId", "bindingGeneration", "bindingHash", "scope", "laneNodeId",
    }, f"lease holder for node {node_id}")
    fail(isinstance(holder.get("actorType"), str) and holder["actorType"] in {"lane", "host"},
         "INVALID_SNAPSHOT", f"lease actorType is invalid for node {node_id}")
    fail(valid_text(holder.get("actorId"), 256, True), "INVALID_SNAPSHOT", f"lease actorId is invalid for node {node_id}")
    fail(valid_binding_id(holder.get("bindingId")),
         "INVALID_SNAPSHOT", f"lease bindingId is invalid for node {node_id}")
    fail(isinstance(holder.get("bindingGeneration"), int) and not isinstance(holder["bindingGeneration"], bool) and holder["bindingGeneration"] >= 1,
         "INVALID_SNAPSHOT", f"lease bindingGeneration is invalid for node {node_id}")
    fail(isinstance(holder.get("bindingHash"), str) and HASH_RE.fullmatch(holder["bindingHash"]) is not None,
         "INVALID_SNAPSHOT", f"lease bindingHash is invalid for node {node_id}")
    fail(valid_text(holder.get("scope"), 512, True) and valid_text(holder.get("laneNodeId"), 128, True),
         "INVALID_SNAPSHOT", f"lease scope is invalid for node {node_id}")
    clock = require_exact(lease.get("clock"), {
        "hostId", "bootId", "monotonicSource", "acquiredMonotonicNs", "expiresMonotonicNs",
    }, f"lease clock for node {node_id}")
    fail(valid_text(clock.get("hostId"), 256) and valid_text(clock.get("bootId"), 256),
         "INVALID_SNAPSHOT", f"lease clock identity is invalid for node {node_id}")
    fail(isinstance(clock.get("monotonicSource"), str)
         and clock["monotonicSource"] in {"linux-proc-uptime", "macos-mach-continuous"},
         "INVALID_SNAPSHOT", f"lease monotonic source is invalid for node {node_id}")
    for key in ("acquiredMonotonicNs", "expiresMonotonicNs"):
        fail(isinstance(clock.get(key), int) and not isinstance(clock[key], bool) and clock[key] >= 0,
             "INVALID_SNAPSHOT", f"lease clock {key} is invalid for node {node_id}")
    fail(clock["expiresMonotonicNs"] > clock["acquiredMonotonicNs"], "INVALID_SNAPSHOT", f"lease monotonic interval is invalid for node {node_id}")


def validate_snapshot(snapshot: Mapping[str, Any]) -> Dict[str, Any]:
    required = {
        "schemaVersion", "graphId", "revision", "definitionRevision", "definitionHash", "updatedAt",
        "eventCount", "nodes", "edges", "leases", "leaseFences", "executionStarted",
        "reconciliations", "bindingGenerations", "authorityKeyId", "authorityHash",
    }
    require_exact(snapshot, required, "control snapshot")
    version = snapshot.get("schemaVersion")
    if version != SNAPSHOT_VERSION:
        raise SchedulerError("UNKNOWN_SNAPSHOT_VERSION", f"unsupported snapshot schemaVersion: {version}", {"expected": SNAPSHOT_VERSION}, 4)
    fail(valid_text(snapshot.get("graphId"), 128, True), "INVALID_SNAPSHOT", "snapshot graphId is invalid")
    for key in ("revision", "definitionRevision", "eventCount"):
        fail(isinstance(snapshot.get(key), int) and not isinstance(snapshot[key], bool) and snapshot[key] >= 1,
             "INVALID_SNAPSHOT", f"snapshot {key} must be a positive integer")
    fail(snapshot["eventCount"] == snapshot["revision"], "INVALID_SNAPSHOT", "snapshot eventCount must equal revision")
    fail(snapshot["definitionRevision"] <= snapshot["revision"], "INVALID_SNAPSHOT", "snapshot definitionRevision cannot exceed revision")
    fail(isinstance(snapshot.get("definitionHash"), str) and HASH_RE.fullmatch(snapshot["definitionHash"]) is not None,
         "INVALID_SNAPSHOT", "snapshot definitionHash is invalid")
    fail(valid_text(snapshot.get("authorityKeyId"), 128, True), "INVALID_SNAPSHOT", "snapshot authorityKeyId is invalid")
    fail(isinstance(snapshot.get("authorityHash"), str) and HASH_RE.fullmatch(snapshot["authorityHash"]) is not None,
         "INVALID_SNAPSHOT", "snapshot authorityHash is invalid")
    updated_at = parse_time(snapshot.get("updatedAt"), "snapshot updatedAt")

    raw_nodes = snapshot.get("nodes")
    fail(isinstance(raw_nodes, list) and len(raw_nodes) <= 10000, "INVALID_SNAPSHOT", "snapshot nodes must be a bounded array")
    nodes: Dict[str, Dict[str, Any]] = {}
    paused: Dict[str, bool] = {}
    claims: Dict[str, Dict[str, List[str]]] = {}
    for index, raw in enumerate(raw_nodes):
        node = require_exact(raw, {"id", "kind", "title", "initialState", "priority", "metadata", "state"}, f"nodes[{index}]")
        node_id = node.get("id")
        fail(valid_text(node_id, 128, True), "INVALID_NODE", f"nodes[{index}].id is invalid")
        fail(node_id not in nodes, "INVALID_NODE", f"duplicate node id: {node_id}")
        kind = node.get("kind")
        fail(isinstance(kind, str) and kind in NODE_KINDS, "INVALID_NODE", f"node kind is invalid for {node_id}")
        node_family = family(kind)
        fail(isinstance(node.get("initialState"), str) and node["initialState"] == INITIAL[node_family],
             "INVALID_NODE", f"initialState is invalid for {node_id}")
        fail(isinstance(node.get("state"), str) and node["state"] in STATES[node_family],
             "INVALID_NODE", f"state is invalid for {node_id}")
        fail(valid_text(node.get("title"), 512), "INVALID_NODE", f"title is invalid for {node_id}")
        fail(isinstance(node.get("priority"), int) and not isinstance(node["priority"], bool) and 0 <= node["priority"] <= 1000,
             "INVALID_NODE", f"priority is invalid for {node_id}")
        fail(isinstance(node.get("metadata"), dict), "INVALID_NODE", f"metadata is invalid for {node_id}")
        paused[node_id] = node["state"] == "blocked"
        claims[node_id] = validate_scheduler_metadata(node)
        nodes[node_id] = dict(node)

    raw_edges = snapshot.get("edges")
    fail(isinstance(raw_edges, list) and len(raw_edges) <= 50000, "INVALID_SNAPSHOT", "snapshot edges must be a bounded array")
    edges: List[Dict[str, Any]] = []
    edge_ids: Set[str] = set()
    edge_triples: Set[Tuple[str, str, str]] = set()
    for index, raw in enumerate(raw_edges):
        edge = require_exact(raw, {"id", "kind", "from", "to", "metadata"}, f"edges[{index}]")
        edge_id = edge.get("id")
        fail(valid_text(edge_id, 384, True) and edge_id not in edge_ids, "INVALID_EDGE", f"edge id is invalid or duplicated at index {index}")
        edge_ids.add(edge_id)
        kind = edge.get("kind")
        source, target = edge.get("from"), edge.get("to")
        fail(isinstance(kind, str) and kind in EDGE_KINDS, "INVALID_EDGE", f"edge kind is invalid for {edge_id}")
        fail(valid_text(source, 128, True) and valid_text(target, 128, True),
             "INVALID_EDGE", f"edge endpoints are invalid for {edge_id}")
        if source not in nodes or target not in nodes:
            raise SchedulerError("MISSING_DEPENDENCY", f"edge {edge_id} references a missing node", {"from": source, "to": target})
        fail(source != target, "DEPENDENCY_CYCLE", f"self edge is not schedulable: {edge_id}")
        allowed_from, allowed_to = ENDPOINTS[kind]
        fail(nodes[source]["kind"] in allowed_from and nodes[target]["kind"] in allowed_to,
             "INVALID_EDGE", f"edge endpoints are invalid for {edge_id}")
        triple = (kind, source, target)
        fail(triple not in edge_triples, "INVALID_EDGE", f"duplicate edge relation: {kind} {source} -> {target}")
        edge_triples.add(triple)
        fail(isinstance(edge.get("metadata"), dict), "INVALID_EDGE", f"edge metadata is invalid for {edge_id}")
        if kind == "gated-by":
            require_exact(edge["metadata"], {"protectedTransitions"}, f"gated-by metadata for {edge_id}")
            protected = edge["metadata"].get("protectedTransitions")
            transition_targets = {
                "container": {"active", "blocked", "completed", "cancelled"},
                "work": {"ready", "active", "blocked", "completed", "failed", "cancelled"},
            }[family(nodes[source]["kind"])]
            fail(isinstance(protected, list) and bool(protected),
                 "INVALID_EDGE", f"protectedTransitions must be a non-empty array for {edge_id}")
            fail(all(isinstance(item, str) and item in transition_targets for item in protected),
                 "INVALID_EDGE", f"protectedTransitions contain an invalid value for {edge_id}")
            fail(len(protected) == len(set(protected)),
                 "INVALID_EDGE", f"protectedTransitions must be unique for {edge_id}")
            if nodes[source]["kind"] == "integration":
                fail({"ready", "active", "completed"} <= set(protected), "INVALID_EDGE", f"integration gate coverage is invalid for {edge_id}")
        edges.append(dict(edge))

    indegree = {node_id: 0 for node_id in nodes}
    adjacency: Dict[str, List[str]] = {node_id: [] for node_id in nodes}
    for edge in edges:
        if edge["kind"] in {"contains", "depends-on"}:
            adjacency[edge["from"]].append(edge["to"])
            indegree[edge["to"]] += 1
    queue = [node_id for node_id, count in indegree.items() if count == 0]
    heapq.heapify(queue)
    visited = 0
    while queue:
        node_id = heapq.heappop(queue)
        visited += 1
        for target in sorted(adjacency[node_id]):
            indegree[target] -= 1
            if indegree[target] == 0:
                heapq.heappush(queue, target)
    fail(visited == len(nodes), "DEPENDENCY_CYCLE", "contains/depends-on graph contains a cycle")

    leases = snapshot.get("leases")
    fail(isinstance(leases, dict) and len(leases) <= 10000, "INVALID_SNAPSHOT", "snapshot leases must be an object")
    for node_id, lease in leases.items():
        fail(node_id in nodes and nodes[node_id]["kind"] in WORK_KINDS, "INVALID_SNAPSHOT", f"lease references a non-work node: {node_id}")
        validate_lease(node_id, lease, snapshot["revision"], updated_at)

    fences = snapshot.get("leaseFences")
    fail(isinstance(fences, dict) and len(fences) <= 10000, "INVALID_SNAPSHOT", "snapshot leaseFences must be an object")
    for node_id, fence in fences.items():
        fail(node_id in nodes and nodes[node_id]["kind"] in WORK_KINDS and isinstance(fence, int)
             and not isinstance(fence, bool) and fence >= 1, "INVALID_SNAPSHOT", f"lease fence is invalid for {node_id}")
        if node_id in leases:
            fail(fence == leases[node_id]["fence"], "INVALID_SNAPSHOT", f"lease fence does not match live record for {node_id}")

    started = snapshot.get("executionStarted")
    fail(isinstance(started, dict) and len(started) <= 10000, "INVALID_SNAPSHOT", "snapshot executionStarted must be an object")
    for node_id, marker in started.items():
        fail(node_id in nodes and nodes[node_id]["kind"] in WORK_KINDS, "INVALID_SNAPSHOT", f"execution marker references invalid node: {node_id}")
        marker = require_exact(marker, {"revision", "occurredAt"}, f"execution marker for {node_id}")
        fail(isinstance(marker.get("revision"), int) and not isinstance(marker["revision"], bool)
             and 1 <= marker["revision"] <= snapshot["revision"], "INVALID_SNAPSHOT", f"execution marker revision is invalid for {node_id}")
        fail(parse_time(marker.get("occurredAt"), f"execution marker occurredAt for {node_id}") <= updated_at,
             "INVALID_SNAPSHOT", f"execution marker is in the future for {node_id}")
    fail(set(leases) <= set(started), "INVALID_SNAPSHOT", "every lease must have an executionStarted marker")

    reconciliations = snapshot.get("reconciliations")
    fail(isinstance(reconciliations, dict) and len(reconciliations) <= 10000, "INVALID_SNAPSHOT", "snapshot reconciliations must be an object")
    for node_id, record in reconciliations.items():
        fail(node_id in nodes and nodes[node_id]["kind"] in WORK_KINDS and node_id not in leases,
             "INVALID_SNAPSHOT", f"reconciliation references invalid or leased node: {node_id}")
        record = require_exact(record, {"leaseId", "fence", "reason", "requiredAt", "priorState"}, f"reconciliation for {node_id}")
        fail(valid_text(record.get("leaseId"), 256, True), "INVALID_SNAPSHOT", f"reconciliation leaseId is invalid for {node_id}")
        fail(isinstance(record.get("fence"), int) and not isinstance(record["fence"], bool) and record["fence"] >= 1,
             "INVALID_SNAPSHOT", f"reconciliation fence is invalid for {node_id}")
        fail(isinstance(record.get("reason"), str)
             and record["reason"] in {"expired-unsafe", "binding-rotated", "clock-recovery"},
             "INVALID_SNAPSHOT", f"reconciliation reason is invalid for {node_id}")
        fail(isinstance(record.get("priorState"), str) and record["priorState"] in STATES["work"],
             "INVALID_SNAPSHOT", f"reconciliation priorState is invalid for {node_id}")
        fail(parse_time(record.get("requiredAt"), f"reconciliation requiredAt for {node_id}") <= updated_at,
             "INVALID_SNAPSHOT", f"reconciliation is in the future for {node_id}")
        fail(node_id in started and fences.get(node_id) == record["fence"], "INVALID_SNAPSHOT",
             f"reconciliation history is incomplete for {node_id}")

    generations = snapshot.get("bindingGenerations")
    fail(isinstance(generations, dict) and len(generations) <= 10000, "INVALID_SNAPSHOT", "snapshot bindingGenerations must be an object")
    for binding_id, record in generations.items():
        fail(valid_binding_id(binding_id),
             "INVALID_SNAPSHOT", f"binding generation key is invalid: {binding_id}")
        record = require_exact(record, {"generation", "bindingHash"}, f"binding generation for {binding_id}")
        fail(isinstance(record.get("generation"), int) and not isinstance(record["generation"], bool) and record["generation"] >= 1,
             "INVALID_SNAPSHOT", f"binding generation is invalid for {binding_id}")
        fail(isinstance(record.get("bindingHash"), str) and HASH_RE.fullmatch(record["bindingHash"]) is not None,
             "INVALID_SNAPSHOT", f"binding hash is invalid for {binding_id}")
    assigned: Dict[str, List[str]] = {node_id: [] for node_id in nodes}
    dependencies: Dict[str, List[str]] = {node_id: [] for node_id in nodes}
    gates: Dict[str, List[Dict[str, Any]]] = {node_id: [] for node_id in nodes}
    for edge in edges:
        if edge["kind"] == "assigned-to":
            assigned[edge["from"]].append(edge["to"])
        elif edge["kind"] == "depends-on":
            dependencies[edge["from"]].append(edge["to"])
        elif edge["kind"] == "gated-by":
            gates[edge["from"]].append({
                "gateId": edge["to"],
                "protectedTransitions": list(edge["metadata"]["protectedTransitions"]),
            })
    for values in (*assigned.values(), *dependencies.values()):
        values.sort()
    for values in gates.values():
        values.sort(key=lambda item: (item["gateId"], item["protectedTransitions"]))
    for node_id, lease in leases.items():
        fail(lease["holder"]["laneNodeId"] in assigned[node_id], "INVALID_SNAPSHOT",
             f"lease holder lane is not assigned to node: {node_id}")

    return {
        "snapshot": snapshot, "nodes": nodes, "edges": edges, "leases": leases,
        "updatedAt": updated_at, "paused": paused, "claims": claims,
        "assigned": assigned, "dependencies": dependencies, "gates": gates,
        "reconciliations": reconciliations,
    }


def reason(code: str, **details: Any) -> Dict[str, Any]:
    result: Dict[str, Any] = {"code": code}
    if details:
        result["details"] = details
    return result


def node_claims(model: Mapping[str, Any], node_id: str) -> Dict[str, List[str]]:
    claims = {key: list(values) for key, values in model["claims"][node_id].items()}
    claims["lanes"] = sorted(set(claims["lanes"]) | set(model["assigned"][node_id]))
    return claims


def bind_trusted_clock(model: Dict[str, Any], clock: Optional[Mapping[str, Any]]) -> None:
    leases = model["leases"]
    if leases and clock is None:
        raise SchedulerError("TRUSTED_CLOCK_REQUIRED", "a trusted current clock is required to classify snapshot leases")
    liveness: Dict[str, str] = {}
    for node_id in sorted(leases):
        lease_clock = leases[node_id]["clock"]
        expected = {key: lease_clock[key] for key in ("hostId", "bootId", "monotonicSource")}
        actual = {key: clock[key] for key in ("hostId", "bootId", "monotonicSource")} if clock is not None else {}
        if actual != expected:
            raise SchedulerError("TRUSTED_CLOCK_MISMATCH", f"trusted current clock does not match lease boot session: {node_id}", {
                "nodeId": node_id, "expected": expected, "actual": actual,
            })
        if clock["monotonicNs"] < lease_clock["acquiredMonotonicNs"]:
            raise SchedulerError("TRUSTED_CLOCK_ROLLBACK", f"trusted current clock precedes lease acquisition: {node_id}", {
                "nodeId": node_id, "currentMonotonicNs": clock["monotonicNs"],
                "acquiredMonotonicNs": lease_clock["acquiredMonotonicNs"],
            })
        liveness[node_id] = "stale" if clock["monotonicNs"] >= lease_clock["expiresMonotonicNs"] else "live"
    model["trustedClock"] = dict(clock) if clock is not None else None
    model["leaseLiveness"] = liveness


def live_lease(model: Mapping[str, Any], node_id: str) -> bool:
    return model["leaseLiveness"].get(node_id) == "live"


def safely_reclaimable_stale_lease(model: Mapping[str, Any], node_id: str) -> bool:
    if model["leaseLiveness"].get(node_id) != "stale":
        return False
    node = model["nodes"][node_id]
    execution = node["metadata"].get("execution", {})
    return (
        execution.get("idempotent") is True
        and execution.get("reclaimable") is True
        and node["state"] in {"pending", "ready", "blocked"}
    )


def evaluate(model: Mapping[str, Any], capacity: Optional[int]) -> Dict[str, Any]:
    nodes = model["nodes"]
    candidates = sorted(
        (node for node in nodes.values() if node["kind"] in WORK_KINDS),
        key=lambda item: (-item["priority"], item["id"]),
    )
    selected: List[Dict[str, Any]] = []
    excluded: List[Dict[str, Any]] = []
    reserved: Dict[str, Dict[str, str]] = {kind: {} for kind in CLAIM_KINDS}

    reservation_nodes = {
        node_id for node_id in model["leases"]
        if live_lease(model, node_id) or not safely_reclaimable_stale_lease(model, node_id)
    }
    reservation_nodes.update(model["reconciliations"])
    reservation_nodes.update(
        node_id for node_id, node in nodes.items()
        if node["kind"] in WORK_KINDS and node["state"] == "active"
    )
    for node_id in sorted(reservation_nodes):
        if node_id in nodes:
            for kind, values in node_claims(model, node_id).items():
                for value in values:
                    reserved[kind].setdefault(value, node_id)

    for node in candidates:
        node_id = node["id"]
        reasons: List[Dict[str, Any]] = []
        if node["state"] == "blocked":
            reasons.append(reason("PAUSED_NODE"))
        elif node["state"] not in SCHEDULABLE_STATES:
            reasons.append(reason("STATE_UNSCHEDULABLE", state=node["state"]))
        paused_lanes = [lane for lane in model["assigned"][node_id] if model["paused"].get(lane, False)]
        if paused_lanes:
            reasons.append(reason("PAUSED_LANE", lanes=paused_lanes))
        if live_lease(model, node_id):
            lease = model["leases"][node_id]
            reasons.append(reason("LEASE_LIVE", leaseId=lease["leaseId"], fence=lease["fence"], expiresAt=lease["expiresAt"]))
        elif node_id in model["leases"] and not safely_reclaimable_stale_lease(model, node_id):
            reasons.append(reason("LEASE_STALE_UNSAFE", leaseId=model["leases"][node_id]["leaseId"]))
        if node_id in model["reconciliations"]:
            record = model["reconciliations"][node_id]
            reasons.append(reason("RECONCILIATION_REQUIRED", leaseId=record["leaseId"], fence=record["fence"], reason=record["reason"]))

        missing: List[str] = []
        failed: List[str] = []
        incomplete: List[str] = []
        for predecessor in model["dependencies"][node_id]:
            if predecessor not in nodes:
                missing.append(predecessor)
                continue
            predecessor_node = nodes[predecessor]
            predecessor_family = family(predecessor_node["kind"])
            if predecessor_node["state"] == SUCCESS[predecessor_family]:
                continue
            if predecessor_node["state"] in {"failed", "cancelled", "rejected"}:
                failed.append(predecessor)
            else:
                incomplete.append(predecessor)
        if missing:
            reasons.append(reason("DEPENDENCY_MISSING", dependencies=sorted(missing)))
        if failed:
            reasons.append(reason("DEPENDENCY_FAILED", dependencies=sorted(failed)))
        if incomplete:
            reasons.append(reason("DEPENDENCY_INCOMPLETE", dependencies=sorted(incomplete)))

        gate_edges = model["gates"][node_id]
        if node["kind"] == "integration" and not gate_edges:
            reasons.append(reason("GATE_MISSING"))
        upcoming_transitions = (
            {"ready", "active"} if node["state"] == "pending"
            else {"active"} if node["state"] == "ready"
            else set()
        )
        gate_ids = [
            edge["gateId"] for edge in gate_edges
            if upcoming_transitions.intersection(edge["protectedTransitions"])
        ]
        rejected_gates = [gate for gate in gate_ids if nodes[gate]["state"] in {"rejected", "cancelled"}]
        pending_gates = [gate for gate in gate_ids if nodes[gate]["state"] not in {"approved", "rejected", "cancelled"}]
        if rejected_gates:
            reasons.append(reason("GATE_REJECTED", gates=rejected_gates))
        if pending_gates:
            reasons.append(reason("GATE_PENDING", gates=pending_gates))

        claims = node_claims(model, node_id)
        if not model["assigned"][node_id]:
            reasons.append(reason("ASSIGNMENT_MISSING"))
        if not reasons:
            for kind in CLAIM_KINDS:
                collisions = [
                    {"claim": value, "withNode": reserved[kind][value]}
                    for value in claims[kind] if value in reserved[kind]
                ]
                if collisions:
                    reasons.append(reason(f"CONFLICT_{kind[:-1].upper() if kind.endswith('s') else kind.upper()}", collisions=collisions))
            if not reasons and capacity is not None and len(selected) >= capacity:
                reasons.append(reason("CAPACITY_EXHAUSTED", capacity=capacity))

        if reasons:
            excluded.append({"nodeId": node_id, "reasons": reasons})
            continue
        selected.append({
            "nodeId": node_id, "kind": node["kind"], "title": node["title"],
            "priority": node["priority"], "claims": claims,
        })
        for kind, values in claims.items():
            for value in values:
                reserved[kind][value] = node_id

    return {"runnable": selected, "excluded": excluded}


def frontier_payload(model: Mapping[str, Any], result: Mapping[str, Any], capacity: Optional[int], explain: bool) -> Dict[str, Any]:
    snapshot = model["snapshot"]
    data: Dict[str, Any] = {
        "schemaVersion": FRONTIER_VERSION,
        "graphId": snapshot["graphId"],
        "revision": snapshot["revision"],
        "definitionRevision": snapshot["definitionRevision"],
        "snapshotUpdatedAt": snapshot["updatedAt"],
        "trustedClock": model["trustedClock"],
        "capacity": capacity,
        "runnable": result["runnable"],
    }
    if explain:
        data["excluded"] = result["excluded"]
    return {"ok": True, "command": "frontier", "data": data}


def status_payload(model: Mapping[str, Any], result: Mapping[str, Any], capacity: Optional[int]) -> Dict[str, Any]:
    snapshot = model["snapshot"]
    counts = Counter(entry["code"] for item in result["excluded"] for entry in item["reasons"])
    data = {
        "schemaVersion": STATUS_VERSION,
        "graphId": snapshot["graphId"],
        "revision": snapshot["revision"],
        "definitionRevision": snapshot["definitionRevision"],
        "snapshotUpdatedAt": snapshot["updatedAt"],
        "trustedClock": model["trustedClock"],
        "capacity": capacity,
        "nodeCount": len(model["nodes"]),
        "workNodeCount": sum(node["kind"] in WORK_KINDS for node in model["nodes"].values()),
        "runnableCount": len(result["runnable"]),
        "excludedCount": len(result["excluded"]),
        "liveLeaseCount": sum(live_lease(model, node_id) for node_id in model["leases"]),
        "staleLeaseCount": sum(not live_lease(model, node_id) for node_id in model["leases"]),
        "reasonCounts": dict(sorted(counts.items())),
    }
    return {"ok": True, "command": "status", "data": data}


def print_frontier_text(payload: Mapping[str, Any], explain: bool) -> None:
    data = payload["data"]
    print(f"Runnable frontier for {data['graphId']} at revision {data['revision']}")
    if data["runnable"]:
        for item in data["runnable"]:
            print(f"- {item['nodeId']} (priority {item['priority']}, {item['kind']})")
    else:
        print("No runnable nodes.")
    if explain:
        print("Exclusions:")
        if not data["excluded"]:
            print("- none")
        for item in data["excluded"]:
            print(f"- {item['nodeId']}: {','.join(entry['code'] for entry in item['reasons'])}")


def print_status_text(payload: Mapping[str, Any]) -> None:
    data = payload["data"]
    print(f"Scheduler status for {data['graphId']} at revision {data['revision']}")
    print(f"Nodes: {data['nodeCount']} ({data['workNodeCount']} work)")
    print(f"Runnable: {data['runnableCount']}")
    print(f"Excluded: {data['excludedCount']}")
    print(f"Leases: {data['liveLeaseCount']} live, {data['staleLeaseCount']} stale")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="operator-scheduler")
    sub = root.add_subparsers(dest="command", required=True)
    for command in ("frontier", "status"):
        current = sub.add_parser(command)
        current.add_argument("--snapshot", default="-", metavar="FILE", help="trusted control snapshot or public graph CLI envelope; default: stdin")
        current.add_argument("--clock", metavar="FILE", help="trusted operator.scheduler-clock/v1 evidence from the host boundary")
        current.add_argument("--graph", metavar="ID", help="require this graph ID")
        current.add_argument("--json", action="store_true", help="emit stable JSON")
        current.add_argument("--capacity", type=int, metavar="N", help="maximum number of newly selected nodes")
        if command == "frontier":
            current.add_argument("--explain", action="store_true", help="include stable exclusion reasons")
    return root


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        args = parser().parse_args(argv)
        if args.capacity is not None and not 0 <= args.capacity <= 10000:
            raise SchedulerError("USAGE", "--capacity must be between 0 and 10000", exit_code=2)
        if args.snapshot == "-" and args.clock == "-":
            raise SchedulerError("USAGE", "--snapshot and --clock cannot both read stdin", exit_code=2)
        snapshot = read_input(args.snapshot)
        model = validate_snapshot(snapshot)
        if args.graph is not None and args.graph != snapshot["graphId"]:
            raise SchedulerError("GRAPH_MISMATCH", "snapshot graphId does not match --graph", {
                "expected": args.graph, "actual": snapshot["graphId"],
            })
        bind_trusted_clock(model, read_clock(args.clock))
        result = evaluate(model, args.capacity)
        if args.command == "frontier":
            payload = frontier_payload(model, result, args.capacity, args.explain)
            if args.json:
                print(json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
            else:
                print_frontier_text(payload, args.explain)
        else:
            payload = status_payload(model, result, args.capacity)
            if args.json:
                print(json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
            else:
                print_status_text(payload)
        return 0
    except SchedulerError as exc:
        error: Dict[str, Any] = {"ok": False, "error": {"code": exc.code, "message": exc.message}}
        if exc.details is not None:
            error["error"]["details"] = exc.details
        print(json.dumps(error, sort_keys=True, separators=(",", ":"), ensure_ascii=False), file=sys.stderr)
        return exc.exit_code
    except (AttributeError, IndexError, KeyError, OverflowError, RecursionError, TypeError, ValueError):
        error = {"ok": False, "error": {"code": "INVALID_SNAPSHOT", "message": "snapshot validation failed closed"}}
        print(json.dumps(error, sort_keys=True, separators=(",", ":"), ensure_ascii=False), file=sys.stderr)
        return 5
    except BrokenPipeError:
        return 0


raise SystemExit(main())
PY

exec python3 -c "$OPERATOR_SCHEDULER_PROGRAM" "$@"
