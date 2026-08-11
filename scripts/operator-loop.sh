#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${OPERATOR_DIR:-}" ]; then
  # shellcheck source=scripts/operator-lib.sh
  if ! source "$SCRIPT_DIR/operator-lib.sh" >/dev/null 2>&1 || ! operator_load_config >/dev/null 2>&1; then
    printf '%s\n' '{"error":{"code":"USAGE","message":"OPERATOR_DIR is required and project configuration could not be loaded"},"ok":false}' >&2
    exit 2
  fi
fi

export OPERATOR_LOOP_SCRIPT_DIR="$SCRIPT_DIR"

IFS= read -r -d '' OPERATOR_LOOP_PROGRAM <<'PY' || true
from __future__ import annotations

import argparse
import base64
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from typing import Any, Dict, Iterator, List, Mapping, Optional, Sequence, Tuple


LOOP_STATUS_VERSION = "operator.loop-status/v1"
LOOP_TICK_VERSION = "operator.loop-tick/v1"
LOOP_STATE_VERSION = "operator.loop-state/v1"
LOOP_LEASE_VERSION = "operator.loop-lease/v1"
LOOP_EVENT_VERSION = "operator.loop-event/v1"
MUTATION_REQUEST_VERSION = "operator.loop-mutation-request/v1"
RUN_REQUEST_VERSION = "operator.runner-request/v1"
RUN_RESULT_VERSION = "operator.runner-result/v1"
SNAPSHOT_VERSION = "operator.control-snapshot/v1"
CLOCK_VERSION = "operator.scheduler-clock/v1"
FRONTIER_VERSION = "operator.scheduler-frontier/v1"
SCHEDULER_STATUS_VERSION = "operator.scheduler-status/v1"
MAX_INTERFACE_BYTES = 8 * 1024 * 1024
MAX_RUNNER_BYTES = 1024 * 1024
MAX_JSON_DEPTH = 40
MAX_JSON_ITEMS = 200000
MAX_COUNTER = (1 << 63) - 1
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+\-]*$")
BINDING_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]*$")
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
WORK_KINDS = {"task", "validation", "integration", "feedback"}
CLAIM_KINDS = ("files", "contracts", "resources", "lanes")
LIMITS: Dict[str, int] = {}


class LoopError(Exception):
    def __init__(self, code: str, message: str, details: Any = None, exit_code: int = 5):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details
        self.exit_code = exit_code


class MutationError(LoopError):
    pass


class JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise LoopError("USAGE", message, exit_code=2)


def fail(condition: bool, code: str, message: str, details: Any = None, exit_code: int = 5) -> None:
    if not condition:
        raise LoopError(code, message, details, exit_code)


def reject_float(raw: str) -> None:
    raise ValueError(f"floating-point JSON number is not canonical: {raw}")


def parse_integer(raw: str) -> int:
    if raw == "-0":
        raise ValueError("negative zero is not a canonical JSON integer")
    return int(raw)


def strict_pairs(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    value: Dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate object key: {key}")
        value[key] = item
    return value


def validate_json_domain(root: Any) -> None:
    stack: List[Tuple[Any, int]] = [(root, 1)]
    items = 0
    while stack:
        value, depth = stack.pop()
        if depth > MAX_JSON_DEPTH:
            raise ValueError("JSON exceeds maximum depth")
        items += 1
        if items > MAX_JSON_ITEMS:
            raise ValueError("JSON exceeds maximum item count")
        if isinstance(value, str):
            if any(ord(ch) < 32 or 127 <= ord(ch) <= 159 or 0xD800 <= ord(ch) <= 0xDFFF for ch in value):
                raise ValueError("JSON contains a non-canonical string")
        elif isinstance(value, dict):
            for key, item in value.items():
                if not isinstance(key, str):
                    raise ValueError("JSON object key is not a string")
                stack.extend(((key, depth + 1), (item, depth + 1)))
        elif isinstance(value, list):
            stack.extend((item, depth + 1) for item in value)
        elif value is not None and not isinstance(value, (bool, int)):
            raise ValueError("JSON contains a non-canonical value")


def loads(raw: bytes, label: str, maximum: int = MAX_INTERFACE_BYTES) -> Any:
    if len(raw) > maximum:
        raise LoopError("INTERFACE_PROTOCOL", f"{label} exceeds {maximum} bytes")
    try:
        value = json.loads(
            raw.decode("utf-8"), parse_float=reject_float, parse_int=parse_integer,
            parse_constant=reject_float, object_pairs_hook=strict_pairs,
        )
        validate_json_domain(value)
        return value
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise LoopError("INTERFACE_PROTOCOL", f"{label} is not canonical JSON", str(exc)) from exc


def canonical(value: Any) -> bytes:
    validate_json_domain(value)
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def exact(value: Any, fields: set[str], label: str) -> Mapping[str, Any]:
    fail(isinstance(value, dict), "INTERFACE_PROTOCOL", f"{label} must be an object")
    actual = set(value)
    fail(actual == fields, "INTERFACE_PROTOCOL", f"{label} fields are invalid", {
        "missing": sorted(fields - actual), "unknown": sorted(actual - fields),
    })
    return value


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def integer(value: Any, minimum: int = 0, maximum: Optional[int] = None) -> bool:
    return (isinstance(value, int) and not isinstance(value, bool) and value >= minimum
            and (maximum is None or value <= maximum))


def text_value(value: Any, maximum: int, pattern: Optional[re.Pattern[str]] = None) -> bool:
    return (isinstance(value, str) and 1 <= len(value) <= maximum and bool(value.strip())
            and (pattern is None or pattern.fullmatch(value) is not None))


def canonical_timestamp(value: Any) -> Optional[dt.datetime]:
    if not isinstance(value, str) or len(value) > 64 or not value.endswith("Z"):
        return None
    try:
        parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00")
    except (ValueError, OverflowError):
        return None
    if parsed.tzinfo is None:
        return None
    normalized = parsed.astimezone(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
    return parsed.astimezone(dt.timezone.utc) if normalized == value else None


def env_integer(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = parse_integer(raw)
    except ValueError as exc:
        raise LoopError("USAGE", f"{name} must be an integer", exit_code=2) from exc
    fail(minimum <= value <= maximum, "USAGE", f"{name} must be between {minimum} and {maximum}", exit_code=2)
    return value


def configure_limits() -> None:
    LIMITS.clear()
    LIMITS.update({
        "interfaceTimeout": env_integer("OPERATOR_LOOP_INTERFACE_TIMEOUT_SECONDS", 30, 1, 300),
        "schedulerTimeout": env_integer("OPERATOR_LOOP_SCHEDULER_TIMEOUT_SECONDS", 30, 1, 300),
        "runnerTimeout": env_integer("OPERATOR_LOOP_RUN_TIMEOUT_SECONDS", 3600, 1, 86400),
        "heartbeat": env_integer("OPERATOR_LOOP_HEARTBEAT_SECONDS", 30, 1, 28800),
    })


def command_path(variable: str, required: bool = True) -> Optional[str]:
    raw = os.environ.get(variable)
    if not raw:
        if required:
            raise LoopError("TRUSTED_INTERFACE_UNAVAILABLE", f"{variable} is not configured", exit_code=3)
        return None
    path = Path(raw)
    fail(path.is_absolute(), "TRUSTED_INTERFACE_UNAVAILABLE", f"{variable} must be an absolute executable path", exit_code=3)
    fail(path.is_file() and os.access(path, os.X_OK), "TRUSTED_INTERFACE_UNAVAILABLE",
         f"{variable} is not an executable file", exit_code=3)
    return str(path)


def child_process_group(process: subprocess.Popen[Any], label: str) -> int:
    try:
        process_group = os.getpgid(process.pid)
    except OSError as exc:
        with contextlib.suppress(OSError):
            process.kill()
        with contextlib.suppress(subprocess.TimeoutExpired):
            process.wait(timeout=2)
        raise LoopError("TRUSTED_INTERFACE_UNAVAILABLE", f"{label} process group is unavailable", str(exc), 3) from exc
    if process_group != process.pid or process_group == os.getpgrp():
        with contextlib.suppress(OSError):
            process.kill()
        with contextlib.suppress(subprocess.TimeoutExpired):
            process.wait(timeout=2)
        raise LoopError("TRUSTED_INTERFACE_UNAVAILABLE", f"{label} did not enter a contained process group", exit_code=3)
    return process_group


def process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
        return True
    except PermissionError:
        return True
    except ProcessLookupError:
        return False


def terminate_process_group(process: subprocess.Popen[Any], process_group: int) -> None:
    fail(process_group == process.pid and process_group != os.getpgrp(), "IO_ERROR",
         "refusing to terminate an uncontained process group", exit_code=3)
    with contextlib.suppress(OSError):
        os.killpg(process_group, signal.SIGTERM)
    deadline = time.monotonic() + 0.5
    while time.monotonic() < deadline:
        process.poll()
        if not process_group_exists(process_group):
            break
        time.sleep(0.02)
    process.poll()
    if process_group_exists(process_group):
        with contextlib.suppress(OSError):
            os.killpg(process_group, signal.SIGKILL)
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(OSError):
            process.kill()
        with contextlib.suppress(subprocess.TimeoutExpired):
            process.wait(timeout=2)


def bounded_process(argv: Sequence[str], input_bytes: Optional[bytes], label: str, timeout: int,
                    stdout_limit: int, stderr_limit: int,
                    environment: Optional[Mapping[str, str]] = None) -> Tuple[int, bytes, bytes]:
    with tempfile.TemporaryFile() as stdin_file, tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
        if input_bytes is not None:
            stdin_file.write(input_bytes)
        stdin_file.seek(0)
        try:
            process = subprocess.Popen(
                list(argv), stdin=stdin_file, stdout=stdout_file, stderr=stderr_file,
                env=None if environment is None else dict(environment), start_new_session=True,
            )
            process_group = child_process_group(process, label)
        except OSError as exc:
            raise LoopError("TRUSTED_INTERFACE_UNAVAILABLE", f"{label} could not be invoked", str(exc), 3) from exc
        deadline = time.monotonic() + timeout
        while process.poll() is None:
            out_size = os.fstat(stdout_file.fileno()).st_size
            err_size = os.fstat(stderr_file.fileno()).st_size
            if out_size > stdout_limit or err_size > stderr_limit:
                terminate_process_group(process, process_group)
                raise LoopError("INTERFACE_LIMIT", f"{label} exceeded its output bound", {
                    "stdoutLimit": stdout_limit, "stderrLimit": stderr_limit,
                }, 4)
            if time.monotonic() >= deadline:
                terminate_process_group(process, process_group)
                raise LoopError("INTERFACE_TIMEOUT", f"{label} exceeded its time bound", {"timeoutSeconds": timeout}, 4)
            time.sleep(0.02)
        out_size = os.fstat(stdout_file.fileno()).st_size
        err_size = os.fstat(stderr_file.fileno()).st_size
        if out_size > stdout_limit or err_size > stderr_limit:
            raise LoopError("INTERFACE_LIMIT", f"{label} exceeded its output bound", {
                "stdoutLimit": stdout_limit, "stderrLimit": stderr_limit,
            }, 4)
        stdout_file.seek(0)
        stderr_file.seek(0)
        return process.returncode, stdout_file.read(stdout_limit + 1), stderr_file.read(stderr_limit + 1)


def run_command(path: str, payload: Optional[Mapping[str, Any]], label: str,
                maximum: int = MAX_INTERFACE_BYTES, timeout: Optional[int] = None) -> bytes:
    result_code, result_stdout, result_stderr = bounded_process(
        [path], None if payload is None else canonical(payload), label,
        LIMITS["interfaceTimeout"] if timeout is None else timeout, maximum, maximum,
    )
    if result_code != 0:
        diagnostic: Any = None
        for raw in (result_stderr, result_stdout):
            if raw.strip():
                try:
                    diagnostic = loads(raw, f"{label} error", maximum)
                except LoopError:
                    diagnostic = raw.decode("utf-8", errors="replace")[:2048]
                break
        raise LoopError("TRUSTED_INTERFACE_FAILED", f"{label} exited with status {result_code}", diagnostic, 4)
    return result_stdout


def operator_dir() -> Path:
    raw = os.environ.get("OPERATOR_DIR")
    fail(bool(raw), "USAGE", "OPERATOR_DIR is required", exit_code=2)
    path = Path(os.path.abspath(str(raw)))
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise LoopError("IO_ERROR", "cannot inspect OPERATOR_DIR", str(exc), 3) from exc
    fail(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode), "IO_ERROR",
         "OPERATOR_DIR must be a real directory", str(path), 3)
    fail(info.st_uid == os.geteuid(), "IO_ERROR", "OPERATOR_DIR has unsafe ownership", str(path), 3)
    return path


def scheduler_path() -> str:
    override = os.environ.get("OPERATOR_LOOP_SCHEDULER")
    if override:
        fail(os.environ.get("OPERATOR_LOOP_TEST_MODE") == "1", "TRUSTED_INTERFACE_UNAVAILABLE",
             "scheduler override is permitted only in explicit test mode", exit_code=3)
        path = Path(override)
    else:
        path = Path(os.environ["OPERATOR_LOOP_SCRIPT_DIR"]) / "operator-scheduler.sh"
    fail(path.is_absolute() and path.is_file() and os.access(path, os.X_OK),
         "TRUSTED_INTERFACE_UNAVAILABLE", "scheduler runtime is unavailable", str(path), 3)
    return str(path)


def trusted_inputs() -> Tuple[bytes, bytes]:
    snapshot = run_command(command_path("OPERATOR_LOOP_SNAPSHOT_COMMAND") or "", None, "trusted snapshot provider")
    clock = run_command(command_path("OPERATOR_LOOP_CLOCK_COMMAND") or "", None, "trusted clock provider", maximum=4096)
    return snapshot, clock


def validate_clock(clock: Any, label: str) -> Mapping[str, Any]:
    exact(clock, {"schemaVersion", "hostId", "bootId", "monotonicSource", "monotonicNs"}, label)
    fail(clock.get("schemaVersion") == CLOCK_VERSION, "INTERFACE_PROTOCOL", f"{label} has the wrong version")
    fail(text_value(clock.get("hostId"), 256) and text_value(clock.get("bootId"), 256),
         "INTERFACE_PROTOCOL", f"{label} identity is invalid")
    fail(clock.get("monotonicSource") in {"linux-proc-uptime", "macos-mach-continuous"},
         "INTERFACE_PROTOCOL", f"{label} source is invalid")
    fail(integer(clock.get("monotonicNs")), "INTERFACE_PROTOCOL", f"{label} value is invalid")
    return clock


def snapshot_node_index(snapshot: Mapping[str, Any]) -> Dict[str, Mapping[str, Any]]:
    nodes = snapshot.get("nodes")
    fail(isinstance(nodes, list), "INTERFACE_PROTOCOL", "trusted snapshot nodes must be an array")
    result: Dict[str, Mapping[str, Any]] = {}
    for node in nodes:
        fail(isinstance(node, dict) and isinstance(node.get("id"), str),
             "INTERFACE_PROTOCOL", "trusted snapshot node is invalid")
        fail(node["id"] not in result, "INTERFACE_PROTOCOL", "trusted snapshot node IDs are duplicated")
        result[node["id"]] = node
    return result


def expected_claims(snapshot: Mapping[str, Any], node: Mapping[str, Any]) -> Dict[str, List[str]]:
    claims: Dict[str, List[str]] = {kind: [] for kind in CLAIM_KINDS}
    metadata = node.get("metadata", {})
    scheduler = metadata.get("scheduler", {}) if isinstance(metadata, dict) else {}
    raw = scheduler.get("claims", {}) if isinstance(scheduler, dict) else {}
    if isinstance(raw, dict):
        for kind in CLAIM_KINDS:
            values = raw.get(kind, [])
            if isinstance(values, list):
                claims[kind].extend(values)
    edges = snapshot.get("edges", [])
    if isinstance(edges, list):
        claims["lanes"].extend(
            edge["to"] for edge in edges
            if isinstance(edge, dict) and edge.get("kind") == "assigned-to" and edge.get("from") == node.get("id")
            and isinstance(edge.get("to"), str)
        )
    return {kind: sorted(set(values)) for kind, values in claims.items()}


REASON_DETAILS = {
    "STATE_UNSCHEDULABLE": {"state"}, "ASSIGNMENT_MISSING": set(),
    "DEPENDENCY_INCOMPLETE": {"dependencies"}, "DEPENDENCY_FAILED": {"dependencies"},
    "DEPENDENCY_MISSING": {"dependencies"}, "GATE_MISSING": set(),
    "GATE_PENDING": {"gates"}, "GATE_REJECTED": {"gates"},
    "LEASE_LIVE": {"leaseId", "fence", "expiresAt"}, "LEASE_STALE_UNSAFE": {"leaseId"},
    "RECONCILIATION_REQUIRED": {"leaseId", "fence", "reason"},
    "PAUSED_NODE": set(), "PAUSED_LANE": {"lanes"},
    "CONFLICT_FILE": {"collisions"}, "CONFLICT_CONTRACT": {"collisions"},
    "CONFLICT_RESOURCE": {"collisions"}, "CONFLICT_LANE": {"collisions"},
    "CAPACITY_EXHAUSTED": {"capacity"},
}


def validate_reasons(reasons: Any) -> None:
    fail(isinstance(reasons, list) and reasons, "INTERFACE_PROTOCOL", "scheduler exclusion reasons are invalid")
    for reason in reasons:
        fail(isinstance(reason, dict) and isinstance(reason.get("code"), str)
             and reason["code"] in REASON_DETAILS, "INTERFACE_PROTOCOL", "scheduler exclusion reason is unknown")
        detail_fields = REASON_DETAILS[reason["code"]]
        exact(reason, {"code"} if not detail_fields else {"code", "details"}, "scheduler exclusion reason")
        details = reason.get("details", {})
        exact(details, detail_fields, "scheduler exclusion reason details")
        for key in ("dependencies", "gates", "lanes"):
            if key in details:
                fail(isinstance(details[key], list) and all(isinstance(item, str) for item in details[key])
                     and details[key] == sorted(set(details[key])), "INTERFACE_PROTOCOL",
                     f"scheduler exclusion {key} are invalid")
        if "collisions" in details:
            fail(isinstance(details["collisions"], list), "INTERFACE_PROTOCOL", "scheduler collisions are invalid")
            for collision in details["collisions"]:
                exact(collision, {"claim", "withNode"}, "scheduler collision")
                fail(isinstance(collision.get("claim"), str) and isinstance(collision.get("withNode"), str),
                     "INTERFACE_PROTOCOL", "scheduler collision is invalid")


def validate_scheduler_data(command: str, data: Mapping[str, Any], snapshot: Mapping[str, Any],
                            clock: Mapping[str, Any], capacity: int) -> None:
    common = {"schemaVersion", "graphId", "revision", "definitionRevision", "snapshotUpdatedAt",
              "trustedClock", "capacity"}
    if command == "frontier":
        exact(data, common | {"runnable", "excluded"}, "scheduler frontier data")
    else:
        exact(data, common | {"nodeCount", "workNodeCount", "runnableCount", "excludedCount",
                             "liveLeaseCount", "staleLeaseCount", "reasonCounts"}, "scheduler status data")
    expected = FRONTIER_VERSION if command == "frontier" else SCHEDULER_STATUS_VERSION
    fail(data.get("schemaVersion") == expected, "INTERFACE_PROTOCOL", "scheduler result has the wrong version")
    fail(data.get("capacity") == capacity, "INTERFACE_PROTOCOL", "scheduler did not apply the explicit capacity")
    fail(data.get("graphId") == snapshot.get("graphId") and data.get("revision") == snapshot.get("revision")
         and data.get("definitionRevision") == snapshot.get("definitionRevision")
         and data.get("snapshotUpdatedAt") == snapshot.get("updatedAt"),
         "INTERFACE_PROTOCOL", "scheduler result does not bind the delivered snapshot")
    fail(data.get("trustedClock") == clock, "INTERFACE_PROTOCOL", "scheduler result does not echo the delivered clock")
    nodes = snapshot_node_index(snapshot)
    work_ids = {node_id for node_id, node in nodes.items() if node.get("kind") in WORK_KINDS}
    if command == "frontier":
        runnable = data.get("runnable")
        excluded = data.get("excluded")
        fail(isinstance(runnable, list) and isinstance(excluded, list), "INTERFACE_PROTOCOL",
             "scheduler candidate arrays are invalid")
        seen: set[str] = set()
        for candidate in runnable:
            exact(candidate, {"nodeId", "kind", "title", "priority", "claims"}, "scheduler runnable entry")
            node_id = candidate.get("nodeId")
            fail(isinstance(node_id, str) and node_id in work_ids and node_id not in seen,
                 "INTERFACE_PROTOCOL", "scheduler runnable candidate is missing, invented, or duplicated")
            seen.add(node_id)
            node = nodes[node_id]
            fail(candidate.get("kind") == node.get("kind") and candidate.get("title") == node.get("title")
                 and candidate.get("priority") == node.get("priority"),
                 "INTERFACE_PROTOCOL", "scheduler runnable immutable fields mismatch the snapshot")
            claims = candidate.get("claims")
            exact(claims, set(CLAIM_KINDS), "scheduler runnable claims")
            for kind in CLAIM_KINDS:
                fail(isinstance(claims[kind], list) and all(isinstance(item, str) for item in claims[kind])
                     and claims[kind] == sorted(set(claims[kind])), "INTERFACE_PROTOCOL",
                     f"scheduler runnable {kind} claims are invalid")
            fail(claims == expected_claims(snapshot, node), "INTERFACE_PROTOCOL",
                 "scheduler runnable claims mismatch the snapshot")
        for item in excluded:
            exact(item, {"nodeId", "reasons"}, "scheduler exclusion")
            node_id = item.get("nodeId")
            fail(isinstance(node_id, str) and node_id in work_ids and node_id not in seen,
                 "INTERFACE_PROTOCOL", "scheduler excluded candidate is missing, invented, or duplicated")
            seen.add(node_id)
            validate_reasons(item.get("reasons"))
        fail(seen == work_ids, "INTERFACE_PROTOCOL", "scheduler omitted work candidates")
    else:
        count_fields = ("nodeCount", "workNodeCount", "runnableCount", "excludedCount",
                        "liveLeaseCount", "staleLeaseCount")
        fail(all(integer(data.get(field)) for field in count_fields), "INTERFACE_PROTOCOL",
             "scheduler status counts are invalid")
        leases = snapshot.get("leases")
        fail(isinstance(leases, dict), "INTERFACE_PROTOCOL", "trusted snapshot leases are invalid")
        fail(data["nodeCount"] == len(nodes) and data["workNodeCount"] == len(work_ids)
             and data["runnableCount"] + data["excludedCount"] == len(work_ids)
             and data["liveLeaseCount"] + data["staleLeaseCount"] == len(leases),
             "INTERFACE_PROTOCOL", "scheduler status counts mismatch the snapshot")
        reasons = data.get("reasonCounts")
        fail(isinstance(reasons, dict) and all(code in REASON_DETAILS and integer(count)
             for code, count in reasons.items()), "INTERFACE_PROTOCOL", "scheduler status reasonCounts are invalid")


def scheduler_evaluate(command: str, capacity: int, explain: bool = False) -> Tuple[Mapping[str, Any], Mapping[str, Any], Mapping[str, Any]]:
    snapshot_raw, clock_raw = trusted_inputs()
    snapshot_value = loads(snapshot_raw, "trusted snapshot")
    if isinstance(snapshot_value, dict) and snapshot_value.get("ok") is True:
        exact(snapshot_value, {"ok", "command", "data"}, "trusted graph snapshot envelope")
        fail(snapshot_value.get("command") in {"status", "snapshot"}, "INTERFACE_PROTOCOL", "trusted snapshot command is invalid")
        snapshot = snapshot_value.get("data")
    else:
        snapshot = snapshot_value
    fail(isinstance(snapshot, dict) and snapshot.get("schemaVersion") == SNAPSHOT_VERSION,
         "INTERFACE_PROTOCOL", "trusted snapshot has the wrong version")
    clock = validate_clock(loads(clock_raw, "trusted scheduler clock", 4096), "trusted scheduler clock")

    with tempfile.TemporaryDirectory(prefix="operator-loop-scheduler-") as temporary:
        snapshot_path = Path(temporary) / "snapshot.json"
        clock_path = Path(temporary) / "clock.json"
        snapshot_path.write_bytes(snapshot_raw)
        clock_path.write_bytes(clock_raw)
        argv = [scheduler_path(), command, "--snapshot", str(snapshot_path), "--clock", str(clock_path),
                "--capacity", str(capacity), "--json"]
        if command == "frontier" and explain:
            argv.append("--explain")
        result_code, result_stdout, result_stderr = bounded_process(
            argv, None, "scheduler", LIMITS["schedulerTimeout"], MAX_INTERFACE_BYTES, MAX_INTERFACE_BYTES,
        )
    if result_code != 0:
        diagnostic = loads(result_stderr, "scheduler error") if result_stderr.strip() else None
        code = "SCHEDULER_REJECTED"
        if isinstance(diagnostic, dict) and isinstance(diagnostic.get("error"), dict):
            code = str(diagnostic["error"].get("code", code))
        raise LoopError(code, "scheduler failed closed", diagnostic, 4)
    payload = loads(result_stdout, "scheduler result")
    exact(payload, {"ok", "command", "data"}, "scheduler result")
    fail(payload.get("ok") is True and payload.get("command") == command,
         "INTERFACE_PROTOCOL", "scheduler result envelope is invalid")
    data = payload.get("data")
    fail(isinstance(data, dict), "INTERFACE_PROTOCOL", "scheduler result data must be an object")
    validate_scheduler_data(command, data, snapshot, clock, capacity)
    return snapshot, clock, data


class LoopStore:
    def __init__(self, root: Path, create: bool):
        self.root = root
        self.create = create
        self.root_fd: Optional[int] = None
        self.graph_fd: Optional[int] = None
        self.loop_fd: Optional[int] = None

    def __enter__(self) -> "LoopStore":
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        try:
            self.root_fd = os.open(self.root, flags)
            root_info = os.fstat(self.root_fd)
            self._require_owned_directory(root_info, "OPERATOR_DIR")
            try:
                self.graph_fd = os.open("graph", flags, dir_fd=self.root_fd)
                self._require_owned_directory(os.fstat(self.graph_fd), "graph directory")
            except FileNotFoundError:
                self.graph_fd = None
            try:
                self.loop_fd = os.open("loop", flags, dir_fd=self.root_fd)
            except FileNotFoundError:
                if not self.create:
                    return self
                try:
                    os.mkdir("loop", mode=0o700, dir_fd=self.root_fd)
                except FileExistsError:
                    pass
                self.loop_fd = os.open("loop", flags, dir_fd=self.root_fd)
            self._require_owned_directory(os.fstat(self.loop_fd), "loop directory", private=True)
            return self
        except LoopError:
            self.close()
            raise
        except OSError as exc:
            self.close()
            raise LoopError("IO_ERROR", "cannot open contained loop state", str(exc), 3) from exc

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        self.close()

    def close(self) -> None:
        for descriptor_name in ("loop_fd", "graph_fd", "root_fd"):
            descriptor = getattr(self, descriptor_name)
            if descriptor is not None:
                with contextlib.suppress(OSError):
                    os.close(descriptor)
                setattr(self, descriptor_name, None)

    @staticmethod
    def _require_owned_directory(info: os.stat_result, label: str, private: bool = False) -> None:
        fail(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(), "IO_ERROR",
             f"{label} must be an owned real directory", exit_code=3)
        if private:
            fail(stat.S_IMODE(info.st_mode) == 0o700, "IO_ERROR",
                 f"{label} must have mode 0700", exit_code=3)

    @staticmethod
    def _require_owned_regular(info: os.stat_result, label: str) -> None:
        fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid(), "IO_ERROR",
             f"{label} must be an owned regular file", exit_code=3)

    def _stat_optional(self, name: str, label: str) -> Optional[os.stat_result]:
        if self.loop_fd is None:
            return None
        try:
            info = os.stat(name, dir_fd=self.loop_fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise LoopError("IO_ERROR", f"cannot inspect {label}", str(exc), 3) from exc
        self._require_owned_regular(info, label)
        return info

    def read_json(self, name: str, label: str) -> Optional[Mapping[str, Any]]:
        expected = self._stat_optional(name, label)
        if expected is None:
            return None
        assert self.loop_fd is not None
        try:
            descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.loop_fd)
            try:
                actual = os.fstat(descriptor)
                self._require_owned_regular(actual, label)
                fail((actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino), "IO_ERROR",
                     f"{label} changed during open", exit_code=3)
                if stat.S_IMODE(actual.st_mode) != 0o600:
                    os.fchmod(descriptor, 0o600)
                    os.fsync(descriptor)
                chunks: List[bytes] = []
                total = 0
                while True:
                    chunk = os.read(descriptor, min(65536, MAX_INTERFACE_BYTES + 1 - total))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    total += len(chunk)
                    fail(total <= MAX_INTERFACE_BYTES, "IO_ERROR", f"{label} exceeds its file bound", exit_code=3)
                raw = b"".join(chunks)
            finally:
                os.close(descriptor)
        except OSError as exc:
            raise LoopError("IO_ERROR", f"cannot read {label}", str(exc), 3) from exc
        value = loads(raw, label)
        fail(isinstance(value, dict), "LOOP_STATE_CORRUPT", f"{label} must be an object")
        return value

    def write_json(self, name: str, value: Mapping[str, Any], label: str) -> None:
        fail(self.loop_fd is not None, "IO_ERROR", "loop directory is unavailable", exit_code=3)
        self._stat_optional(name, label)
        assert self.loop_fd is not None
        temporary = f".{name}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
        descriptor: Optional[int] = None
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=self.loop_fd)
            encoded = canonical(value)
            offset = 0
            while offset < len(encoded):
                written = os.write(descriptor, encoded[offset:])
                if written <= 0:
                    raise OSError("short write")
                offset += written
            os.fsync(descriptor)
            os.close(descriptor)
            descriptor = None
            self._stat_optional(name, label)
            os.replace(temporary, name, src_dir_fd=self.loop_fd, dst_dir_fd=self.loop_fd)
            os.fsync(self.loop_fd)
        except OSError as exc:
            raise LoopError("IO_ERROR", f"cannot write {label}", str(exc), 3) from exc
        finally:
            if descriptor is not None:
                with contextlib.suppress(OSError):
                    os.close(descriptor)
            with contextlib.suppress(FileNotFoundError, OSError):
                os.unlink(temporary, dir_fd=self.loop_fd)

    def append_json(self, name: str, value: Mapping[str, Any], label: str) -> None:
        fail(self.loop_fd is not None, "IO_ERROR", "loop directory is unavailable", exit_code=3)
        expected = self._stat_optional(name, label)
        assert self.loop_fd is not None
        try:
            descriptor = os.open(name, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW,
                                 0o600, dir_fd=self.loop_fd)
            try:
                actual = os.fstat(descriptor)
                self._require_owned_regular(actual, label)
                if expected is not None:
                    fail((actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino), "IO_ERROR",
                         f"{label} changed during append open", exit_code=3)
                if stat.S_IMODE(actual.st_mode) != 0o600:
                    os.fchmod(descriptor, 0o600)
                    os.fsync(descriptor)
                encoded = canonical(value)
                offset = 0
                while offset < len(encoded):
                    written = os.write(descriptor, encoded[offset:])
                    if written <= 0:
                        raise OSError("short append")
                    offset += written
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        except OSError as exc:
            raise LoopError("IO_ERROR", f"cannot append {label}", str(exc), 3) from exc

    def unlink(self, name: str, label: str) -> None:
        info = self._stat_optional(name, label)
        if info is None:
            return
        assert self.loop_fd is not None
        try:
            current = os.stat(name, dir_fd=self.loop_fd, follow_symlinks=False)
            self._require_owned_regular(current, label)
            fail((current.st_dev, current.st_ino) == (info.st_dev, info.st_ino), "IO_ERROR",
                 f"{label} changed before unlink", exit_code=3)
            os.unlink(name, dir_fd=self.loop_fd)
            os.fsync(self.loop_fd)
        except OSError as exc:
            raise LoopError("IO_ERROR", f"cannot unlink {label}", str(exc), 3) from exc


@contextlib.contextmanager
def exclusive_lock(root: Path, kind: str, blocking: bool) -> Iterator[None]:
    with LoopStore(root, create=kind == "state") as store:
        # The trusted host holds an exclusive capability lock on OPERATOR_DIR
        # while it supervises a tick. Re-locking that directory from the
        # launchd-contained child self-deadlocks on macOS. A real V5 graph is
        # always present, so use its directory as the independent singleton
        # tick boundary. The root fallback preserves the standalone harness
        # and pre-initialization fail-closed behavior without creating state.
        descriptor = (store.graph_fd or store.root_fd) if kind == "tick" else store.loop_fd
        fail(descriptor is not None, "IO_ERROR", "lock directory is unavailable", exit_code=3)
        flags = fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB)
        try:
            fcntl.flock(descriptor, flags)
        except BlockingIOError as exc:
            raise LoopError("LOOP_BUSY", "another loop tick owns the singleton lease", exit_code=6) from exc
        except OSError as exc:
            raise LoopError("IO_ERROR", "cannot acquire loop lock", str(exc), 3) from exc
        try:
            yield
        finally:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            except OSError as exc:
                raise LoopError("IO_ERROR", "cannot release loop lock", str(exc), 3) from exc


def read_state(root: Path) -> Dict[str, Any]:
    with LoopStore(root, create=False) as store:
        value = store.read_json("state.json", "loop state")
    if value is None:
        return {"schemaVersion": LOOP_STATE_VERSION, "paused": False, "reason": None, "generation": 0, "updatedAt": None}
    exact(value, {"schemaVersion", "paused", "reason", "generation", "updatedAt"}, "loop state")
    fail(value.get("schemaVersion") == LOOP_STATE_VERSION and isinstance(value.get("paused"), bool),
         "LOOP_STATE_CORRUPT", "loop state version or pause flag is invalid")
    fail(value.get("reason") is None or isinstance(value.get("reason"), str), "LOOP_STATE_CORRUPT", "loop pause reason is invalid")
    fail(isinstance(value.get("generation"), int) and not isinstance(value.get("generation"), bool)
         and value["generation"] >= 0, "LOOP_STATE_CORRUPT", "loop state generation is invalid")
    fail(value.get("updatedAt") is None or isinstance(value.get("updatedAt"), str), "LOOP_STATE_CORRUPT", "loop updatedAt is invalid")
    return dict(value)


def read_tick_lease(root: Path) -> Optional[Dict[str, Any]]:
    with LoopStore(root, create=False) as store:
        value = store.read_json("lease.json", "loop lease")
    if value is None:
        return None
    exact(value, {"schemaVersion", "tickId", "pid", "startedAt", "renewedAt", "maxActions", "clock", "claim"}, "loop lease")
    fail(value.get("schemaVersion") == LOOP_LEASE_VERSION, "LOOP_STATE_CORRUPT", "loop lease has the wrong version")
    fail(isinstance(value.get("tickId"), str) and isinstance(value.get("pid"), int)
         and not isinstance(value.get("pid"), bool) and value["pid"] >= 1,
         "LOOP_STATE_CORRUPT", "loop lease identity is invalid")
    fail(isinstance(value.get("startedAt"), str) and isinstance(value.get("renewedAt"), str),
         "LOOP_STATE_CORRUPT", "loop lease timestamps are invalid")
    fail(isinstance(value.get("maxActions"), int) and not isinstance(value.get("maxActions"), bool)
         and 0 <= value["maxActions"] <= 10000, "LOOP_STATE_CORRUPT", "loop lease capacity is invalid")
    clock = value.get("clock")
    exact(clock, {"schemaVersion", "hostId", "bootId", "monotonicSource", "monotonicNs"}, "loop lease clock")
    fail(clock.get("schemaVersion") == CLOCK_VERSION, "LOOP_STATE_CORRUPT", "loop lease clock has the wrong version")
    claim = value.get("claim")
    if claim is not None:
        exact(claim, {"nodeId", "leaseId", "fence"}, "loop lease claim")
        fail(isinstance(claim.get("nodeId"), str) and isinstance(claim.get("leaseId"), str)
             and isinstance(claim.get("fence"), int) and not isinstance(claim.get("fence"), bool)
             and claim["fence"] >= 1, "LOOP_STATE_CORRUPT", "loop lease claim is invalid")
    return dict(value)


def write_tick_lease(root: Path, tick_id: str, clock: Mapping[str, Any], max_actions: int,
                     started_at: str, claim: Optional[Mapping[str, Any]] = None) -> None:
    value = {
        "schemaVersion": LOOP_LEASE_VERSION, "tickId": tick_id, "pid": os.getpid(),
        "startedAt": started_at, "renewedAt": utc_now(), "maxActions": max_actions,
        "clock": dict(clock), "claim": None if claim is None else dict(claim),
    }
    with LoopStore(root, create=True) as store:
        store.write_json("lease.json", value, "loop lease")


def clear_tick_lease(root: Path, tick_id: str) -> None:
    value = read_tick_lease(root)
    if value is not None and value.get("tickId") == tick_id:
        with LoopStore(root, create=False) as store:
            store.unlink("lease.json", "loop lease")


def append_event(root: Path, value: Mapping[str, Any]) -> None:
    with LoopStore(root, create=True) as store:
        store.append_json("events.jsonl", value, "loop event journal")


def mutation_error(raw: bytes, label: str, returncode: int) -> MutationError:
    try:
        payload = loads(raw, f"{label} error")
    except LoopError:
        return MutationError("MUTATION_INTERFACE_FAILED", f"{label} failed", {"returncode": returncode}, 4)
    if isinstance(payload, dict) and payload.get("ok") is False and isinstance(payload.get("error"), dict):
        error = payload["error"]
        code = error.get("code") if isinstance(error.get("code"), str) else "MUTATION_INTERFACE_FAILED"
        return MutationError(code, str(error.get("message", f"{label} failed")), error.get("details"), 4)
    return MutationError("MUTATION_INTERFACE_FAILED", f"{label} failed", payload, 4)


def validate_lease_shape(value: Any, node_id: str, lease_id: str) -> Tuple[Mapping[str, Any], Mapping[str, Any],
                                                                          Mapping[str, Any], dt.datetime,
                                                                          dt.datetime, dt.datetime]:
    lease = exact(value, {"schemaVersion", "nodeId", "leaseId", "holder", "acquiredAt", "renewedAt",
                          "expiresAt", "fence", "clock"}, "mutation lease")
    fail(lease.get("schemaVersion") == "operator.ownership-lease/v1", "MUTATION_INTERFACE_PROTOCOL",
         "mutation lease has the wrong version")
    fail(lease.get("nodeId") == node_id and lease.get("leaseId") == lease_id,
         "MUTATION_INTERFACE_PROTOCOL", "mutation lease identity mismatch")
    fail(integer(lease.get("fence"), 1, MAX_COUNTER), "MUTATION_INTERFACE_PROTOCOL",
         "mutation lease fence is invalid")
    acquired = canonical_timestamp(lease.get("acquiredAt"))
    renewed = canonical_timestamp(lease.get("renewedAt"))
    expires = canonical_timestamp(lease.get("expiresAt"))
    fail(acquired is not None and renewed is not None and expires is not None and acquired <= renewed < expires,
         "MUTATION_INTERFACE_PROTOCOL", "mutation lease timestamps are invalid or noncanonical")
    holder = exact(lease.get("holder"), {"actorType", "actorId", "bindingId", "bindingGeneration",
                                         "bindingHash", "scope", "laneNodeId"}, "mutation lease holder")
    fail(holder.get("actorType") in {"lane", "host"}
         and text_value(holder.get("actorId"), 256, ID_RE)
         and text_value(holder.get("bindingId"), 128, BINDING_ID_RE)
         and integer(holder.get("bindingGeneration"), 1, MAX_COUNTER)
         and isinstance(holder.get("bindingHash"), str) and HASH_RE.fullmatch(holder["bindingHash"]) is not None
         and text_value(holder.get("scope"), 512, ID_RE)
         and text_value(holder.get("laneNodeId"), 128, ID_RE),
         "MUTATION_INTERFACE_PROTOCOL", "mutation lease holder is invalid")
    clock = exact(lease.get("clock"), {"hostId", "bootId", "monotonicSource", "acquiredMonotonicNs",
                                       "expiresMonotonicNs"}, "mutation lease clock")
    fail(text_value(clock.get("hostId"), 256) and text_value(clock.get("bootId"), 256)
         and clock.get("monotonicSource") in {"linux-proc-uptime", "macos-mach-continuous"}
         and integer(clock.get("acquiredMonotonicNs"), 0, MAX_COUNTER)
         and integer(clock.get("expiresMonotonicNs"), 0, MAX_COUNTER)
         and clock["acquiredMonotonicNs"] < clock["expiresMonotonicNs"],
         "MUTATION_INTERFACE_PROTOCOL", "mutation lease clock is invalid")
    return lease, holder, clock, acquired, renewed, expires


def assigned_lanes(snapshot: Mapping[str, Any], node_id: str) -> set[str]:
    edges = snapshot.get("edges")
    fail(isinstance(edges, list), "MUTATION_INTERFACE_PROTOCOL", "pre-mutation snapshot edges are invalid")
    return {str(edge.get("to")) for edge in edges if isinstance(edge, dict)
            and edge.get("kind") == "assigned-to" and edge.get("from") == node_id
            and isinstance(edge.get("to"), str)}


def validate_public_lease(value: Any, action: str, node_id: str, lease_id: str,
                          snapshot: Mapping[str, Any], trusted_clock: Mapping[str, Any],
                          ttl_seconds: int, expected_fence: Optional[int] = None) -> Mapping[str, Any]:
    lease, holder, clock, acquired, renewed, expires = validate_lease_shape(value, node_id, lease_id)
    fail(holder["laneNodeId"] in assigned_lanes(snapshot, node_id), "MUTATION_INTERFACE_PROTOCOL",
         "mutation lease holder is not assigned to the node")
    fail(clock["hostId"] == trusted_clock.get("hostId") and clock["bootId"] == trusted_clock.get("bootId")
         and clock["monotonicSource"] == trusted_clock.get("monotonicSource"),
         "MUTATION_INTERFACE_PROTOCOL", "mutation lease clock epoch does not match trusted clock")
    fail(integer(ttl_seconds, 1, 86400), "MUTATION_INTERFACE_PROTOCOL", "mutation lease TTL is invalid")
    leases = snapshot.get("leases")
    fences = snapshot.get("leaseFences")
    fail(isinstance(leases, dict) and isinstance(fences, dict), "MUTATION_INTERFACE_PROTOCOL",
         "pre-mutation lease projection is invalid")
    tombstone = fences.get(node_id, 0)
    fail(integer(tombstone, 0, MAX_COUNTER - 1), "MUTATION_INTERFACE_PROTOCOL",
         "pre-mutation lease fence tombstone is invalid")
    if action == "acquire":
        prior = leases.get(node_id)
        fail(lease["fence"] == tombstone + 1 and acquired == renewed,
             "MUTATION_INTERFACE_PROTOCOL", "acquired lease fence or acquisition time is invalid")
        fail((expires - acquired) == dt.timedelta(seconds=ttl_seconds)
             and clock["expiresMonotonicNs"] - clock["acquiredMonotonicNs"] == ttl_seconds * 1_000_000_000,
             "MUTATION_INTERFACE_PROTOCOL", "acquired lease expiry does not match requested TTL")
        fail(clock["acquiredMonotonicNs"] >= trusted_clock.get("monotonicNs", MAX_COUNTER + 1),
             "MUTATION_INTERFACE_PROTOCOL", "acquired lease predates the trusted mutation clock")
        if prior is not None:
            fail(isinstance(prior, dict), "MUTATION_INTERFACE_PROTOCOL", "prior lease is invalid")
            prior_id = prior.get("leaseId")
            fail(isinstance(prior_id, str), "MUTATION_INTERFACE_PROTOCOL", "prior lease identity is invalid")
            prior_lease, _prior_holder, prior_clock, _prior_acquired, _prior_renewed, _prior_expires = \
                validate_lease_shape(prior, node_id, prior_id)
            node = snapshot_node_index(snapshot).get(node_id)
            execution = node.get("metadata", {}).get("execution", {}) if isinstance(node, dict) else {}
            fail(prior_lease["fence"] == tombstone
                 and prior_clock["hostId"] == trusted_clock.get("hostId")
                 and prior_clock["bootId"] == trusted_clock.get("bootId")
                 and prior_clock["monotonicSource"] == trusted_clock.get("monotonicSource")
                 and trusted_clock.get("monotonicNs", -1) >= prior_clock["expiresMonotonicNs"]
                 and isinstance(node, dict) and node.get("state") in {"pending", "ready", "blocked"}
                 and execution.get("idempotent") is True and execution.get("reclaimable") is True,
                 "MUTATION_INTERFACE_PROTOCOL", "acquire did not safely reclaim the prior snapshot lease")
    else:
        prior = leases.get(node_id)
        fail(isinstance(prior, dict) and expected_fence is not None,
             "MUTATION_INTERFACE_PROTOCOL", "renewal has no exact pre-mutation lease")
        prior_lease, prior_holder, prior_clock, prior_acquired, prior_renewed, prior_expires = \
            validate_lease_shape(prior, node_id, lease_id)
        fail(prior_lease["fence"] == expected_fence == tombstone == lease["fence"],
             "MUTATION_INTERFACE_PROTOCOL", "renewed lease fence does not match the projection")
        fail(holder == prior_holder and acquired == prior_acquired
             and clock["acquiredMonotonicNs"] == prior_clock["acquiredMonotonicNs"],
             "MUTATION_INTERFACE_PROTOCOL", "renewal reshaped immutable lease fields")
        renewal_monotonic = clock["expiresMonotonicNs"] - ttl_seconds * 1_000_000_000
        fail(renewed > prior_renewed and expires > prior_expires
             and clock["expiresMonotonicNs"] > prior_clock["expiresMonotonicNs"]
             and expires - renewed == dt.timedelta(seconds=ttl_seconds)
             and renewal_monotonic >= trusted_clock.get("monotonicNs", MAX_COUNTER + 1)
             and renewal_monotonic < prior_clock["expiresMonotonicNs"],
             "MUTATION_INTERFACE_PROTOCOL", "renewed lease expiry does not match the live TTL contract")
    return lease


def validate_mutation_result(payload: Any, action: str, request_id: str, expected_revision: int,
                             node_id: str, lease_id: Optional[str], fence: Optional[int],
                             target_state: Optional[str], expected_state: Optional[str],
                             snapshot: Mapping[str, Any], trusted_clock: Mapping[str, Any],
                             ttl_seconds: Optional[int]) -> Mapping[str, Any]:
    exact(payload, {"ok", "command", "requestId", "revision", "data"}, "trusted mutation result")
    expected_command = {
        "acquire": "lease acquire", "renew": "lease renew", "release": "lease release", "transition": "transition",
    }[action]
    fail(payload.get("ok") is True and payload.get("command") == expected_command,
         "MUTATION_INTERFACE_PROTOCOL", "trusted mutation result command is invalid")
    fail(payload.get("requestId") == request_id, "MUTATION_INTERFACE_PROTOCOL",
         "trusted mutation result requestId mismatch")
    fail(integer(payload.get("revision"), 1) and payload["revision"] == expected_revision + 1,
         "MUTATION_INTERFACE_PROTOCOL", "trusted mutation result revision must equal expectedRevision + 1")
    data = payload.get("data")
    if action == "acquire":
        exact(data, {"lease", "reclaimed"}, "lease acquire result data")
        fail(isinstance(data.get("reclaimed"), bool), "MUTATION_INTERFACE_PROTOCOL",
             "lease acquire reclaimed flag must be boolean")
        fail(isinstance(lease_id, str), "MUTATION_INTERFACE_PROTOCOL", "lease acquire request identity is invalid")
        fail(isinstance(ttl_seconds, int), "MUTATION_INTERFACE_PROTOCOL", "lease acquire TTL is invalid")
        validate_public_lease(data.get("lease"), "acquire", node_id, lease_id, snapshot,
                              trusted_clock, ttl_seconds)
        fail(data.get("reclaimed") is (snapshot.get("leases", {}).get(node_id) is not None),
             "MUTATION_INTERFACE_PROTOCOL", "lease acquire reclaimed flag mismatches the snapshot")
    elif action == "renew":
        exact(data, {"lease"}, "lease renew result data")
        fail(isinstance(lease_id, str) and integer(fence, 1), "MUTATION_INTERFACE_PROTOCOL",
             "lease renew request identity is invalid")
        fail(isinstance(ttl_seconds, int), "MUTATION_INTERFACE_PROTOCOL", "lease renew TTL is invalid")
        validate_public_lease(data.get("lease"), "renew", node_id, lease_id, snapshot,
                              trusted_clock, ttl_seconds, fence)
    elif action == "release":
        exact(data, {"nodeId", "leaseId", "fence"}, "lease release result data")
        fail(data.get("nodeId") == node_id and data.get("leaseId") == lease_id and data.get("fence") == fence,
             "MUTATION_INTERFACE_PROTOCOL", "lease release result identity mismatch")
    else:
        exact(data, {"nodeId", "from", "to"}, "transition result data")
        fail(data.get("nodeId") == node_id and data.get("from") == expected_state
             and data.get("to") == target_state, "MUTATION_INTERFACE_PROTOCOL",
             "transition result does not match the requested node and state")
    return payload


def mutate(action: str, graph_id: str, node_id: str, tick_id: str, expected_revision: int,
           lease_id: Optional[str] = None, fence: Optional[int] = None,
           target_state: Optional[str] = None, ttl_seconds: Optional[int] = None,
           expected_state: Optional[str] = None, snapshot: Optional[Mapping[str, Any]] = None,
           trusted_clock: Optional[Mapping[str, Any]] = None) -> Mapping[str, Any]:
    path = command_path("OPERATOR_LOOP_MUTATION_COMMAND")
    request_id = f"loop-{action}-{uuid.uuid4()}"
    request: Dict[str, Any] = {
        "schemaVersion": MUTATION_REQUEST_VERSION, "action": action, "graphId": graph_id,
        "nodeId": node_id, "tickId": tick_id, "requestId": request_id,
        "expectedRevision": expected_revision, "leaseId": lease_id, "fence": fence,
        "targetState": target_state, "ttlSeconds": ttl_seconds,
    }
    try:
        result_code, result_stdout, result_stderr = bounded_process(
            [path or ""], canonical(request), "trusted mutation launcher", LIMITS["interfaceTimeout"],
            MAX_INTERFACE_BYTES, MAX_INTERFACE_BYTES,
        )
    except LoopError as exc:
        raise MutationError("BROKER_UNAVAILABLE" if exc.code == "TRUSTED_INTERFACE_UNAVAILABLE" else exc.code,
                            exc.message, exc.details, exc.exit_code) from exc
    if result_code != 0:
        raise mutation_error(result_stderr or result_stdout, "trusted mutation launcher", result_code)
    try:
        payload = loads(result_stdout, "trusted mutation result")
        fail(snapshot is not None and trusted_clock is not None, "MUTATION_INTERFACE_PROTOCOL",
             "mutation validation context is missing")
        return validate_mutation_result(payload, action, request_id, expected_revision, node_id,
                                        lease_id, fence, target_state, expected_state,
                                        snapshot, trusted_clock, ttl_seconds)
    except LoopError as exc:
        raise MutationError("MUTATION_INTERFACE_PROTOCOL", exc.message, exc.details, 4) from exc


def current_revision(capacity: int) -> Tuple[Mapping[str, Any], Mapping[str, Any]]:
    snapshot, clock, _status = scheduler_evaluate("status", capacity)
    return snapshot, clock


def mutate_current(action: str, graph_id: str, node_id: str, tick_id: str, capacity: int,
                   lease_id: Optional[str] = None, fence: Optional[int] = None,
                   target_state: Optional[str] = None, ttl_seconds: Optional[int] = None,
                   attempts: int = 3) -> Mapping[str, Any]:
    last: Optional[MutationError] = None
    for _ in range(attempts):
        snapshot, clock = current_revision(capacity)
        node = snapshot_node_index(snapshot).get(node_id)
        expected_state = node.get("state") if isinstance(node, dict) else None
        try:
            return mutate(action, graph_id, node_id, tick_id, int(snapshot["revision"]), lease_id, fence,
                          target_state, ttl_seconds, expected_state, snapshot, clock)
        except MutationError as exc:
            last = exc
            if exc.code != "REVISION_CONFLICT":
                raise
    assert last is not None
    raise last


def validate_runner_result(value: Any, run_id: str, node_id: str, lease_id: str, fence: int) -> Mapping[str, Any]:
    exact(value, {"schemaVersion", "runId", "nodeId", "leaseId", "fence", "status", "summary", "error"}, "runner result")
    fail(isinstance(value.get("schemaVersion"), str) and value.get("schemaVersion") == RUN_RESULT_VERSION,
         "RUNNER_PROTOCOL", "runner result has the wrong version")
    fail(isinstance(value.get("runId"), str) and isinstance(value.get("nodeId"), str)
         and isinstance(value.get("leaseId"), str) and integer(value.get("fence"), 1),
         "RUNNER_PROTOCOL", "runner result scalar identity fields are invalid")
    fail(value.get("runId") == run_id and value.get("nodeId") == node_id
         and value.get("leaseId") == lease_id and value.get("fence") == fence,
         "RUNNER_PROTOCOL", "runner result is not bound to the leased run")
    fail(isinstance(value.get("status"), str) and value.get("status") in {"succeeded", "failed"}, "RUNNER_PROTOCOL",
         "runner status must be succeeded or failed; needs-runner is not a result")
    fail(isinstance(value.get("summary"), str) and len(value["summary"]) <= 4096,
         "RUNNER_PROTOCOL", "runner summary must be a bounded string")
    fail(value.get("error") is None or isinstance(value.get("error"), dict), "RUNNER_PROTOCOL", "runner error must be an object or null")
    fail(value["status"] != "succeeded" or value["error"] is None, "RUNNER_PROTOCOL", "successful runner result cannot carry an error")
    fail(value["status"] != "failed" or isinstance(value["error"], dict), "RUNNER_PROTOCOL", "failed runner result requires an error")
    return value


def run_runner(request: Mapping[str, Any], root: Path, tick_id: str, graph_id: str,
               node_id: str, lease_id: str, fence: int, ttl_seconds: int,
               capacity: int, clock: Mapping[str, Any], started_at: str, max_actions: int) -> Mapping[str, Any]:
    path = command_path("OPERATOR_LOOP_RUNNER_COMMAND")
    interval = max(1, min(ttl_seconds // 3, LIMITS["heartbeat"]))
    timeout = LIMITS["runnerTimeout"]
    runner_environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"}
    with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
        try:
            with tempfile.TemporaryFile() as stdin_file:
                stdin_file.write(canonical(request))
                stdin_file.seek(0)
                process = subprocess.Popen(
                    [path or ""], stdin=stdin_file, stdout=stdout_file, stderr=stderr_file,
                    env=runner_environment, start_new_session=True,
                )
                process_group = child_process_group(process, "runner")
        except OSError as exc:
            raise LoopError("RUNNER_UNAVAILABLE", "installed runner could not be started", str(exc), 3) from exc
        deadline = time.monotonic() + timeout
        next_heartbeat = time.monotonic() + interval
        heartbeat_error: Optional[LoopError] = None
        while process.poll() is None:
            now = time.monotonic()
            if (os.fstat(stdout_file.fileno()).st_size > MAX_RUNNER_BYTES
                    or os.fstat(stderr_file.fileno()).st_size > MAX_RUNNER_BYTES):
                terminate_process_group(process, process_group)
                heartbeat_error = LoopError("RUNNER_PROTOCOL", "runner output exceeded its bound")
                break
            if now >= deadline:
                terminate_process_group(process, process_group)
                heartbeat_error = LoopError("RUNNER_TIMEOUT", "runner exceeded its bounded execution time")
                break
            if now >= next_heartbeat:
                try:
                    renewed = mutate_current("renew", graph_id, node_id, tick_id, capacity, lease_id, fence,
                                             ttl_seconds=ttl_seconds)
                    clock = scheduler_evaluate("status", capacity)[1]
                    write_tick_lease(root, tick_id, clock, max_actions, started_at, {
                        "nodeId": node_id, "leaseId": lease_id, "fence": fence,
                    })
                    fail(renewed["data"].get("lease", {}).get("leaseId") == lease_id
                         and renewed["data"].get("lease", {}).get("fence") == fence,
                         "MUTATION_INTERFACE_PROTOCOL", "renewed lease identity changed")
                except LoopError as exc:
                    terminate_process_group(process, process_group)
                    heartbeat_error = exc
                    break
                next_heartbeat = time.monotonic() + interval
            time.sleep(min(0.1, max(0.01, next_heartbeat - now)))
        stdout_file.seek(0)
        stderr_file.seek(0)
        output = stdout_file.read(MAX_RUNNER_BYTES + 1)
        error_output = stderr_file.read(MAX_RUNNER_BYTES + 1)
    if heartbeat_error is not None:
        raise heartbeat_error
    if len(output) > MAX_RUNNER_BYTES or len(error_output) > MAX_RUNNER_BYTES:
        raise LoopError("RUNNER_PROTOCOL", "runner output exceeds its bound")
    if process.returncode != 0:
        return {
            "schemaVersion": RUN_RESULT_VERSION, "runId": request["runId"], "nodeId": node_id,
            "leaseId": lease_id, "fence": fence, "status": "failed", "summary": "runner process failed",
            "error": {"code": "RUNNER_EXIT", "exitCode": process.returncode,
                      "stderrEncoding": "base64url",
                      "stderr": base64.urlsafe_b64encode(error_output[:4096]).decode("ascii").rstrip("=")},
        }
    return validate_runner_result(loads(output, "runner result", MAX_RUNNER_BYTES), request["runId"], node_id, lease_id, fence)


def finalize_result(result: Mapping[str, Any], graph_id: str, node_id: str, tick_id: str,
                    lease_id: str, fence: int, capacity: int) -> Tuple[str, List[Mapping[str, Any]], Optional[Dict[str, Any]]]:
    mutations: List[Mapping[str, Any]] = []
    error: Optional[Dict[str, Any]] = None
    try:
        snapshot, _clock = current_revision(capacity)
        node = snapshot_node_index(snapshot).get(node_id)
        state = node.get("state") if isinstance(node, dict) else None
        if state == "pending":
            ready = mutate_current("transition", graph_id, node_id, tick_id, capacity,
                                   lease_id, fence, "ready")
            mutations.append(ready)
        active = mutate_current("transition", graph_id, node_id, tick_id, capacity, lease_id, fence, "active")
        mutations.append(active)
        target = "completed" if result["status"] == "succeeded" else "failed"
        try:
            final = mutate_current("transition", graph_id, node_id, tick_id, capacity, lease_id, fence, target)
            mutations.append(final)
            return ("succeeded" if target == "completed" else "failed"), mutations, None
        except LoopError as exc:
            if target == "completed":
                try:
                    failed = mutate_current("transition", graph_id, node_id, tick_id, capacity, lease_id, fence, "failed")
                    mutations.append(failed)
                except LoopError:
                    pass
            error = safe_error(exc)
            return "failed", mutations, error
    except LoopError as exc:
        try:
            def observed_state() -> Optional[str]:
                current, _trusted_clock = current_revision(capacity)
                current_node = snapshot_node_index(current).get(node_id)
                value = current_node.get("state") if isinstance(current_node, dict) else None
                return value if isinstance(value, str) else None

            state = observed_state()
            if state == "pending":
                try:
                    ready = mutate_current("transition", graph_id, node_id, tick_id, capacity,
                                           lease_id, fence, "ready")
                    mutations.append(ready)
                except LoopError:
                    pass
                state = observed_state()
            if state == "ready":
                try:
                    active = mutate_current("transition", graph_id, node_id, tick_id, capacity,
                                            lease_id, fence, "active")
                    mutations.append(active)
                except LoopError:
                    pass
                state = observed_state()
            if state == "active":
                try:
                    failed = mutate_current("transition", graph_id, node_id, tick_id, capacity,
                                            lease_id, fence, "failed")
                    mutations.append(failed)
                except LoopError:
                    pass
        except LoopError:
            pass
        error = safe_error(exc)
        return "failed", mutations, error


def release_lease(graph_id: str, node_id: str, tick_id: str, lease_id: str, fence: int, capacity: int) -> Optional[Dict[str, Any]]:
    try:
        mutate_current("release", graph_id, node_id, tick_id, capacity, lease_id, fence)
        return None
    except LoopError as exc:
        return safe_error(exc)


def safe_error(exc: LoopError) -> Dict[str, Any]:
    message = "".join(character if 32 <= ord(character) < 127 else "?" for character in exc.message)[:1024]
    value: Dict[str, Any] = {"code": exc.code, "message": message}
    if exc.details is not None:
        encoded = base64.urlsafe_b64encode(repr(exc.details).encode("utf-8", errors="replace")[:4096]).decode("ascii").rstrip("=")
        value["details"] = {"encoding": "base64url", "value": encoded}
    return value


def recover_acquired_lease(graph_id: str, node_id: str, lease_id: str, capacity: int,
                           before: Mapping[str, Any], trusted_clock: Mapping[str, Any],
                           ttl_seconds: int) -> Optional[Mapping[str, Any]]:
    snapshot, _clock = current_revision(capacity)
    leases = snapshot.get("leases", {})
    fail(snapshot.get("graphId") == graph_id, "MUTATION_INTERFACE_PROTOCOL",
         "recovery snapshot graph mismatch")
    lease = leases.get(node_id) if isinstance(leases, dict) else None
    if not isinstance(lease, dict) or lease.get("leaseId") != lease_id:
        return None
    validated = validate_public_lease(lease, "acquire", node_id, lease_id, before,
                                      trusted_clock, ttl_seconds)
    fences = snapshot.get("leaseFences")
    fail(isinstance(fences, dict) and fences.get(node_id) == validated["fence"],
         "MUTATION_INTERFACE_PROTOCOL", "recovered lease fence mismatches current projection")
    return validated


def handle_acquired(root: Path, args: argparse.Namespace, tick_id: str, started_at: str,
                    graph_id: str, candidate: Mapping[str, Any], lease: Mapping[str, Any],
                    capacity: int, clock: Mapping[str, Any], initial_error: Optional[LoopError] = None) -> Dict[str, Any]:
    node_id = str(candidate["nodeId"])
    lease_id = str(lease["leaseId"])
    fence = int(lease["fence"])
    run_id = str(uuid.uuid4())
    runner_result: Mapping[str, Any]
    runner_error: Optional[Dict[str, Any]] = None
    try:
        write_tick_lease(root, tick_id, clock, args.max_actions, started_at, {
            "nodeId": node_id, "leaseId": lease_id, "fence": fence,
        })
        runner_request = {
            "schemaVersion": RUN_REQUEST_VERSION, "tickId": tick_id, "runId": run_id,
            "idempotencyKey": "sha256:" + hashlib.sha256((graph_id + "\0" + node_id).encode("utf-8")).hexdigest(),
            "graphId": graph_id,
            "node": {"nodeId": node_id, "kind": candidate["kind"], "title": candidate["title"],
                     "claims": candidate["claims"]},
            "lease": {"leaseId": lease_id, "fence": fence, "expiresAt": lease["expiresAt"]},
        }
        if initial_error is not None:
            raise initial_error
        runner_result = run_runner(runner_request, root, tick_id, graph_id, node_id, lease_id,
                                   fence, args.lease_ttl, capacity, clock, started_at, args.max_actions)
    except LoopError as exc:
        runner_error = safe_error(exc)
        runner_result = {
            "schemaVersion": RUN_RESULT_VERSION, "runId": run_id, "nodeId": node_id,
            "leaseId": lease_id, "fence": fence, "status": "failed",
            "summary": "runner orchestration failed", "error": runner_error,
        }
    outcome, mutations, final_error = finalize_result(runner_result, graph_id, node_id, tick_id,
                                                       lease_id, fence, capacity)
    release_error = release_lease(graph_id, node_id, tick_id, lease_id, fence, capacity)
    event = {
        "schemaVersion": LOOP_EVENT_VERSION, "eventId": str(uuid.uuid4()), "occurredAt": utc_now(),
        "tickId": tick_id, "runId": run_id, "graphId": graph_id, "nodeId": node_id,
        "leaseId": lease_id, "fence": fence, "outcome": outcome,
        "runnerResult": dict(runner_result), "graphMutationRevisions": [item["revision"] for item in mutations],
        "error": final_error or runner_error, "releaseError": release_error,
    }
    append_event(root, event)
    return event


def tick(args: argparse.Namespace) -> Mapping[str, Any]:
    root = operator_dir()
    if not args.dry_run:
        if command_path("OPERATOR_LOOP_RUNNER_COMMAND", required=False) is None:
            raise LoopError("NEEDS_RUNNER", "no installed host runner is configured", exit_code=7)
        if command_path("OPERATOR_LOOP_MUTATION_COMMAND", required=False) is None:
            raise LoopError("BROKER_UNAVAILABLE", "trusted mutation launcher is not configured", exit_code=7)
    tick_id = str(uuid.uuid4())
    started_at = utc_now()
    actions: List[Dict[str, Any]] = []
    diagnostics: List[Dict[str, Any]] = []
    with exclusive_lock(root, "tick", blocking=False):
        snapshot, clock, frontier = scheduler_evaluate("frontier", args.max_actions, explain=True)
        if args.dry_run:
            return {
                "ok": True, "command": "tick", "data": {
                    "schemaVersion": LOOP_TICK_VERSION, "tickId": tick_id, "dryRun": True,
                    "maxActions": args.max_actions, "claimedCount": 0, "actions": [],
                    "frontier": frontier, "paused": read_state(root)["paused"], "diagnostics": [],
                },
            }
        write_tick_lease(root, tick_id, clock, args.max_actions, started_at)
        try:
            claim_attempts = 0
            max_claim_attempts = max(16, args.max_actions * 4)
            while len(actions) < args.max_actions and claim_attempts < max_claim_attempts:
                remaining = args.max_actions - len(actions)
                snapshot, clock, frontier = scheduler_evaluate("frontier", remaining, explain=True)
                graph_id = str(snapshot["graphId"])
                runnable = frontier.get("runnable")
                fail(isinstance(runnable, list), "INTERFACE_PROTOCOL", "scheduler frontier runnable must be an array")
                if not runnable:
                    break
                candidate = runnable[0]
                fail(isinstance(candidate, dict) and isinstance(candidate.get("nodeId"), str),
                     "INTERFACE_PROTOCOL", "scheduler runnable entry is invalid")
                node_id = candidate["nodeId"]
                lease_id = f"loop-{uuid.uuid4()}"
                claim_attempts += 1
                with exclusive_lock(root, "state", blocking=True):
                    state = read_state(root)
                    if state["paused"]:
                        break
                    try:
                        acquired = mutate("acquire", graph_id, node_id, tick_id, int(snapshot["revision"]),
                                          lease_id=lease_id, ttl_seconds=args.lease_ttl,
                                          snapshot=snapshot, trusted_clock=clock)
                    except MutationError as exc:
                        if exc.code in {"REVISION_CONFLICT", "LEASE_CONFLICT", "FENCE_STALE", "RECONCILIATION_REQUIRED"}:
                            diagnostics = [{"code": exc.code, "nodeId": node_id, "attempt": claim_attempts}]
                            if exc.code in {"FENCE_STALE", "RECONCILIATION_REQUIRED"}:
                                break
                            continue
                        recovered = recover_acquired_lease(graph_id, node_id, lease_id, remaining,
                                                           snapshot, clock, args.lease_ttl)
                        if recovered is None:
                            raise
                        event = handle_acquired(root, args, tick_id, started_at, graph_id, candidate,
                                                recovered, remaining, clock, exc)
                        actions.append(event)
                        continue
                lease = acquired["data"]["lease"]
                event = handle_acquired(root, args, tick_id, started_at, graph_id, candidate,
                                        lease, remaining, clock)
                actions.append(event)
                clock = scheduler_evaluate("status", remaining)[1]
                write_tick_lease(root, tick_id, clock, args.max_actions, started_at)
        finally:
            clear_tick_lease(root, tick_id)
    return {
        "ok": True, "command": "tick", "data": {
            "schemaVersion": LOOP_TICK_VERSION, "tickId": tick_id, "dryRun": False,
            "maxActions": args.max_actions, "claimedCount": len(actions), "actions": actions,
            "frontier": frontier, "paused": read_state(root)["paused"], "diagnostics": diagnostics,
        },
    }


def set_pause(paused: bool, reason: Optional[str]) -> Mapping[str, Any]:
    root = operator_dir()
    with exclusive_lock(root, "state", blocking=True):
        state = read_state(root)
        if state["paused"] != paused:
            state = {
                "schemaVersion": LOOP_STATE_VERSION, "paused": paused,
                "reason": reason if paused else None, "generation": state["generation"] + 1,
                "updatedAt": utc_now(),
            }
            with LoopStore(root, create=True) as store:
                store.write_json("state.json", state, "loop state")
    return {"ok": True, "command": "pause" if paused else "resume", "data": state}


def status(args: argparse.Namespace) -> Mapping[str, Any]:
    root = operator_dir()
    _snapshot, _clock, scheduler = scheduler_evaluate("status", args.capacity)
    state = read_state(root)
    lease = read_tick_lease(root)
    data = {
        "schemaVersion": LOOP_STATUS_VERSION, "paused": state["paused"], "reason": state["reason"],
        "stateGeneration": state["generation"], "activeTick": lease,
        "runnerInstalled": command_path("OPERATOR_LOOP_RUNNER_COMMAND", required=False) is not None,
        "mutationLauncherInstalled": command_path("OPERATOR_LOOP_MUTATION_COMMAND", required=False) is not None,
        "scheduler": scheduler,
    }
    return {"ok": True, "command": "status", "data": data}


def parser() -> argparse.ArgumentParser:
    root = JSONArgumentParser(prog="operator-loop")
    sub = root.add_subparsers(dest="command", required=True, parser_class=JSONArgumentParser)
    tick_parser = sub.add_parser("tick", add_help=True)
    tick_parser.add_argument("--dry-run", action="store_true")
    tick_parser.add_argument("--max-actions", type=int, default=1, metavar="N")
    tick_parser.add_argument("--json", action="store_true")
    pause_parser = sub.add_parser("pause")
    pause_parser.add_argument("--reason")
    pause_parser.add_argument("--json", action="store_true")
    resume_parser = sub.add_parser("resume")
    resume_parser.add_argument("--json", action="store_true")
    status_parser = sub.add_parser("status")
    status_parser.add_argument("--json", action="store_true")
    status_parser.add_argument("--capacity", type=int, default=1, help=argparse.SUPPRESS)
    return root


def print_text(payload: Mapping[str, Any]) -> None:
    command = payload["command"]
    data = payload["data"]
    if command == "tick":
        qualifier = "dry-run " if data["dryRun"] else ""
        print(f"Loop {qualifier}tick {data['tickId']}: {data['claimedCount']} action(s) claimed")
        if data["paused"]:
            print("Loop is paused.")
        for action in data["actions"]:
            print(f"- {action['nodeId']}: {action['outcome']} (fence {action['fence']})")
    elif command == "status":
        print("Operator loop is " + ("paused" if data["paused"] else "running"))
        if data["reason"]:
            print(f"Reason: {data['reason']}")
        print(f"Active tick: {data['activeTick']['tickId'] if data['activeTick'] else 'none'}")
        print(f"Runnable: {data['scheduler']['runnableCount']}")
    else:
        print("Operator loop " + ("paused" if data["paused"] else "resumed"))


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        configure_limits()
        args = parser().parse_args(argv)
        if args.command == "tick":
            fail(0 <= args.max_actions <= 10000, "USAGE", "--max-actions must be between 0 and 10000", exit_code=2)
            ttl = env_integer("OPERATOR_LOOP_LEASE_TTL_SECONDS", 300, 3, 86400)
            args.lease_ttl = ttl
            payload = tick(args)
        elif args.command == "pause":
            if args.reason is not None:
                fail(1 <= len(args.reason) <= 1024 and bool(args.reason.strip()), "USAGE", "--reason must be non-empty and at most 1024 characters", exit_code=2)
            payload = set_pause(True, args.reason)
        elif args.command == "resume":
            payload = set_pause(False, None)
        else:
            fail(0 <= args.capacity <= 10000, "USAGE", "status capacity is invalid", exit_code=2)
            payload = status(args)
        if getattr(args, "json", False):
            sys.stdout.buffer.write(canonical(payload))
        else:
            print_text(payload)
        return 0
    except LoopError as exc:
        error: Dict[str, Any] = {"ok": False, "error": {"code": exc.code, "message": exc.message}}
        if exc.details is not None:
            error["error"]["details"] = exc.details
        sys.stderr.buffer.write(canonical(error))
        return exc.exit_code
    except (AttributeError, IndexError, KeyError, OverflowError, RecursionError, TypeError, ValueError) as exc:
        error = {"ok": False, "error": {"code": "LOOP_FAILED_CLOSED", "message": "loop failed closed", "details": str(exc)}}
        sys.stderr.buffer.write(canonical(error))
        return 5
    except OSError as exc:
        error = {"ok": False, "error": {"code": "IO_ERROR", "message": "loop I/O failed", "details": str(exc)}}
        sys.stderr.buffer.write(canonical(error))
        return 3
    except BrokenPipeError:
        return 0


raise SystemExit(main())
PY

exec python3 -c "$OPERATOR_LOOP_PROGRAM" "$@"
