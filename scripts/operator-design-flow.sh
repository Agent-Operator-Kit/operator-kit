#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPERATOR_DESIGN_FLOW_SCRIPT_DIR="$SCRIPT_DIR"

IFS= read -r -d '' OPERATOR_DESIGN_FLOW_PROGRAM <<'PY' || true
from __future__ import annotations

import argparse
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
from typing import Any, Dict, List, Mapping, Optional, Sequence, Set, Tuple


STATUS_VERSION = "operator.design-flow-status/v1"
GRAPH_REQUEST_VERSION = "operator.design-flow-graph-mutation-request/v1"
FEEDBACK_REQUEST_VERSION = "operator.design-flow-feedback-request/v1"
FEEDBACK_RESULT_VERSION = "operator.design-flow-feedback-result/v1"
SNAPSHOT_VERSION = "operator.control-snapshot/v1"
GRAPH_VERSION = "operator.control-graph/v1"
PROPOSALS = ("proposal-a", "proposal-b", "proposal-c")
PUBLISH_FLOW = "production-publish"
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+\-]*$")
BINDING_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]*$")
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
FLOW_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]{0,47}$")
REQUEST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+\-]{0,127}$")
NODE_KINDS = {"goal", "feature", "lane", "task", "validation", "human-gate", "integration", "feedback"}
CONTAINER_KINDS = {"goal", "feature", "lane"}
WORK_KINDS = {"task", "validation", "integration", "feedback"}
EDGE_KINDS = {"contains", "depends-on", "assigned-to", "validated-by", "gated-by", "integrates-into", "feedback-for"}
STATES = {
    "container": {"planned", "active", "blocked", "completed", "cancelled"},
    "work": {"pending", "ready", "active", "blocked", "completed", "failed", "cancelled"},
    "gate": {"pending", "approved", "rejected", "cancelled"},
}
INITIAL = {"container": "planned", "work": "pending", "gate": "pending"}
ENDPOINTS = {
    "contains": (CONTAINER_KINDS, NODE_KINDS - {"goal"}),
    "depends-on": (NODE_KINDS - {"human-gate"}, NODE_KINDS),
    "assigned-to": (WORK_KINDS, {"lane"}),
    "validated-by": ({"task", "integration"}, {"validation"}),
    "gated-by": ({"goal", "feature", "task", "integration"}, {"human-gate"}),
    "integrates-into": ({"integration"}, {"feature"}),
    "feedback-for": ({"feedback"}, NODE_KINDS - {"feedback"}),
}
MAX_INTERFACE_BYTES = 8 * 1024 * 1024
MAX_BRIEF_BYTES = 1024 * 1024
MAX_EVIDENCE_FILE_BYTES = 64 * 1024 * 1024
MAX_EVIDENCE_TOTAL_BYTES = 256 * 1024 * 1024
MAX_JSON_DEPTH = 40
MAX_JSON_ITEMS = 200000
PROVIDER_OVERRIDE_VARIABLES = {
    "OPERATOR_DESIGN_FLOW_SNAPSHOT_COMMAND",
    "OPERATOR_DESIGN_FLOW_MUTATION_COMMAND",
    "OPERATOR_DESIGN_FLOW_FEEDBACK_COMMAND",
    "OPERATOR_DESIGN_FLOW_GRAPH_MUTATION_HOST_COMMAND",
}


class FlowError(Exception):
    def __init__(self, code: str, message: str, details: Any = None, exit_code: int = 5):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details
        self.exit_code = exit_code


class JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise FlowError("USAGE", message, exit_code=2)


def fail(condition: bool, code: str, message: str, details: Any = None, exit_code: int = 5) -> None:
    if not condition:
        raise FlowError(code, message, details, exit_code)


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
        raise FlowError("INTERFACE_LIMIT", f"{label} exceeds {maximum} bytes", exit_code=4)
    try:
        value = json.loads(
            raw.decode("utf-8"), parse_float=reject_float, parse_int=parse_integer,
            parse_constant=reject_float, object_pairs_hook=strict_pairs,
        )
        validate_json_domain(value)
        return value
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise FlowError("INTERFACE_PROTOCOL", f"{label} is not canonical JSON", str(exc), 4) from exc


def canonical(value: Any) -> bytes:
    validate_json_domain(value)
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def load_interface(raw: bytes, label: str) -> Any:
    value = loads(raw, label)
    fail(raw == canonical(value), "INTERFACE_PROTOCOL", f"{label} is not Operator Canonical JSON v1", exit_code=4)
    return value


def exact(value: Any, fields: Set[str], label: str) -> Mapping[str, Any]:
    fail(isinstance(value, dict), "INTERFACE_PROTOCOL", f"{label} must be an object", exit_code=4)
    actual = set(value)
    fail(actual == fields, "INTERFACE_PROTOCOL", f"{label} fields are invalid", {
        "missing": sorted(fields - actual), "unknown": sorted(actual - fields),
    }, 4)
    return value


def integer(value: Any, minimum: int = 0) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def require_identifier(value: str, label: str, pattern: re.Pattern[str] = ID_RE) -> str:
    fail(bool(pattern.fullmatch(value)), "USAGE", f"{label} is invalid", value, 2)
    return value


def require_canonical_text(value: str, label: str, maximum: int) -> str:
    fail(bool(value.strip()) and len(value) <= maximum, "USAGE",
         f"{label} must be non-empty and at most {maximum} characters", exit_code=2)
    fail(not any(ord(ch) < 32 or 127 <= ord(ch) <= 159 or 0xD800 <= ord(ch) <= 0xDFFF for ch in value),
         "USAGE", f"{label} contains a non-canonical control character", exit_code=2)
    return value


def interface_timeout() -> int:
    raw = os.environ.get("OPERATOR_DESIGN_FLOW_INTERFACE_TIMEOUT_SECONDS", "30")
    try:
        value = parse_integer(raw)
    except ValueError as exc:
        raise FlowError("USAGE", "OPERATOR_DESIGN_FLOW_INTERFACE_TIMEOUT_SECONDS must be an integer", exit_code=2) from exc
    fail(1 <= value <= 300, "USAGE", "interface timeout must be between 1 and 300 seconds", exit_code=2)
    return value


def command_path(variable: str, default_name: str) -> str:
    fail(variable not in os.environ, "AUTHORITY_DENIED",
         "installed design flow rejects trusted-provider command overrides", variable, 4)
    path = Path(os.environ["OPERATOR_DESIGN_FLOW_SCRIPT_DIR"]) / default_name
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise FlowError("TRUSTED_INTERFACE_UNAVAILABLE",
                        f"trusted sibling provider is unavailable: {default_name}", str(exc), 3) from exc
    fail(path.is_absolute() and stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode)
         and info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) & 0o022 == 0
         and os.access(path, os.X_OK),
         "TRUSTED_INTERFACE_UNAVAILABLE", f"trusted sibling provider is unsafe: {default_name}", str(path), 3)
    return str(path)


def terminate_process_group(process: subprocess.Popen[Any]) -> None:
    try:
        process_group = os.getpgid(process.pid)
    except OSError:
        process_group = process.pid
    if process_group == process.pid and process_group != os.getpgrp():
        try:
            os.killpg(process_group, signal.SIGTERM)
        except OSError:
            pass
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            try:
                os.killpg(process_group, 0)
            except OSError:
                break
            time.sleep(0.02)
        try:
            os.killpg(process_group, signal.SIGKILL)
        except OSError:
            pass
    else:
        try:
            process.kill()
        except OSError:
            pass
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except OSError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def bounded_command(root: "OperatorRoot", path: str, payload: Optional[Mapping[str, Any]], label: str,
                    provider_mode: str) -> bytes:
    root.verify_children()
    successful_mutation = False
    environment = dict(os.environ)
    environment.update({
        "OPERATOR_DIR": str(root.path),
        "OPERATOR_DESIGN_FLOW_ROOT_FD": str(root.fd),
        "OPERATOR_DESIGN_FLOW_ROOT_DEV": str(root.identity[0]),
        "OPERATOR_DESIGN_FLOW_ROOT_INO": str(root.identity[1]),
        "OPERATOR_DESIGN_FLOW_ROOT_PATH": str(root.path),
        "OPERATOR_DESIGN_FLOW_ROOT_LOCK_MODE": "exclusive-held",
        "OPERATOR_DESIGN_FLOW_PROVIDER_MODE": provider_mode,
    })
    for name, descriptor in root.children.items():
        info = os.fstat(descriptor)
        prefix = f"OPERATOR_DESIGN_FLOW_ROOT_{name.upper()}"
        environment[f"{prefix}_FD"] = str(descriptor)
        environment[f"{prefix}_DEV"] = str(info.st_dev)
        environment[f"{prefix}_INO"] = str(info.st_ino)
    leaf_caps: Dict[str, Any] = {}
    leaf_descriptors: List[int] = []
    for name, descriptor in sorted(root.leaves.items()):
        if descriptor is None:
            leaf_caps[name] = None
        else:
            info = os.fstat(descriptor)
            leaf_caps[name] = [descriptor, info.st_dev, info.st_ino]
            leaf_descriptors.append(descriptor)
    environment["OPERATOR_DESIGN_FLOW_ROOT_LEAF_CAPS"] = json.dumps(
        leaf_caps, sort_keys=True, separators=(",", ":"))
    environment["OPERATOR_DESIGN_FLOW_ROOT_BINDING_MANIFEST_FD"] = str(
        root.binding_manifest.fileno())
    try:
        with tempfile.TemporaryFile() as input_file, tempfile.TemporaryFile() as output_file, tempfile.TemporaryFile() as error_file:
            if payload is not None:
                input_file.write(canonical(payload))
            input_file.seek(0)
            try:
                process = subprocess.Popen([path], stdin=input_file, stdout=output_file, stderr=error_file,
                                           start_new_session=True, env=environment,
                                           pass_fds=(root.fd, *root.children.values(), *leaf_descriptors,
                                                     root.binding_manifest.fileno()))
            except OSError as exc:
                raise FlowError("TRUSTED_INTERFACE_UNAVAILABLE", f"{label} could not be invoked", str(exc), 3) from exc
            deadline = time.monotonic() + interface_timeout()
            while process.poll() is None:
                if os.fstat(output_file.fileno()).st_size > MAX_INTERFACE_BYTES or os.fstat(error_file.fileno()).st_size > MAX_INTERFACE_BYTES:
                    terminate_process_group(process)
                    raise FlowError("INTERFACE_LIMIT", f"{label} exceeded its output bound", exit_code=4)
                if time.monotonic() >= deadline:
                    terminate_process_group(process)
                    raise FlowError("INTERFACE_TIMEOUT", f"{label} exceeded its time bound", exit_code=4)
                time.sleep(0.02)
            output_file.seek(0)
            error_file.seek(0)
            output = output_file.read(MAX_INTERFACE_BYTES + 1)
            error = error_file.read(MAX_INTERFACE_BYTES + 1)
            if len(output) > MAX_INTERFACE_BYTES or len(error) > MAX_INTERFACE_BYTES:
                raise FlowError("INTERFACE_LIMIT", f"{label} exceeded its output bound", exit_code=4)
            if process.returncode != 0:
                diagnostic: Any = {"stderr": re.sub(r"[\x00-\x1f\x7f]", " ",
                                                     error.decode("utf-8", errors="replace"))[:4096]}
                for candidate in (error, output):
                    if candidate.strip():
                        try:
                            diagnostic = loads(candidate, f"{label} error")
                        except FlowError:
                            pass
                        break
                raise FlowError("TRUSTED_INTERFACE_FAILED", f"{label} exited with status {process.returncode}", diagnostic, 4)
            successful_mutation = provider_mode == "mutation"
            return output
    finally:
        # A successful trusted mutation is allowed to replace only the two
        # materialized graph leaves.  Their new identities are not adopted
        # here: graph_mutate first validates the result envelope and then
        # refresh_mutable_graph_leaves proves the journal/replay post-state.
        root.verify_children(skip_mutable=successful_mutation)


def owned_real_directory(path: Path, label: str) -> Path:
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise FlowError("IO_ERROR", f"cannot inspect {label}", str(path), 3) from exc
    fail(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode), "IO_ERROR", f"{label} must be a real directory", str(path), 3)
    fail(info.st_uid == os.geteuid(), "IO_ERROR", f"{label} has unsafe ownership", str(path), 3)
    return path.resolve()


class OperatorRoot:
    """One held OPERATOR_DIR identity shared by every operation in a command."""

    def __init__(self, path: Path, descriptor: int, identity: Tuple[int, int],
                 children: Mapping[str, int], leaves: Mapping[str, Optional[int]],
                 binding_manifest: Any):
        self.path = path
        self.fd = descriptor
        self.identity = identity
        self.children = dict(children)
        self.leaves = dict(leaves)
        self.binding_manifest = binding_manifest

    @classmethod
    def open(cls) -> "OperatorRoot":
        raw = os.environ.get("OPERATOR_DIR", "")
        fail(bool(raw), "USAGE", "OPERATOR_DIR is required", exit_code=2)
        path = Path(os.path.abspath(raw))
        descriptor: Optional[int] = None
        children: Dict[str, int] = {}
        leaves: Dict[str, Optional[int]] = {}
        try:
            expected = os.lstat(path)
            fail(stat.S_ISDIR(expected.st_mode) and not stat.S_ISLNK(expected.st_mode)
                 and expected.st_uid == os.geteuid(), "IO_ERROR",
                 "OPERATOR_DIR must be an owned real directory", str(path), 3)
            descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            actual = os.fstat(descriptor)
            fail(stat.S_ISDIR(actual.st_mode) and actual.st_uid == os.geteuid()
                 and (actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino),
                 "IO_ERROR", "OPERATOR_DIR changed during descriptor open", str(path), 3)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            authority = os.open("authority", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=descriptor)
            children["authority"] = authority
            graph = os.open("graph", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            children["graph"] = graph
            bindings = os.open("bindings", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                               dir_fd=graph)
            children["bindings"] = bindings
            host = os.open("host", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                           dir_fd=descriptor)
            children["host"] = host
            for name, child in children.items():
                info = os.fstat(child)
                fail(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(), "IO_ERROR",
                     f"trusted {name} directory is unsafe", exit_code=3)
            def pin_leaf(label: str, parent: int, name: str, required: bool,
                         writable: bool = False) -> None:
                try:
                    leaf = os.open(name, (os.O_RDWR if writable else os.O_RDONLY)
                                   | os.O_NOFOLLOW, dir_fd=parent)
                except FileNotFoundError:
                    fail(not required, "IO_ERROR", f"trusted leaf is missing: {label}", exit_code=3)
                    leaves[label] = None
                    return
                info = os.fstat(leaf)
                fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
                     and info.st_nlink == 1, "IO_ERROR", f"trusted leaf is unsafe: {label}", exit_code=3)
                leaves[label] = leaf
            pin_leaf("authority/control-graph-public-key.json", authority,
                     "control-graph-public-key.json", True)
            for name in ("definition.json", "projection.json", "events.jsonl"):
                pin_leaf(f"graph/{name}", graph, name, False, name == "events.jsonl")
            for name in ("design-proof-signer.json", "design-proof-keychain.json"):
                pin_leaf(f"host/{name}", host, name, False)
            binding_entries: List[Dict[str, Any]] = []
            binding_total = 0
            for name in sorted(os.listdir(bindings)):
                fail(name.endswith(".json") and "/" not in name, "IO_ERROR",
                     "trusted bindings inventory is unsafe", name, 3)
                binding_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=bindings)
                try:
                    info = os.fstat(binding_fd)
                    fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
                         and info.st_nlink == 1 and info.st_size <= MAX_INTERFACE_BYTES,
                         "IO_ERROR", "trusted binding is unsafe", name, 3)
                    data = bytearray()
                    while len(data) <= MAX_INTERFACE_BYTES:
                        chunk = os.read(binding_fd, min(65536, MAX_INTERFACE_BYTES + 1 - len(data)))
                        if not chunk:
                            break
                        data.extend(chunk)
                    fail(len(data) == info.st_size and len(data) <= MAX_INTERFACE_BYTES,
                         "IO_ERROR", "trusted binding changed during inventory", name, 3)
                    binding_total += len(data)
                    fail(binding_total <= MAX_INTERFACE_BYTES, "IO_ERROR",
                         "trusted binding inventory exceeds its aggregate byte bound", exit_code=3)
                    binding_entries.append({"name": name, "dev": info.st_dev, "ino": info.st_ino,
                                            "size": info.st_size,
                                            "sha256": hashlib.sha256(data).hexdigest()})
                finally:
                    os.close(binding_fd)
            fail(len(binding_entries) <= 10000, "IO_ERROR", "trusted binding inventory exceeds its bound", exit_code=3)
            binding_manifest = tempfile.TemporaryFile()
            encoded_manifest = canonical({"schemaVersion": "operator.binding-capability-manifest/v1",
                                          "entries": binding_entries})
            fail(len(encoded_manifest) <= MAX_INTERFACE_BYTES, "IO_ERROR",
                 "trusted binding manifest exceeds its bound", exit_code=3)
            binding_manifest.write(encoded_manifest); binding_manifest.flush(); binding_manifest.seek(0)
            root = cls(path, descriptor, (actual.st_dev, actual.st_ino), children, leaves,
                       binding_manifest)
            root.verify_children()
            return root
        except FlowError:
            if "binding_manifest" in locals():
                binding_manifest.close()
            for leaf in leaves.values():
                if leaf is not None:
                    os.close(leaf)
            for child in children.values():
                os.close(child)
            if descriptor is not None:
                os.close(descriptor)
            raise
        except OSError as exc:
            if "binding_manifest" in locals():
                binding_manifest.close()
            for leaf in leaves.values():
                if leaf is not None:
                    os.close(leaf)
            for child in children.values():
                os.close(child)
            if descriptor is not None:
                os.close(descriptor)
            raise FlowError("IO_ERROR", "cannot open OPERATOR_DIR", str(path), 3) from exc

    def verify_path(self) -> None:
        """Refuse a rename/replacement even though the original FD remains safe."""
        descriptor: Optional[int] = None
        try:
            expected = os.lstat(self.path)
            fail(stat.S_ISDIR(expected.st_mode) and not stat.S_ISLNK(expected.st_mode)
                 and expected.st_uid == os.geteuid(), "IO_ERROR",
                 "OPERATOR_DIR pathname no longer names an owned real directory", str(self.path), 3)
            descriptor = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            actual = os.fstat(descriptor)
            fail((expected.st_dev, expected.st_ino) == (actual.st_dev, actual.st_ino)
                 and (actual.st_dev, actual.st_ino) == self.identity,
                 "IO_ERROR", "OPERATOR_DIR identity changed during the design command", str(self.path), 3)
        except FlowError:
            raise
        except OSError as exc:
            raise FlowError("IO_ERROR", "cannot reverify OPERATOR_DIR identity", str(self.path), 3) from exc
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def verify_children(self, skip_mutable: bool = False) -> None:
        self.verify_path()
        relationships = ((self.fd, "authority", "authority"),
                         (self.fd, "graph", "graph"),
                         (self.children["graph"], "bindings", "bindings"),
                         (self.fd, "host", "host"))
        for parent, entry, key in relationships:
            current = os.stat(entry, dir_fd=parent, follow_symlinks=False)
            held = os.fstat(self.children[key])
            fail(stat.S_ISDIR(current.st_mode) and not stat.S_ISLNK(current.st_mode)
                 and current.st_uid == os.geteuid()
                 and (current.st_dev, current.st_ino) == (held.st_dev, held.st_ino),
                 "IO_ERROR", f"trusted {key} directory identity changed", exit_code=3)
        for label, descriptor in self.leaves.items():
            if skip_mutable and label in {"graph/definition.json", "graph/projection.json"}:
                continue
            parts = label.split("/")
            parent = (self.children["authority"] if parts[0] == "authority" else
                      self.children["host"] if parts[0] == "host" else
                      self.children["bindings"] if parts[:2] == ["graph", "bindings"] else
                      self.children["graph"])
            name = parts[-1]
            try:
                published = os.stat(name, dir_fd=parent, follow_symlinks=False)
                identity: Optional[Tuple[int, int]] = ((published.st_dev, published.st_ino)
                                                       if stat.S_ISREG(published.st_mode)
                                                       and not stat.S_ISLNK(published.st_mode)
                                                       and published.st_uid == os.geteuid()
                                                       and published.st_nlink == 1 else (-1, -1))
            except FileNotFoundError:
                identity = None
            held_identity = None if descriptor is None else (
                os.fstat(descriptor).st_dev, os.fstat(descriptor).st_ino)
            fail(identity == held_identity, "IO_ERROR", f"trusted leaf identity changed: {label}", exit_code=3)

    def refresh_mutable_graph_leaves(self, request_id: str, expected_revision: int) -> None:
        self.verify_children(skip_mutable=True)
        graph = self.children["graph"]
        replacements: Dict[str, int] = {}
        def journal_state() -> Tuple[int, str, Mapping[str, Any]]:
            descriptor = self.leaves.get("graph/events.jsonl")
            fail(descriptor is not None, "IO_ERROR", "event journal capability is unavailable", exit_code=3)
            assert descriptor is not None
            info = os.fstat(descriptor)
            fail(info.st_size <= 256 * 1024 * 1024, "IO_ERROR", "event journal exceeds its bound", exit_code=3)
            digest = hashlib.sha256(); offset = 0; tail = b""
            while offset < info.st_size:
                chunk = os.pread(descriptor, min(65536, info.st_size - offset), offset)
                fail(bool(chunk), "IO_ERROR", "event journal changed during post-mutation review", exit_code=3)
                digest.update(chunk); offset += len(chunk); tail = (tail + chunk)[-MAX_INTERFACE_BYTES:]
            fail(offset == info.st_size and tail.endswith(b"\n"), "IO_ERROR",
                 "event journal is incomplete after mutation", exit_code=3)
            line = tail.rstrip(b"\n").split(b"\n")[-1]
            event = loads(line + b"\n", "post-mutation event")
            fail(isinstance(event, dict) and event.get("sequence") == expected_revision
                 and event.get("requestId") == request_id, "INTERFACE_PROTOCOL",
                 "event journal does not contain the validated mutation result", exit_code=4)
            return info.st_size, digest.hexdigest(), event
        try:
            before_journal = journal_state()
            for name in ("definition.json", "projection.json"):
                descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=graph)
                info = os.fstat(descriptor)
                fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
                     and info.st_nlink == 1, "IO_ERROR",
                     f"mutable graph leaf is unsafe after commit: {name}", exit_code=3)
                replacements[f"graph/{name}"] = descriptor
            candidate_leaves = dict(self.leaves); candidate_leaves.update(replacements)
            environment = dict(os.environ)
            environment.update({"OPERATOR_DIR": str(self.path),
                                "OPERATOR_DESIGN_FLOW_ROOT_FD": str(self.fd),
                                "OPERATOR_DESIGN_FLOW_ROOT_DEV": str(self.identity[0]),
                                "OPERATOR_DESIGN_FLOW_ROOT_INO": str(self.identity[1]),
                                "OPERATOR_DESIGN_FLOW_ROOT_PATH": str(self.path),
                                "OPERATOR_DESIGN_FLOW_ROOT_LOCK_MODE": "exclusive-held",
                                "OPERATOR_DESIGN_FLOW_PROVIDER_MODE": ""})
            for name, child in self.children.items():
                info = os.fstat(child); prefix = f"OPERATOR_DESIGN_FLOW_ROOT_{name.upper()}"
                environment[f"{prefix}_FD"] = str(child); environment[f"{prefix}_DEV"] = str(info.st_dev)
                environment[f"{prefix}_INO"] = str(info.st_ino)
            caps: Dict[str, Any] = {}; passed: List[int] = [self.fd, *self.children.values()]
            for label, descriptor in candidate_leaves.items():
                if descriptor is None:
                    caps[label] = None
                else:
                    info = os.fstat(descriptor); caps[label] = [descriptor, info.st_dev, info.st_ino]
                    passed.append(descriptor)
            environment["OPERATOR_DESIGN_FLOW_ROOT_LEAF_CAPS"] = json.dumps(caps, sort_keys=True,
                                                                               separators=(",", ":"))
            environment["OPERATOR_DESIGN_FLOW_ROOT_BINDING_MANIFEST_FD"] = str(self.binding_manifest.fileno())
            passed.append(self.binding_manifest.fileno())
            code, output, error = (None, b"", b"")
            with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
                process = subprocess.run([command_path("OPERATOR_DESIGN_FLOW_MUTATION_COMMAND", "operator-graph.sh"),
                                          "replay", "check"], stdin=subprocess.DEVNULL,
                                         stdout=out, stderr=err, env=environment,
                                         pass_fds=tuple(dict.fromkeys(passed)), timeout=30, check=False)
                out.seek(0); err.seek(0); output = out.read(MAX_INTERFACE_BYTES + 1); error = err.read(MAX_INTERFACE_BYTES + 1)
                code = process.returncode
            fail(code == 0 and len(output) <= MAX_INTERFACE_BYTES and len(error) <= MAX_INTERFACE_BYTES,
                 "INTERFACE_PROTOCOL", "post-mutation replay check failed", exit_code=4)
            replay_result = load_interface(output, "post-mutation replay result")
            fail(replay_result.get("ok") is True and replay_result.get("command") == "replay check"
                 and replay_result.get("data", {}).get("inSync") is True
                 and replay_result.get("data", {}).get("revision") == expected_revision,
                 "INTERFACE_PROTOCOL", "post-mutation replay state does not match the validated result", exit_code=4)
            fail(journal_state()[:2] == before_journal[:2], "IO_ERROR",
                 "event journal changed during post-mutation review", exit_code=3)
            self.verify_children(skip_mutable=True)
            for label, descriptor in replacements.items():
                info = os.fstat(descriptor); published = os.stat(label.split("/")[-1], dir_fd=graph,
                                                                 follow_symlinks=False)
                fail((info.st_dev, info.st_ino) == (published.st_dev, published.st_ino), "IO_ERROR",
                     "mutable graph leaf changed before capability adoption", label, 3)
            for label, descriptor in replacements.items():
                prior = self.leaves.get(label)
                self.leaves[label] = descriptor
                if prior is not None:
                    os.close(prior)
            replacements.clear()
            self.verify_children()
        finally:
            for descriptor in replacements.values():
                os.close(descriptor)

    def __enter__(self) -> "OperatorRoot":
        return self

    def __exit__(self, _kind: Any, _value: Any, _traceback: Any) -> None:
        for descriptor in self.children.values():
            os.close(descriptor)
        for descriptor in self.leaves.values():
            if descriptor is not None:
                os.close(descriptor)
        self.binding_manifest.close()
        os.close(self.fd)


def read_regular(path: Path, label: str, maximum: int) -> bytes:
    descriptor: Optional[int] = None
    try:
        expected = os.lstat(path)
        fail(stat.S_ISREG(expected.st_mode) and not stat.S_ISLNK(expected.st_mode), "IO_ERROR", f"{label} must be a regular file", str(path), 3)
        fail(expected.st_size <= maximum, "IO_ERROR", f"{label} exceeds {maximum} bytes", str(path), 3)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        actual = os.fstat(descriptor)
        fail(stat.S_ISREG(actual.st_mode) and (actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino),
             "IO_ERROR", f"{label} changed during open", str(path), 3)
        chunks: List[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            fail(total <= maximum, "IO_ERROR", f"{label} exceeds {maximum} bytes", str(path), 3)
        value = b"".join(chunks)
    except FlowError:
        raise
    except OSError as exc:
        raise FlowError("IO_ERROR", f"cannot read {label}", str(path), 3) from exc
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
    fail(len(value) <= maximum, "IO_ERROR", f"{label} exceeds {maximum} bytes", str(path), 3)
    return value


def read_anchored_regular_fd(root_fd: int, root_label: str, parts: Sequence[str],
                             label: str, maximum: int) -> bytes:
    fail(bool(parts) and all(part not in {"", ".", ".."} and "/" not in part for part in parts),
         "IO_ERROR", f"{label} path is invalid", list(parts), 3)
    descriptors: List[int] = []
    try:
        current = os.dup(root_fd)
        descriptors.append(current)
        root_info = os.fstat(current)
        fail(stat.S_ISDIR(root_info.st_mode) and root_info.st_uid == os.geteuid(),
             "IO_ERROR", f"{label} root must be an owned real directory", root_label, 3)
        for part in parts[:-1]:
            current = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
            descriptors.append(current)
            info = os.fstat(current)
            fail(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(),
                 "IO_ERROR", f"{label} parent must be an owned real directory", part, 3)
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=current)
        descriptors.append(descriptor)
        info = os.fstat(descriptor)
        fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1,
             "IO_ERROR", f"{label} must be an owned, singly linked regular file", parts[-1], 3)
        fail(info.st_size <= maximum, "IO_ERROR", f"{label} exceeds {maximum} bytes", parts[-1], 3)
        chunks: List[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            fail(total <= maximum, "IO_ERROR", f"{label} exceeds {maximum} bytes", parts[-1], 3)
        return b"".join(chunks)
    except FlowError:
        raise
    except OSError as exc:
        raise FlowError("IO_ERROR", f"cannot read {label} through its trusted root", {
            "root": root_label, "path": "/".join(parts), "error": str(exc),
        }, 3) from exc
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass


def read_anchored_regular(root: Path, parts: Sequence[str], label: str, maximum: int) -> bytes:
    descriptor: Optional[int] = None
    try:
        descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        return read_anchored_regular_fd(descriptor, str(root), parts, label, maximum)
    except FlowError:
        raise
    except OSError as exc:
        raise FlowError("IO_ERROR", f"cannot open trusted root for {label}", str(root), 3) from exc
    finally:
        if descriptor is not None:
            os.close(descriptor)


def trusted_source_root() -> Optional[Path]:
    raw = os.environ.get("OPERATOR_DESIGN_FLOW_TRUSTED_SOURCE_ROOT", "")
    if not raw:
        return None
    requested = owned_real_directory(Path(os.path.abspath(raw)), "trusted design-flow source root")
    script_dir = owned_real_directory(
        Path(os.path.abspath(os.environ["OPERATOR_DESIGN_FLOW_SCRIPT_DIR"])), "design-flow script directory",
    )
    expected = script_dir.parent
    fail(requested == expected, "IO_ERROR",
         "trusted design-flow source root must own the executing runtime", {
             "requested": str(requested), "expected": str(expected),
         }, 3)
    try:
        os.lstat(requested / "operator.config.env")
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise FlowError("IO_ERROR", "cannot classify trusted design-flow source root", str(exc), 3) from exc
    else:
        raise FlowError("IO_ERROR", "installed design-flow runtime cannot enable source-template mode",
                        str(requested), 3)
    read_anchored_regular(requested, ("scripts", "operator-bootstrap.sh"),
                          "trusted source bootstrap marker", MAX_INTERFACE_BYTES)
    read_anchored_regular(requested, ("plugins", "operator-kit", ".codex-plugin", "plugin.json"),
                          "trusted source plugin marker", MAX_INTERFACE_BYTES)
    return requested


def read_proposal_prompt(root: OperatorRoot) -> bytes:
    root.verify_path()
    source_root = trusted_source_root()
    if source_root is not None:
        return read_anchored_regular(source_root, ("templates", "prompts", "design-proposal.md"),
                                     "canonical source design proposal prompt template", MAX_BRIEF_BYTES)
    return read_anchored_regular_fd(root.fd, str(root.path), ("prompts", "design-proposal.md"),
                                    "installed design proposal prompt template", MAX_BRIEF_BYTES)


class FeatureWorkspace:
    def __init__(self, path: Path, identity: Tuple[int, int]):
        self.path = path
        self.identity = identity

    def __fspath__(self) -> str:
        return str(self.path)

    def __str__(self) -> str:
        return str(self.path)


def feature_workspace(root: OperatorRoot, feature_id: str) -> FeatureWorkspace:
    require_identifier(feature_id, "feature ID")
    features = root.path / "features"
    matches: List[FeatureWorkspace] = []
    try:
        expected = os.stat("features", dir_fd=root.fd, follow_symlinks=False)
        fail(stat.S_ISDIR(expected.st_mode) and not stat.S_ISLNK(expected.st_mode)
             and expected.st_uid == os.geteuid(), "IO_ERROR",
             "feature workspace root must be an owned real directory", str(features), 3)
        features_fd = os.open("features", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root.fd)
        actual = os.fstat(features_fd)
        fail((actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino)
             and stat.S_ISDIR(actual.st_mode) and actual.st_uid == os.geteuid(),
             "IO_ERROR", "feature workspace root changed during descriptor open", str(features), 3)
        names = sorted(os.listdir(features_fd))
    except OSError as exc:
        raise FlowError("IO_ERROR", "cannot open feature workspace root", str(features), 3) from exc
    try:
        for name in names:
            candidate_fd: Optional[int] = None
            status_fd: Optional[int] = None
            try:
                candidate_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=features_fd)
                info = os.fstat(candidate_fd)
                fail(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(), "IO_ERROR",
                     "feature workspace candidate must be an owned directory", name, 3)
                status_fd = os.open("status.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=candidate_fd)
                status_info = os.fstat(status_fd)
                fail(stat.S_ISREG(status_info.st_mode) and status_info.st_uid == os.geteuid()
                     and status_info.st_size <= MAX_INTERFACE_BYTES,
                     "IO_ERROR", "feature status must be an owned bounded regular file", name, 3)
                chunks: List[bytes] = []
                total = 0
                while True:
                    chunk = os.read(status_fd, min(65536, MAX_INTERFACE_BYTES + 1 - total))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    total += len(chunk)
                    fail(total <= MAX_INTERFACE_BYTES, "IO_ERROR", "feature status exceeds byte limit", name, 3)
                status_value = loads(b"".join(chunks), "feature status")
                fail(isinstance(status_value, dict), "IO_ERROR", "feature status must be an object", name, 3)
                if status_value.get("id") == feature_id:
                    matches.append(FeatureWorkspace(features / name, (info.st_dev, info.st_ino)))
            except FileNotFoundError:
                continue
            except OSError:
                continue
            finally:
                if status_fd is not None:
                    os.close(status_fd)
                if candidate_fd is not None:
                    os.close(candidate_fd)
    finally:
        os.close(features_fd)
    fail(len(matches) == 1, "FEATURE_NOT_FOUND" if not matches else "FEATURE_AMBIGUOUS",
         f"expected exactly one external feature workspace for {feature_id}", [str(item) for item in matches], 3)
    return matches[0]


class ArtifactStore:
    """Descriptor-anchored feature artifact access with no pathname re-resolution."""

    def __init__(self, workspace: FeatureWorkspace):
        self.workspace = workspace
        self.root_fd: Optional[int] = None

    def __enter__(self) -> "ArtifactStore":
        try:
            descriptor = os.open(self.workspace, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            info = os.fstat(descriptor)
        except OSError as exc:
            raise FlowError("IO_ERROR", "cannot open owned feature workspace", str(self.workspace), 3) from exc
        fail(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(), "IO_ERROR",
             "feature workspace must be an owned real directory", str(self.workspace), 3)
        fail((info.st_dev, info.st_ino) == self.workspace.identity, "IO_ERROR",
             "feature workspace identity changed between discovery and open", str(self.workspace), 3)
        self.root_fd = descriptor
        return self

    def __exit__(self, _kind: Any, _value: Any, _traceback: Any) -> None:
        if self.root_fd is not None:
            os.close(self.root_fd)
            self.root_fd = None

    @staticmethod
    def _parts(relative: str) -> Tuple[str, ...]:
        fail(isinstance(relative, str) and not relative.startswith("/"), "IO_ERROR",
             "artifact path must be relative", relative, 3)
        parts = tuple(relative.split("/"))
        fail(bool(parts) and all(part not in {"", ".", ".."} and "/" not in part and "\x00" not in part for part in parts),
             "IO_ERROR", "artifact path contains an unsafe component", relative, 3)
        return parts

    def _open_dir(self, parts: Sequence[str], create: bool) -> int:
        fail(self.root_fd is not None, "IO_ERROR", "artifact store is closed", exit_code=3)
        current = os.dup(self.root_fd)
        try:
            for part in parts:
                try:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
                except FileNotFoundError:
                    if not create:
                        raise
                    os.mkdir(part, 0o700, dir_fd=current)
                    os.fsync(current)
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
                info = os.fstat(child)
                fail(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(), "IO_ERROR",
                     "artifact component must be an owned real directory", part, 3)
                if stat.S_IMODE(info.st_mode) != 0o700:
                    os.fchmod(child, 0o700)
                    os.fsync(child)
                os.close(current)
                current = child
            return current
        except FlowError:
            os.close(current)
            raise
        except OSError as exc:
            os.close(current)
            raise FlowError("IO_ERROR", "cannot traverse artifact path without following links", str(exc), 3) from exc

    def ensure_dir(self, relative: str) -> None:
        descriptor = self._open_dir(self._parts(relative), create=True)
        os.close(descriptor)

    @staticmethod
    def _read_leaf(parent_fd: int, name: str, label: str, maximum: int) -> bytes:
        descriptor: Optional[int] = None
        try:
            expected = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            fail(stat.S_ISREG(expected.st_mode) and expected.st_uid == os.geteuid() and expected.st_nlink == 1,
                 "IO_ERROR", f"{label} must be an owned, single-link regular file", name, 3)
            descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
            actual = os.fstat(descriptor)
            fail((actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino)
                 and stat.S_ISREG(actual.st_mode) and actual.st_nlink == 1,
                 "IO_ERROR", f"{label} changed during descriptor open", name, 3)
            if stat.S_IMODE(actual.st_mode) != 0o600:
                os.fchmod(descriptor, 0o600)
                os.fsync(descriptor)
                actual = os.fstat(descriptor)
            fail(actual.st_size <= maximum, "IO_ERROR", f"{label} exceeds {maximum} bytes", name, 3)
            baseline = (actual.st_dev, actual.st_ino, actual.st_size, actual.st_mtime_ns, actual.st_ctime_ns, actual.st_nlink)
            chunks: List[bytes] = []
            total = 0
            while True:
                chunk = os.read(descriptor, min(65536, maximum + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                fail(total <= maximum, "IO_ERROR", f"{label} exceeds {maximum} bytes", name, 3)
            after = os.fstat(descriptor)
            observed = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns, after.st_nlink)
            fail(observed == baseline, "IO_ERROR", f"{label} changed during read", name, 3)
            return b"".join(chunks)
        except FlowError:
            raise
        except OSError as exc:
            raise FlowError("IO_ERROR", f"cannot read {label} without following links", name, 3) from exc
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def write_once(self, relative: str, data: bytes) -> None:
        parts = self._parts(relative)
        parent_fd = self._open_dir(parts[:-1], create=True)
        name = parts[-1]
        temporary = f".{name}.{os.getpid()}.{time.monotonic_ns()}.tmp"
        descriptor: Optional[int] = None
        try:
            try:
                existing = self._read_leaf(parent_fd, name, "existing artifact", max(len(data), MAX_BRIEF_BYTES))
                fail(existing == data, "ARTIFACT_CONFLICT",
                     "existing artifact differs from the idempotent request", relative, 6)
                return
            except FlowError as exc:
                if exc.code != "IO_ERROR" or "cannot read" not in exc.message:
                    raise
                try:
                    os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    raise
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=parent_fd)
            offset = 0
            while offset < len(data):
                written = os.write(descriptor, data[offset:])
                if written <= 0:
                    raise OSError("short write")
                offset += written
            os.fsync(descriptor)
            created = os.fstat(descriptor)
            fail(stat.S_ISREG(created.st_mode) and created.st_uid == os.geteuid() and created.st_nlink == 1,
                 "IO_ERROR", "new artifact identity is unsafe", relative, 3)
            os.close(descriptor)
            descriptor = None
            created_identity = (created.st_dev, created.st_ino)
            published = False
            try:
                os.link(temporary, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd, follow_symlinks=False)
                linked = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                fail((linked.st_dev, linked.st_ino) == created_identity and linked.st_nlink == 2,
                     "IO_ERROR", "new artifact changed during atomic publication", relative, 3)
                published = True
            except FileExistsError:
                existing = self._read_leaf(parent_fd, name, "existing artifact", max(len(data), MAX_BRIEF_BYTES))
                fail(existing == data, "ARTIFACT_CONFLICT",
                     "concurrent artifact differs from the idempotent request", relative, 6)
            finally:
                os.unlink(temporary, dir_fd=parent_fd)
            if published:
                final = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                fail((final.st_dev, final.st_ino) == created_identity and final.st_nlink == 1
                     and stat.S_ISREG(final.st_mode) and final.st_uid == os.geteuid()
                     and stat.S_IMODE(final.st_mode) == 0o600,
                     "IO_ERROR", "new artifact changed after atomic publication", relative, 3)
            os.fsync(parent_fd)
        except FlowError:
            raise
        except OSError as exc:
            try:
                os.unlink(temporary, dir_fd=parent_fd)
            except OSError:
                pass
            raise FlowError("IO_ERROR", "cannot publish artifact through anchored descriptor", relative, 3) from exc
        finally:
            if descriptor is not None:
                os.close(descriptor)
            os.close(parent_fd)

    def inventory(self, relative: str) -> List[Dict[str, Any]]:
        parts = self._parts(relative)
        try:
            root_fd = self._open_dir(parts, create=False)
        except FlowError as exc:
            if exc.code == "IO_ERROR" and isinstance(exc.details, str) and "No such file" in exc.details:
                return []
            raise
        result: List[Dict[str, Any]] = []
        total = 0

        def scan(directory_fd: int, prefix: str) -> None:
            nonlocal total
            try:
                names = sorted(os.listdir(directory_fd))
            except OSError as exc:
                raise FlowError("IO_ERROR", "cannot list anchored artifact directory", prefix, 3) from exc
            for name in names:
                info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                child_relative = f"{prefix}/{name}"
                if stat.S_ISDIR(info.st_mode):
                    child_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory_fd)
                    opened = os.fstat(child_fd)
                    fail((opened.st_dev, opened.st_ino) == (info.st_dev, info.st_ino)
                         and opened.st_uid == os.geteuid(), "IO_ERROR",
                         "artifact directory changed during descriptor open", child_relative, 3)
                    if stat.S_IMODE(opened.st_mode) != 0o700:
                        os.fchmod(child_fd, 0o700)
                        os.fsync(child_fd)
                    try:
                        scan(child_fd, child_relative)
                    finally:
                        os.close(child_fd)
                elif stat.S_ISREG(info.st_mode):
                    data = self._read_leaf(directory_fd, name, "artifact evidence", MAX_EVIDENCE_FILE_BYTES)
                    total += len(data)
                    fail(total <= MAX_EVIDENCE_TOTAL_BYTES and len(result) < 1000,
                         "IO_ERROR", "artifact inventory exceeds bounds", relative, 3)
                    result.append({"path": child_relative, "sha256": file_digest(data), "size": len(data)})
                else:
                    raise FlowError("IO_ERROR", "artifact inventory contains a link or special file", child_relative, 3)

        try:
            scan(root_fd, relative)
        finally:
            os.close(root_fd)
        return result


def file_digest(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def valid_text(value: Any, maximum: int, pattern: Optional[re.Pattern[str]] = None) -> bool:
    return (isinstance(value, str) and 1 <= len(value) <= maximum and bool(value.strip())
            and not any(ord(ch) < 32 or 127 <= ord(ch) <= 159 or 0xD800 <= ord(ch) <= 0xDFFF for ch in value)
            and (pattern is None or pattern.fullmatch(value) is not None))


def family(kind: str) -> str:
    if kind in CONTAINER_KINDS:
        return "container"
    if kind in WORK_KINDS:
        return "work"
    return "gate"


def canonical_time(value: Any, label: str) -> dt.datetime:
    fail(isinstance(value, str) and value.endswith("Z") and len(value) <= 64,
         "INTERFACE_PROTOCOL", f"{label} is not a canonical UTC timestamp", value, 4)
    try:
        parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00").astimezone(dt.timezone.utc)
    except (ValueError, OverflowError) as exc:
        raise FlowError("INTERFACE_PROTOCOL", f"{label} is invalid", str(exc), 4) from exc
    normalized = parsed.isoformat(timespec="microseconds").replace("+00:00", "Z")
    fail(normalized == value, "INTERFACE_PROTOCOL", f"{label} is not canonically formatted", value, 4)
    return parsed


def validate_lease(node_id: str, value: Any, nodes: Mapping[str, Mapping[str, Any]], updated_at: dt.datetime) -> None:
    lease = exact(value, {"schemaVersion", "nodeId", "leaseId", "holder", "acquiredAt", "renewedAt",
                          "expiresAt", "fence", "clock"}, f"lease for {node_id}")
    fail(lease.get("schemaVersion") == "operator.ownership-lease/v1" and lease.get("nodeId") == node_id,
         "INTERFACE_PROTOCOL", "lease identity is invalid", node_id, 4)
    fail(node_id in nodes and nodes[node_id]["kind"] in WORK_KINDS and valid_text(lease.get("leaseId"), 256, ID_RE)
         and integer(lease.get("fence"), 1), "INTERFACE_PROTOCOL", "lease scalar domain is invalid", node_id, 4)
    acquired = canonical_time(lease.get("acquiredAt"), "lease acquiredAt")
    renewed = canonical_time(lease.get("renewedAt"), "lease renewedAt")
    expires = canonical_time(lease.get("expiresAt"), "lease expiresAt")
    fail(acquired <= renewed < expires and acquired <= updated_at, "INTERFACE_PROTOCOL",
         "lease timestamps are invalid", node_id, 4)
    holder = exact(lease.get("holder"), {"actorType", "actorId", "bindingId", "bindingGeneration",
                                           "bindingHash", "scope", "laneNodeId"}, "lease holder")
    fail(holder.get("actorType") in {"lane", "host"} and valid_text(holder.get("actorId"), 256, ID_RE)
         and valid_text(holder.get("bindingId"), 128, BINDING_ID_RE)
         and integer(holder.get("bindingGeneration"), 1)
         and isinstance(holder.get("bindingHash"), str) and HASH_RE.fullmatch(holder["bindingHash"]) is not None
         and valid_text(holder.get("scope"), 512, ID_RE) and valid_text(holder.get("laneNodeId"), 128, ID_RE),
         "INTERFACE_PROTOCOL", "lease holder domain is invalid", node_id, 4)
    clock = exact(lease.get("clock"), {"hostId", "bootId", "monotonicSource", "acquiredMonotonicNs",
                                        "expiresMonotonicNs"}, "lease clock")
    fail(valid_text(clock.get("hostId"), 256) and valid_text(clock.get("bootId"), 256)
         and clock.get("monotonicSource") in {"linux-proc-uptime", "macos-mach-continuous"}
         and integer(clock.get("acquiredMonotonicNs")) and integer(clock.get("expiresMonotonicNs"), 1)
         and clock["expiresMonotonicNs"] > clock["acquiredMonotonicNs"],
         "INTERFACE_PROTOCOL", "lease clock domain is invalid", node_id, 4)


def validate_snapshot(value: Any) -> Mapping[str, Any]:
    if isinstance(value, dict) and value.get("ok") is True:
        exact(value, {"ok", "command", "data"}, "graph snapshot envelope")
        fail(value.get("command") in {"snapshot", "status"}, "INTERFACE_PROTOCOL", "snapshot command is invalid", exit_code=4)
        value = value.get("data")
    required = {"schemaVersion", "graphId", "revision", "definitionRevision", "definitionHash", "updatedAt",
                "eventCount", "nodes", "edges", "leases", "leaseFences", "executionStarted", "reconciliations",
                "bindingGenerations", "authorityKeyId", "authorityHash"}
    snapshot = exact(value, required, "control snapshot")
    fail(snapshot.get("schemaVersion") == SNAPSHOT_VERSION and valid_text(snapshot.get("graphId"), 128, ID_RE),
         "INTERFACE_PROTOCOL", "control snapshot identity is invalid", exit_code=4)
    for counter in ("revision", "definitionRevision", "eventCount"):
        fail(integer(snapshot.get(counter), 1), "INTERFACE_PROTOCOL", f"snapshot {counter} is invalid", exit_code=4)
    fail(snapshot["eventCount"] == snapshot["revision"] and snapshot["definitionRevision"] <= snapshot["revision"],
         "INTERFACE_PROTOCOL", "snapshot counters are inconsistent", exit_code=4)
    fail(isinstance(snapshot.get("definitionHash"), str) and HASH_RE.fullmatch(snapshot["definitionHash"]) is not None
         and valid_text(snapshot.get("authorityKeyId"), 128, ID_RE)
         and isinstance(snapshot.get("authorityHash"), str) and HASH_RE.fullmatch(snapshot["authorityHash"]) is not None,
         "INTERFACE_PROTOCOL", "snapshot hash or authority identity is invalid", exit_code=4)
    updated_at = canonical_time(snapshot.get("updatedAt"), "snapshot updatedAt")
    fail(isinstance(snapshot.get("nodes"), list) and len(snapshot["nodes"]) <= 10000
         and isinstance(snapshot.get("edges"), list) and len(snapshot["edges"]) <= 50000,
         "INTERFACE_PROTOCOL", "control snapshot graph arrays are invalid", exit_code=4)
    nodes: Dict[str, Mapping[str, Any]] = {}
    for index, node in enumerate(snapshot["nodes"]):
        exact(node, {"id", "kind", "title", "initialState", "priority", "metadata", "state"}, f"snapshot node {index}")
        node_id, kind = node.get("id"), node.get("kind")
        fail(valid_text(node_id, 128, ID_RE) and node_id not in nodes and kind in NODE_KINDS,
             "INTERFACE_PROTOCOL", "snapshot node ID or kind is invalid", node_id, 4)
        node_family = family(str(kind))
        fail(node.get("initialState") == INITIAL[node_family] and node.get("state") in STATES[node_family]
             and valid_text(node.get("title"), 512) and integer(node.get("priority")) and node["priority"] <= 1000
             and isinstance(node.get("metadata"), dict) and len(canonical(node["metadata"])) <= 64 * 1024,
             "INTERFACE_PROTOCOL", "snapshot node domain is invalid", node_id, 4)
        execution = node["metadata"].get("execution")
        if execution is not None:
            exact(execution, {"idempotent", "reclaimable"}, "execution metadata")
            fail(all(isinstance(execution[key], bool) for key in execution), "INTERFACE_PROTOCOL",
                 "execution metadata must contain booleans", node_id, 4)
        nodes[str(node_id)] = node
    edge_ids: Set[str] = set()
    triples: Set[Tuple[str, str, str]] = set()
    adjacency: Dict[str, List[str]] = {node_id: [] for node_id in nodes}
    indegree: Dict[str, int] = {node_id: 0 for node_id in nodes}
    for index, item in enumerate(snapshot["edges"]):
        edge_value = exact(item, {"id", "kind", "from", "to", "metadata"}, f"snapshot edge {index}")
        edge_id, kind, source, target = edge_value.get("id"), edge_value.get("kind"), edge_value.get("from"), edge_value.get("to")
        fail(valid_text(edge_id, 384, ID_RE) and edge_id not in edge_ids and kind in EDGE_KINDS
             and source in nodes and target in nodes and source != target,
             "INTERFACE_PROTOCOL", "snapshot edge identity is invalid", edge_id, 4)
        allowed_from, allowed_to = ENDPOINTS[str(kind)]
        triple = (str(kind), str(source), str(target))
        fail(nodes[str(source)]["kind"] in allowed_from and nodes[str(target)]["kind"] in allowed_to
             and triple not in triples and isinstance(edge_value.get("metadata"), dict)
             and len(canonical(edge_value["metadata"])) <= 64 * 1024,
             "INTERFACE_PROTOCOL", "snapshot edge domain is invalid", edge_id, 4)
        if kind == "gated-by":
            exact(edge_value["metadata"], {"protectedTransitions"}, "gated-by metadata")
            protected = edge_value["metadata"].get("protectedTransitions")
            targets = {"container": {"active", "blocked", "completed", "cancelled"},
                       "work": {"ready", "active", "blocked", "completed", "failed", "cancelled"}}[family(nodes[str(source)]["kind"])]
            fail(isinstance(protected, list) and protected == sorted(set(protected)) and bool(protected)
                 and all(entry in targets for entry in protected),
                 "INTERFACE_PROTOCOL", "gated-by transition domain is invalid", edge_id, 4)
            if nodes[str(source)]["kind"] == "integration":
                fail({"ready", "active", "completed"} <= set(protected), "INTERFACE_PROTOCOL",
                     "integration gate coverage is invalid", edge_id, 4)
        edge_ids.add(str(edge_id))
        triples.add(triple)
        if kind in {"contains", "depends-on"}:
            adjacency[str(source)].append(str(target))
            indegree[str(target)] += 1
    queue = [node_id for node_id, count in indegree.items() if count == 0]
    visited = 0
    while queue:
        source = queue.pop()
        visited += 1
        for target in adjacency[source]:
            indegree[target] -= 1
            if indegree[target] == 0:
                queue.append(target)
    fail(visited == len(nodes), "INTERFACE_PROTOCOL", "snapshot contains/depends-on graph is cyclic", exit_code=4)

    leases = snapshot.get("leases")
    fail(isinstance(leases, dict) and len(leases) <= 10000, "INTERFACE_PROTOCOL", "snapshot leases are invalid", exit_code=4)
    for node_id, lease in leases.items():
        validate_lease(node_id, lease, nodes, updated_at)
    fences = snapshot.get("leaseFences")
    fail(isinstance(fences, dict) and len(fences) <= 10000, "INTERFACE_PROTOCOL", "snapshot lease fences are invalid", exit_code=4)
    for node_id, fence in fences.items():
        fail(node_id in nodes and nodes[node_id]["kind"] in WORK_KINDS and integer(fence, 1),
             "INTERFACE_PROTOCOL", "snapshot lease fence domain is invalid", node_id, 4)
        if node_id in leases:
            fail(leases[node_id]["fence"] == fence, "INTERFACE_PROTOCOL", "live lease fence mismatch", node_id, 4)
    started = snapshot.get("executionStarted")
    fail(isinstance(started, dict) and len(started) <= 10000, "INTERFACE_PROTOCOL", "executionStarted is invalid", exit_code=4)
    for node_id, marker_value in started.items():
        marker = exact(marker_value, {"revision", "occurredAt"}, "execution marker")
        fail(node_id in nodes and nodes[node_id]["kind"] in WORK_KINDS and integer(marker.get("revision"), 1)
             and marker["revision"] <= snapshot["revision"] and canonical_time(marker.get("occurredAt"), "execution occurredAt") <= updated_at,
             "INTERFACE_PROTOCOL", "execution marker domain is invalid", node_id, 4)
    fail(set(leases) <= set(started), "INTERFACE_PROTOCOL", "live lease lacks execution marker", exit_code=4)
    reconciliations = snapshot.get("reconciliations")
    fail(isinstance(reconciliations, dict) and len(reconciliations) <= 10000,
         "INTERFACE_PROTOCOL", "snapshot reconciliations are invalid", exit_code=4)
    for node_id, record_value in reconciliations.items():
        record = exact(record_value, {"leaseId", "fence", "reason", "requiredAt", "priorState"}, "reconciliation")
        fail(node_id in nodes and nodes[node_id]["kind"] in WORK_KINDS and node_id not in leases
             and valid_text(record.get("leaseId"), 256, ID_RE) and integer(record.get("fence"), 1)
             and record.get("reason") in {"expired-unsafe", "binding-rotated", "clock-recovery"}
             and record.get("priorState") in STATES["work"] and canonical_time(record.get("requiredAt"), "reconciliation requiredAt") <= updated_at
             and node_id in started and fences.get(node_id) == record["fence"],
             "INTERFACE_PROTOCOL", "reconciliation domain is invalid", node_id, 4)
    generations = snapshot.get("bindingGenerations")
    fail(isinstance(generations, dict) and len(generations) <= 10000,
         "INTERFACE_PROTOCOL", "bindingGenerations is invalid", exit_code=4)
    for binding_id, record_value in generations.items():
        record = exact(record_value, {"generation", "bindingHash"}, "binding generation")
        fail(valid_text(binding_id, 128, BINDING_ID_RE) and integer(record.get("generation"), 1)
             and isinstance(record.get("bindingHash"), str) and HASH_RE.fullmatch(record["bindingHash"]) is not None,
             "INTERFACE_PROTOCOL", "binding generation domain is invalid", binding_id, 4)
    assigned = {(edge["from"], edge["to"]) for edge in snapshot["edges"] if edge["kind"] == "assigned-to"}
    for node_id, lease in leases.items():
        fail((node_id, lease["holder"]["laneNodeId"]) in assigned, "INTERFACE_PROTOCOL",
             "lease holder lane is not assigned", node_id, 4)
    return snapshot


def snapshot(root: OperatorRoot) -> Mapping[str, Any]:
    raw = bounded_command(root, command_path("OPERATOR_DESIGN_FLOW_SNAPSHOT_COMMAND", "operator-graph.sh"), None,
                          "trusted graph snapshot provider", "snapshot")
    return validate_snapshot(load_interface(raw, "trusted graph snapshot"))


def node_index(value: Mapping[str, Any]) -> Dict[str, Mapping[str, Any]]:
    return {str(node["id"]): node for node in value["nodes"]}


def definition_from_snapshot(value: Mapping[str, Any]) -> Dict[str, Any]:
    nodes = []
    for node in value["nodes"]:
        nodes.append({key: node[key] for key in ("id", "kind", "title", "initialState", "priority", "metadata")})
    return {"schemaVersion": GRAPH_VERSION, "graphId": value["graphId"], "nodes": nodes, "edges": list(value["edges"])}


def edge(kind: str, source: str, target: str, metadata: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    return {"id": f"{kind}:{source}:{target}", "kind": kind, "from": source, "to": target,
            "metadata": dict(metadata or {})}


def promotion_ids(feature_id: str) -> Tuple[str, str]:
    return f"{feature_id}-production-publish", f"{feature_id}-production-publish-gate"


def feature_status(workspace: FeatureWorkspace) -> Tuple[Mapping[str, Any], str]:
    raw = Path(workspace.path, "status.json").read_bytes()
    fail(len(raw) <= MAX_INTERFACE_BYTES, "IO_ERROR", "feature status exceeds byte limit", exit_code=3)
    value = loads(raw, "feature status")
    fail(isinstance(value, dict), "IO_ERROR", "feature status must be an object", exit_code=3)
    return value, "sha256:" + hashlib.sha256(raw).hexdigest()


def promote_feature(root: OperatorRoot, args: argparse.Namespace) -> Mapping[str, Any]:
    workspace = feature_workspace(root, args.feature)
    status, status_hash = feature_status(workspace)
    fail(status.get("id") == args.feature and status.get("project") == "cadence",
         "GRAPH_PRECONDITION", "feature status identity is invalid", exit_code=6)
    value = snapshot(root)
    nodes = node_index(value)
    task_id, gate_id = promotion_ids(args.feature)
    if args.feature in nodes:
        fail(task_id in nodes and gate_id in nodes, "FLOW_CORRUPT",
             "feature promotion is partial", exit_code=6)
        return {"ok": True, "command": "promote", "data": {
            "featureId": args.feature, "taskNodeId": task_id, "gateNodeId": gate_id,
            "gateState": nodes[gate_id]["state"], "revision": value["revision"]}}
    fail("operator-control" in nodes and nodes["operator-control"]["kind"] == "goal",
         "GRAPH_PRECONDITION", "operator-control goal is missing", exit_code=6)
    fail(args.lane in nodes and nodes[args.lane]["kind"] == "lane",
         "GRAPH_PRECONDITION", "promotion lane is missing", exit_code=6)
    claims = status.get("claims", {})
    resources = sorted(set(claims.get("resources", []))) if isinstance(claims, dict) else []
    definition = definition_from_snapshot(value)
    promotion = {"featureId": args.feature, "featureStatusHash": status_hash,
                 "laneNodeId": args.lane, "taskNodeId": task_id, "gateNodeId": gate_id,
                 "operation": PUBLISH_FLOW}
    definition["nodes"].extend([
        {"id": args.feature, "kind": "feature", "title": str(status.get("title", args.feature)),
         "initialState": "planned", "priority": args.priority,
         "metadata": {"featureSessionId": args.feature, "featurePromotion": promotion}},
        {"id": task_id, "kind": "task", "title": args.title, "initialState": "pending",
         "priority": args.priority,
         "metadata": {"execution": {"idempotent": True, "reclaimable": False},
                      "featurePromotion": promotion,
                      "scheduler": {"claims": {"contracts": ["production-publish"],
                                                   "files": [], "resources": resources}}}},
        {"id": gate_id, "kind": "human-gate", "title": f"Authorize {args.feature} production publish",
         "initialState": "pending", "priority": args.priority,
         "metadata": {"featurePromotion": promotion}},
    ])
    definition["edges"].extend([
        edge("contains", "operator-control", args.feature),
        edge("contains", args.feature, task_id),
        edge("contains", args.feature, gate_id),
        edge("assigned-to", task_id, args.lane),
        edge("gated-by", task_id, gate_id,
             {"protectedTransitions": ["active", "completed", "ready"]}),
    ])
    graph_mutate(root, "replace-definition", f"feature-promote-{args.feature}-{PUBLISH_FLOW}", value,
                 {"action": "promote", "featureId": args.feature, "flowId": PUBLISH_FLOW},
                 definition=definition)
    current = snapshot(root)
    current_nodes = node_index(current)
    return {"ok": True, "command": "promote", "data": {
        "featureId": args.feature, "taskNodeId": task_id, "gateNodeId": gate_id,
        "gateState": current_nodes[gate_id]["state"], "revision": current["revision"]}}


def authorize_publish(root: OperatorRoot, args: argparse.Namespace) -> Mapping[str, Any]:
    value = snapshot(root)
    nodes = node_index(value)
    task_id, gate_id = promotion_ids(args.feature)
    fail(args.feature in nodes and task_id in nodes and gate_id in nodes,
         "GRAPH_PRECONDITION", "feature promotion is missing", exit_code=6)
    if nodes[gate_id]["state"] == "pending":
        graph_mutate(root, "gate decide", f"feature-authorize-{args.feature}-{PUBLISH_FLOW}", value,
                     {"action": "authorize-publish", "featureId": args.feature,
                      "flowId": PUBLISH_FLOW}, gate_node_id=gate_id, decision="approved")
        value = snapshot(root)
        nodes = node_index(value)
    fail(nodes[gate_id]["state"] == "approved", "GATE_REJECTED",
         "production publish gate is not approved", exit_code=6)
    return {"ok": True, "command": "authorize-publish", "data": {
        "featureId": args.feature, "taskNodeId": task_id, "gateNodeId": gate_id,
        "gateState": "approved", "revision": value["revision"]}}


def flow_prefix(feature_id: str, flow_id: str) -> str:
    readable = re.sub(r"[^A-Za-z0-9._-]+", "-", f"{feature_id}-{flow_id}").strip("-")[:48] or "flow"
    digest = hashlib.sha256((feature_id + "\x00" + flow_id).encode("utf-8")).hexdigest()[:16]
    return f"design-flow-{readable}-{digest}"


def validate_context(value: Mapping[str, Any], feature_id: str, feature_node: str, lane_node: Optional[str]) -> None:
    nodes = node_index(value)
    fail(feature_node in nodes and nodes[feature_node]["kind"] == "feature", "GRAPH_PRECONDITION",
         f"feature graph node is missing or not a feature: {feature_node}", exit_code=6)
    if lane_node is not None:
        fail(lane_node in nodes and nodes[lane_node]["kind"] == "lane", "GRAPH_PRECONDITION",
             f"lane graph node is missing or not a lane: {lane_node}", exit_code=6)
    feature_metadata = nodes[feature_node].get("metadata", {})
    session = feature_metadata.get("featureSessionId") if isinstance(feature_metadata, dict) else None
    fail(session in {None, feature_id}, "GRAPH_PRECONDITION", "feature session identity conflicts with graph node", exit_code=6)


def graph_mutate(root: OperatorRoot, command: str, request_id: str, value: Mapping[str, Any],
                 cli_intent: Mapping[str, Any],
                 definition: Optional[Mapping[str, Any]] = None,
                 gate_node_id: Optional[str] = None, decision: Optional[str] = None) -> Mapping[str, Any]:
    expected_revision = int(value["revision"])
    normalized_definition = None
    if definition is not None:
        normalized_definition = dict(definition)
        normalized_definition["nodes"] = sorted(definition["nodes"], key=lambda item: item["id"])
        normalized_definition["edges"] = sorted(definition["edges"], key=lambda item: item["id"])
    request = {
        "schemaVersion": GRAPH_REQUEST_VERSION, "command": command, "requestId": request_id,
        "graphId": value["graphId"], "expectedRevision": expected_revision,
        "cliIntent": dict(cli_intent),
        "definition": normalized_definition,
        "gateNodeId": gate_node_id, "decision": decision,
    }
    raw = bounded_command(root, command_path("OPERATOR_DESIGN_FLOW_MUTATION_COMMAND", "operator-graph.sh"), request,
                          "trusted graph mutation launcher", "mutation")
    result = load_interface(raw, "trusted graph mutation result")
    exact(result, {"ok", "command", "requestId", "revision", "data"}, "graph mutation result")
    expected_command = "replace-definition" if command == "replace-definition" else "gate decide"
    fail(result.get("ok") is True and result.get("command") == expected_command and result.get("requestId") == request_id,
         "INTERFACE_PROTOCOL", "graph mutation result identity is invalid", result, 4)
    fail(result.get("revision") == expected_revision + 1, "INTERFACE_PROTOCOL",
         "graph mutation result revision must equal expectedRevision + 1", result.get("revision"), 4)
    data = result.get("data")
    if command == "replace-definition":
        exact(data, {"graphId", "definitionRevision", "nodes", "edges"}, "definition replacement result")
        fail(data.get("graphId") == value["graphId"] and data.get("definitionRevision") == value["definitionRevision"] + 1,
             "INTERFACE_PROTOCOL", "definition replacement result is not bound to the snapshot", data, 4)
        fail(definition is not None and data.get("nodes") == len(definition["nodes"]) and data.get("edges") == len(definition["edges"]),
             "INTERFACE_PROTOCOL", "definition replacement counts are invalid", data, 4)
    else:
        exact(data, {"nodeId", "from", "to"}, "gate decision result")
        fail(data == {"nodeId": gate_node_id, "from": "pending", "to": decision},
             "INTERFACE_PROTOCOL", "gate decision result is invalid", data, 4)
    root.refresh_mutable_graph_leaves(request_id, expected_revision + 1)
    return result


def node_metadata(feature_id: str, flow_id: str, role: str, artifact: str,
                  proposal: Optional[str] = None, extra: Optional[Mapping[str, Any]] = None,
                  reclaimable: bool = True) -> Dict[str, Any]:
    design: Dict[str, Any] = {"featureId": feature_id, "flowId": flow_id, "role": role, "artifactPath": artifact}
    if proposal is not None:
        design["proposal"] = proposal
    if extra:
        design.update(extra)
    return {
        "designFlow": design,
        "execution": {"idempotent": reclaimable, "reclaimable": reclaimable},
        "scheduler": {"claims": {"contracts": ["design-flow"], "files": [], "resources": []}},
    }


def assert_node_shape(node: Mapping[str, Any], expected: Mapping[str, Any], label: str) -> None:
    actual = {key: node[key] for key in ("id", "kind", "title", "initialState", "priority", "metadata")}
    fail(actual == expected, "FLOW_CORRUPT", f"{label} immutable identity does not match canonical flow", {
        "expected": expected, "actual": actual,
    }, 6)


def validate_flow_topology(value: Mapping[str, Any], feature_id: str, flow_id: str,
                           allow_missing: bool = False,
                           allow_approved_without_implementation: bool = True) -> Optional[Dict[str, Any]]:
    nodes = node_index(value)
    prefix = flow_prefix(feature_id, flow_id)
    proposal_ids = {proposal: f"{prefix}-{proposal}" for proposal in PROPOSALS}
    gate_id = f"{prefix}-selection-gate"
    implementation_id = f"{prefix}-implementation"
    scoped = []
    for node in value["nodes"]:
        design = node["metadata"].get("designFlow")
        if isinstance(design, dict) and design.get("featureId") == feature_id and design.get("flowId") == flow_id:
            scoped.append(node)
    prefixed = [node for node in value["nodes"] if node["id"].startswith(prefix + "-")]
    if gate_id not in nodes:
        fail(not scoped and not prefixed and not any(node_id in nodes for node_id in proposal_ids.values()),
             "FLOW_CORRUPT", "existing design flow is partial or uses an impostor identity", exit_code=6)
        if allow_missing:
            return None
        raise FlowError("FLOW_NOT_FOUND", f"design flow not found for {feature_id}/{flow_id}", exit_code=6)
    gate = nodes[gate_id]
    gate_design = gate["metadata"].get("designFlow")
    required_gate_fields = {"featureId", "flowId", "role", "artifactPath", "featureNodeId",
                            "proposalLaneNodeId", "flowTitle", "proposalPriority", "options",
                            "briefHash", "briefArtifact"}
    fail(isinstance(gate_design, dict) and set(gate_design) == required_gate_fields,
         "FLOW_CORRUPT", "selection gate intent metadata is invalid", gate_id, 6)
    intent = {
        "featureNodeId": gate_design["featureNodeId"], "proposalLaneNodeId": gate_design["proposalLaneNodeId"],
        "flowTitle": gate_design["flowTitle"], "proposalPriority": gate_design["proposalPriority"],
        "briefHash": gate_design["briefHash"], "briefArtifact": gate_design["briefArtifact"],
    }
    fail(valid_text(intent["featureNodeId"], 128, ID_RE) and valid_text(intent["proposalLaneNodeId"], 128, ID_RE)
         and valid_text(intent["flowTitle"], 512) and integer(intent["proposalPriority"])
         and intent["proposalPriority"] <= 1000 and isinstance(intent["briefHash"], str)
         and HASH_RE.fullmatch(intent["briefHash"]) is not None
         and intent["briefArtifact"] == "work/design-options/brief.md"
         and gate_design["options"] == list(PROPOSALS),
         "FLOW_CORRUPT", "selection gate immutable intent domain is invalid", gate_id, 6)
    expected_gate_metadata = node_metadata(feature_id, flow_id, "selection-gate", "work/design-options",
        extra={**intent, "options": list(PROPOSALS)}, reclaimable=False)
    assert_node_shape(gate, {"id": gate_id, "kind": "human-gate", "title": f"Select {intent['flowTitle']}",
        "initialState": "pending", "priority": intent["proposalPriority"], "metadata": expected_gate_metadata},
        "selection gate")
    proposals: Dict[str, Mapping[str, Any]] = {}
    expected_nodes: Set[str] = {gate_id}
    expected_edges: List[Dict[str, Any]] = [edge("contains", intent["featureNodeId"], gate_id)]
    for proposal in PROPOSALS:
        node_id = proposal_ids[proposal]
        fail(node_id in nodes, "FLOW_CORRUPT", "canonical proposal node is missing", node_id, 6)
        expected_metadata = node_metadata(feature_id, flow_id, "proposal", f"work/design-options/{proposal}", proposal,
            {**intent})
        assert_node_shape(nodes[node_id], {"id": node_id, "kind": "task",
            "title": f"{intent['flowTitle']}: {proposal}", "initialState": "pending",
            "priority": intent["proposalPriority"], "metadata": expected_metadata}, f"proposal {proposal}")
        proposals[proposal] = nodes[node_id]
        expected_nodes.add(node_id)
        expected_edges.extend((edge("contains", intent["featureNodeId"], node_id),
                               edge("assigned-to", node_id, intent["proposalLaneNodeId"])))

    implementation = nodes.get(implementation_id)
    if implementation is not None:
        design = implementation["metadata"].get("designFlow")
        fields = {"featureId", "flowId", "role", "artifactPath", "featureNodeId", "implementationLaneNodeId",
                  "implementationPriority", "selectedProposal", "selectionGate"}
        fail(isinstance(design, dict) and set(design) == fields and design.get("selectedProposal") in PROPOSALS
             and valid_text(design.get("implementationLaneNodeId"), 128, ID_RE)
             and integer(design.get("implementationPriority")) and design["implementationPriority"] <= 1000,
             "FLOW_CORRUPT", "implementation intent metadata is invalid", implementation_id, 6)
        selected = design["selectedProposal"]
        expected_metadata = node_metadata(feature_id, flow_id, "implementation", f"work/design-options/{selected}",
            extra={"featureNodeId": intent["featureNodeId"], "implementationLaneNodeId": design["implementationLaneNodeId"],
                   "implementationPriority": design["implementationPriority"], "selectedProposal": selected,
                   "selectionGate": gate_id}, reclaimable=False)
        assert_node_shape(implementation, {"id": implementation_id, "kind": "task",
            "title": f"Implement {selected}", "initialState": "pending", "priority": design["implementationPriority"],
            "metadata": expected_metadata}, "implementation")
        fail(gate["state"] in {"pending", "approved"}, "FLOW_CORRUPT",
             "implementation exists without an exact pending/approved selection", gate["state"], 6)
        expected_nodes.add(implementation_id)
        expected_edges.extend((edge("contains", intent["featureNodeId"], implementation_id),
                               edge("assigned-to", implementation_id, design["implementationLaneNodeId"]),
                               edge("gated-by", implementation_id, gate_id,
                                    {"protectedTransitions": ["active", "completed"]})))
        expected_edges.extend(edge("depends-on", implementation_id, proposal_ids[proposal]) for proposal in PROPOSALS)
    else:
        fail(gate["state"] != "approved" or allow_approved_without_implementation, "FLOW_CORRUPT",
             "approved selection gate has no canonical implementation", gate_id, 6)

    improvements = []
    for node in scoped:
        design = node["metadata"]["designFlow"]
        if design.get("role") != "improvement":
            continue
        improvements.append(node)
    improvements.sort(key=lambda item: item["metadata"]["designFlow"].get("sequence", -1))
    fail([node["metadata"]["designFlow"].get("sequence") for node in improvements] == list(range(1, len(improvements) + 1)),
         "FLOW_CORRUPT", "improvement sequence is not contiguous", exit_code=6)
    previous_id = implementation_id
    for sequence, node in enumerate(improvements, 1):
        fail(implementation is not None and gate["state"] == "approved", "FLOW_CORRUPT",
             "forward improvement exists without approved implementation", node["id"], 6)
        design = node["metadata"]["designFlow"]
        fields = {"featureId", "flowId", "role", "artifactPath", "featureNodeId", "improvementLaneNodeId",
                  "improvementPriority", "sequence", "requestId", "feedbackId", "messageHash", "evidenceHash",
                  "sourceNodeId"}
        request_id = design.get("requestId")
        token = hashlib.sha256(str(request_id).encode("utf-8")).hexdigest()[:12]
        node_id = f"{prefix}-improvement-{token}"
        relative = f"work/design-options/improvements/improvement-{token}"
        fail(set(design) == fields and valid_text(request_id, 128, REQUEST_RE)
             and design.get("sequence") == sequence and node["id"] == node_id
             and design.get("artifactPath") == relative and design.get("featureNodeId") == intent["featureNodeId"]
             and valid_text(design.get("improvementLaneNodeId"), 128, ID_RE)
             and integer(design.get("improvementPriority")) and design["improvementPriority"] <= 1000
             and isinstance(design.get("feedbackId"), str) and re.fullmatch(r"FB-[0-9]{4,}", design["feedbackId"])
             and isinstance(design.get("messageHash"), str) and HASH_RE.fullmatch(design["messageHash"])
             and isinstance(design.get("evidenceHash"), str) and HASH_RE.fullmatch(design["evidenceHash"])
             and design.get("sourceNodeId") == previous_id,
             "FLOW_CORRUPT", "forward improvement immutable intent is invalid", node["id"], 6)
        expected_metadata = node_metadata(feature_id, flow_id, "improvement", relative,
            extra={"featureNodeId": intent["featureNodeId"], "improvementLaneNodeId": design["improvementLaneNodeId"],
                   "improvementPriority": design["improvementPriority"], "sequence": sequence,
                   "requestId": request_id, "feedbackId": design["feedbackId"], "messageHash": design["messageHash"],
                   "evidenceHash": design["evidenceHash"], "sourceNodeId": previous_id})
        assert_node_shape(node, {"id": node_id, "kind": "feedback", "title": f"Forward design improvement {sequence}",
            "initialState": "pending", "priority": design["improvementPriority"], "metadata": expected_metadata},
            f"improvement {sequence}")
        expected_nodes.add(node_id)
        expected_edges.extend((edge("contains", intent["featureNodeId"], node_id),
                               edge("assigned-to", node_id, design["improvementLaneNodeId"]),
                               edge("depends-on", node_id, previous_id),
                               edge("feedback-for", node_id, implementation_id)))
        previous_id = node_id

    scoped_ids = {node["id"] for node in scoped}
    prefixed_ids = {node["id"] for node in prefixed}
    fail(scoped_ids == expected_nodes and prefixed_ids == expected_nodes,
         "FLOW_CORRUPT", "flow contains missing, extra, or metadata-impostor nodes", {
             "expected": sorted(expected_nodes), "scoped": sorted(scoped_ids), "prefixed": sorted(prefixed_ids),
         }, 6)
    actual_edges = [item for item in value["edges"]
                    if item["from"] in expected_nodes or item["to"] in expected_nodes]
    fail(sorted(actual_edges, key=canonical) == sorted(expected_edges, key=canonical),
         "FLOW_CORRUPT", "flow topology edges do not match the canonical lifecycle", {
             "expected": expected_edges, "actual": actual_edges,
         }, 6)
    return {"prefix": prefix, "intent": intent, "proposals": proposals, "gate": gate,
            "implementation": implementation, "improvements": improvements}


def read_brief(path: Path) -> Tuple[bytes, str]:
    brief = read_regular(path, "design brief", MAX_BRIEF_BYTES)
    try:
        brief.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise FlowError("USAGE", "design brief must be UTF-8 text", str(path), 2) from exc
    return brief, file_digest(brief)


def prepare_proposal_artifacts(root: OperatorRoot, store: ArtifactStore,
                               feature_id: str, flow_id: str, brief: bytes) -> None:
    try:
        prompt = read_proposal_prompt(root).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise FlowError("IO_ERROR", "design proposal prompt template must be UTF-8 text", exit_code=3) from exc
    store.ensure_dir("work/design-options")
    store.write_once("work/design-options/brief.md", brief)
    for proposal in PROPOSALS:
        proposal_dir = f"work/design-options/{proposal}"
        store.ensure_dir(proposal_dir)
        rendered = (prompt.replace("{{PROPOSAL_ID}}", proposal).replace("{{FEATURE_ID}}", feature_id)
                    .replace("{{FLOW_ID}}", flow_id).replace("{{BRIEF_PATH}}", "../brief.md"))
        store.write_once(f"{proposal_dir}/prompt.md", rendered.encode("utf-8"))
        store.write_once(f"{proposal_dir}/brief.md", brief)


def require_start_intent(model: Mapping[str, Any], args: argparse.Namespace, brief_hash: Optional[str] = None,
                         bind_start_fields: bool = False) -> None:
    expected = {"featureNodeId": args.feature_node}
    if bind_start_fields:
        expected.update({"proposalLaneNodeId": args.lane, "flowTitle": args.title,
                         "proposalPriority": args.priority})
    actual = {key: model["intent"][key] for key in expected}
    fail(actual == expected and (brief_hash is None or model["intent"]["briefHash"] == brief_hash),
         "INTENT_CONFLICT", "retry intent differs from the immutable design-flow start", {
             "expected": expected, "actual": actual, "briefHash": model["intent"]["briefHash"],
         }, 6)


def selection_preconditions(model: Mapping[str, Any]) -> None:
    proposals = model["proposals"]
    fail(all(node["state"] == "completed" for node in proposals.values()), "PROPOSALS_INCOMPLETE",
         "all three proposal nodes must be completed before a human decision",
         {proposal: proposals[proposal]["state"] for proposal in PROPOSALS}, 6)


def start_flow(root: OperatorRoot, args: argparse.Namespace) -> Mapping[str, Any]:
    workspace = feature_workspace(root, args.feature)
    brief, brief_hash = read_brief(Path(args.brief))
    with ArtifactStore(workspace) as store:
        value = snapshot(root)
        model = validate_flow_topology(value, args.feature, args.flow_id, allow_missing=True)
        if model is not None:
            require_start_intent(model, args, brief_hash, bind_start_fields=True)
            validate_context(value, args.feature, args.feature_node, args.lane)
            prepare_proposal_artifacts(root, store, args.feature, args.flow_id, brief)
            return status_flow(root, args, value=value, workspace=workspace, store=store, model=model)
        validate_context(value, args.feature, args.feature_node, args.lane)
        prepare_proposal_artifacts(root, store, args.feature, args.flow_id, brief)
        definition = definition_from_snapshot(value)
        prefix = flow_prefix(args.feature, args.flow_id)
        intent = {"featureNodeId": args.feature_node, "proposalLaneNodeId": args.lane, "flowTitle": args.title,
                  "proposalPriority": args.priority, "briefHash": brief_hash,
                  "briefArtifact": "work/design-options/brief.md"}
        for proposal in PROPOSALS:
            node_id = f"{prefix}-{proposal}"
            definition["nodes"].append({"id": node_id, "kind": "task", "title": f"{args.title}: {proposal}",
                "initialState": "pending", "priority": args.priority,
                "metadata": node_metadata(args.feature, args.flow_id, "proposal", f"work/design-options/{proposal}",
                                          proposal, {**intent})})
            definition["edges"].extend((edge("contains", args.feature_node, node_id), edge("assigned-to", node_id, args.lane)))
        gate_id = f"{prefix}-selection-gate"
        definition["nodes"].append({"id": gate_id, "kind": "human-gate", "title": f"Select {args.title}",
            "initialState": "pending", "priority": args.priority,
            "metadata": node_metadata(args.feature, args.flow_id, "selection-gate", "work/design-options",
                                      extra={**intent, "options": list(PROPOSALS)}, reclaimable=False)})
        definition["edges"].append(edge("contains", args.feature_node, gate_id))
        graph_mutate(root, "replace-definition", f"design-start-{args.feature}-{args.flow_id}", value,
                     {"action": "start", "featureId": args.feature, "flowId": args.flow_id},
                     definition=definition)
        current = snapshot(root)
        current_model = validate_flow_topology(current, args.feature, args.flow_id)
        assert current_model is not None
        return status_flow(root, args, value=current, workspace=workspace, store=store, model=current_model)


def select_flow(root: OperatorRoot, args: argparse.Namespace) -> Mapping[str, Any]:
    workspace = feature_workspace(root, args.feature)
    with ArtifactStore(workspace) as store:
        value = snapshot(root)
        model = validate_flow_topology(value, args.feature, args.flow_id,
                                       allow_approved_without_implementation=True)
        assert model is not None
        require_start_intent(model, args)
        validate_context(value, args.feature, args.feature_node, args.lane)
        selection_preconditions(model)
        implementation = model["implementation"]
        if implementation is not None:
            design = implementation["metadata"]["designFlow"]
            fail(design["selectedProposal"] == args.proposal, "SELECTION_CONFLICT",
                 f"flow already selected {design['selectedProposal']}", exit_code=6)
            fail(design["implementationLaneNodeId"] == args.lane and design["implementationPriority"] == args.priority,
                 "INTENT_CONFLICT", "selection retry lane or priority differs from immutable intent", exit_code=6)
            fail(model["gate"]["state"] == "approved", "GATE_REJECTED",
                 "selected implementation is not backed by an approved human gate", exit_code=6)
        else:
            gate = model["gate"]
            if gate["state"] == "pending":
                graph_mutate(root, "gate decide", f"design-select-gate-{args.feature}-{args.flow_id}-{args.proposal}",
                             value, {"action": "select", "featureId": args.feature, "flowId": args.flow_id,
                                     "proposal": args.proposal}, gate_node_id=gate["id"], decision="approved")
                value = snapshot(root)
                model = validate_flow_topology(value, args.feature, args.flow_id,
                                               allow_approved_without_implementation=True)
                assert model is not None
            elif gate["state"] != "approved":
                raise FlowError("GATE_REJECTED", "selection gate was not approved; completed history cannot be reopened",
                                exit_code=6)
            definition = definition_from_snapshot(value)
            node_id = f"{model['prefix']}-implementation"
            definition["nodes"].append({"id": node_id, "kind": "task", "title": f"Implement {args.proposal}",
                "initialState": "pending", "priority": args.priority,
                "metadata": node_metadata(args.feature, args.flow_id, "implementation", f"work/design-options/{args.proposal}",
                    extra={"featureNodeId": args.feature_node, "implementationLaneNodeId": args.lane,
                           "implementationPriority": args.priority, "selectedProposal": args.proposal,
                           "selectionGate": model["gate"]["id"]}, reclaimable=False)})
            definition["edges"].extend((edge("contains", args.feature_node, node_id), edge("assigned-to", node_id, args.lane)))
            definition["edges"].extend(edge("depends-on", node_id, model["proposals"][proposal]["id"]) for proposal in PROPOSALS)
            definition["edges"].append(edge("gated-by", node_id, model["gate"]["id"],
                                            {"protectedTransitions": ["active", "completed"]}))
            graph_mutate(root, "replace-definition", f"design-select-node-{args.feature}-{args.flow_id}-{args.proposal}",
                         value, {"action": "select", "featureId": args.feature, "flowId": args.flow_id,
                                 "proposal": args.proposal}, definition=definition)
            value = snapshot(root)
            model = validate_flow_topology(value, args.feature, args.flow_id)
            assert model is not None
            implementation = model["implementation"]
            fail(implementation is not None and implementation["metadata"]["designFlow"]["selectedProposal"] == args.proposal,
                 "FLOW_CORRUPT", "canonical implementation did not materialize", exit_code=6)
        current = snapshot(root)
        current_model = validate_flow_topology(current, args.feature, args.flow_id)
        assert current_model is not None
        return status_flow(root, args, value=current, workspace=workspace, store=store, model=current_model)


def reject_flow(root: OperatorRoot, args: argparse.Namespace) -> Mapping[str, Any]:
    workspace = feature_workspace(root, args.feature)
    with ArtifactStore(workspace) as store:
        value = snapshot(root)
        model = validate_flow_topology(value, args.feature, args.flow_id)
        assert model is not None
        require_start_intent(model, args)
        validate_context(value, args.feature, args.feature_node, None)
        selection_preconditions(model)
        fail(model["implementation"] is None, "SELECTION_CONFLICT",
             "cannot reject after implementation selection exists", exit_code=6)
        gate = model["gate"]
        if gate["state"] == "pending":
            graph_mutate(root, "gate decide", f"design-reject-gate-{args.feature}-{args.flow_id}", value,
                         {"action": "reject", "featureId": args.feature, "flowId": args.flow_id},
                         gate_node_id=gate["id"], decision="rejected")
        elif gate["state"] != "rejected":
            raise FlowError("GATE_ALREADY_DECIDED", "selection gate is already approved or cancelled", exit_code=6)
        current = snapshot(root)
        current_model = validate_flow_topology(current, args.feature, args.flow_id)
        assert current_model is not None
        return status_flow(root, args, value=current, workspace=workspace, store=store, model=current_model)


def collect_evidence(evidence: Sequence[str]) -> Tuple[List[Tuple[str, bytes]], List[Dict[str, Any]]]:
    seen: Set[str] = set()
    files: List[Tuple[str, bytes]] = []
    records: List[Dict[str, Any]] = []
    total = 0
    for raw in evidence:
        source = Path(raw)
        data = read_regular(source, "dissatisfaction evidence", MAX_EVIDENCE_FILE_BYTES)
        total += len(data)
        fail(total <= MAX_EVIDENCE_TOTAL_BYTES, "IO_ERROR", "dissatisfaction evidence exceeds total byte limit", exit_code=3)
        name = source.name
        fail(name not in seen and name not in {"", ".", ".."}, "USAGE", "evidence basenames must be unique", name, 2)
        require_canonical_text(name, "evidence basename", 255)
        seen.add(name)
        files.append((name, data))
        records.append({"name": name, "sha256": file_digest(data), "size": len(data)})
    return files, records


def copy_evidence(store: ArtifactStore, relative: str, message: str,
                  files: Sequence[Tuple[str, bytes]]) -> Tuple[str, List[Dict[str, Any]]]:
    store.ensure_dir(relative)
    message_data = ("# Dissatisfaction\n\n" + message.strip() + "\n").encode("utf-8")
    store.write_once(f"{relative}/dissatisfaction.md", message_data)
    store.ensure_dir(f"{relative}/evidence")
    records = []
    for name, data in files:
        store.write_once(f"{relative}/evidence/{name}", data)
        records.append({"name": name, "sha256": file_digest(data), "size": len(data)})
    return file_digest(message_data), records


def feedback_intake(root: OperatorRoot, request_id: str, feature_id: str, flow_id: str, node_id: str, source_node: str,
                    message: str, evidence_path: str, message_hash: str,
                    evidence: Sequence[Mapping[str, Any]]) -> Mapping[str, Any]:
    request = {
        "schemaVersion": FEEDBACK_REQUEST_VERSION, "requestId": request_id, "featureId": feature_id,
        "flowId": flow_id, "improvementNodeId": node_id, "sourceNodeId": source_node,
        "message": message, "messageHash": message_hash, "evidencePath": evidence_path,
        "evidence": [dict(item) for item in evidence],
    }
    raw = bounded_command(root, command_path("OPERATOR_DESIGN_FLOW_FEEDBACK_COMMAND", "operator-feedback.sh"), request,
                          "trusted feedback intake owner", "feedback")
    result = load_interface(raw, "trusted feedback result")
    exact(result, {"ok", "schemaVersion", "requestId", "feedbackId", "status", "evidencePath"}, "feedback result")
    fail(result.get("ok") is True and result.get("schemaVersion") == FEEDBACK_RESULT_VERSION
         and result.get("requestId") == request_id and result.get("status") == "inbox"
         and result.get("evidencePath") == evidence_path,
         "INTERFACE_PROTOCOL", "feedback result is not bound to the request", result, 4)
    feedback_id = result.get("feedbackId")
    fail(isinstance(feedback_id, str) and bool(re.fullmatch(r"FB-[0-9]{4,}", feedback_id)),
         "INTERFACE_PROTOCOL", "feedback result ID is invalid", feedback_id, 4)
    return result


def dissatisfied_flow(root: OperatorRoot, args: argparse.Namespace) -> Mapping[str, Any]:
    require_identifier(args.request_id, "request ID", REQUEST_RE)
    require_canonical_text(args.message, "message", 4096)
    workspace = feature_workspace(root, args.feature)
    files, evidence_records = collect_evidence(args.evidence)
    message_data = ("# Dissatisfaction\n\n" + args.message.strip() + "\n").encode("utf-8")
    message_hash = file_digest(message_data)
    evidence_hash = file_digest(canonical(evidence_records))
    with ArtifactStore(workspace) as store:
        value = snapshot(root)
        model = validate_flow_topology(value, args.feature, args.flow_id)
        assert model is not None
        require_start_intent(model, args)
        validate_context(value, args.feature, args.feature_node, args.lane)
        implementation = model["implementation"]
        fail(implementation is not None and model["gate"]["state"] == "approved"
             and implementation["state"] == "completed", "OUTCOME_INCOMPLETE",
             "approved selected implementation must be completed before dissatisfaction creates forward work", exit_code=6)
        improvements = model["improvements"]
        for existing in improvements:
            design = existing["metadata"]["designFlow"]
            if design["requestId"] == args.request_id:
                fail(design["featureNodeId"] == args.feature_node and design["improvementLaneNodeId"] == args.lane
                     and design["improvementPriority"] == args.priority and design["messageHash"] == message_hash
                     and design["evidenceHash"] == evidence_hash,
                     "INTENT_CONFLICT", "dissatisfaction retry differs from immutable request intent", args.request_id, 6)
                copy_evidence(store, design["artifactPath"], args.message, files)
                return status_flow(root, args, value=value, workspace=workspace, store=store, model=model)
            if design["messageHash"] == message_hash and design["evidenceHash"] == evidence_hash:
                raise FlowError("REQUEST_ID_CONFLICT", "the same dissatisfaction evidence already uses a different request ID",
                                {"existing": design["requestId"], "requested": args.request_id}, 6)
        previous = improvements[-1] if improvements else implementation
        assert previous is not None
        fail(previous["state"] == "completed", "OUTCOME_INCOMPLETE",
             "the current forward improvement must complete before another is created", previous["id"], 6)
        sequence = len(improvements) + 1
        token = hashlib.sha256(args.request_id.encode("utf-8")).hexdigest()[:12]
        node_id = f"{model['prefix']}-improvement-{token}"
        relative = f"work/design-options/improvements/improvement-{token}"
        copy_evidence(store, relative, args.message, files)
        feedback = feedback_intake(root, args.request_id, args.feature, args.flow_id, node_id, previous["id"],
                                   args.message.strip(), relative, message_hash, evidence_records)
        value = snapshot(root)
        model = validate_flow_topology(value, args.feature, args.flow_id)
        assert model is not None
        for existing in model["improvements"]:
            if existing["metadata"]["designFlow"]["requestId"] == args.request_id:
                return status_flow(root, args, value=value, workspace=workspace, store=store, model=model)
        fail(len(model["improvements"]) + 1 == sequence, "REVISION_CONFLICT",
             "forward improvement sequence changed; retry the same request", exit_code=6)
        implementation = model["implementation"]
        assert implementation is not None
        previous = model["improvements"][-1] if model["improvements"] else implementation
        definition = definition_from_snapshot(value)
        definition["nodes"].append({"id": node_id, "kind": "feedback", "title": f"Forward design improvement {sequence}",
            "initialState": "pending", "priority": args.priority,
            "metadata": node_metadata(args.feature, args.flow_id, "improvement", relative,
                extra={"featureNodeId": args.feature_node, "improvementLaneNodeId": args.lane,
                       "improvementPriority": args.priority, "sequence": sequence, "requestId": args.request_id,
                       "feedbackId": feedback["feedbackId"], "messageHash": message_hash,
                       "evidenceHash": evidence_hash, "sourceNodeId": previous["id"]})})
        definition["edges"].extend((edge("contains", args.feature_node, node_id), edge("assigned-to", node_id, args.lane),
                                    edge("depends-on", node_id, previous["id"]),
                                    edge("feedback-for", node_id, implementation["id"])))
        graph_mutate(root, "replace-definition", f"design-improvement-{args.request_id}", value,
                     {"action": "improve", "featureId": args.feature, "flowId": args.flow_id,
                             "feedbackRequestId": args.request_id}, definition=definition)
        current = snapshot(root)
        current_model = validate_flow_topology(current, args.feature, args.flow_id)
        assert current_model is not None
        return status_flow(root, args, value=current, workspace=workspace, store=store, model=current_model)


def status_flow(root: OperatorRoot, args: argparse.Namespace, value: Optional[Mapping[str, Any]] = None,
                workspace: Optional[FeatureWorkspace] = None, store: Optional[ArtifactStore] = None,
                model: Optional[Mapping[str, Any]] = None) -> Mapping[str, Any]:
    current_workspace = workspace or feature_workspace(root, args.feature)
    if store is None:
        with ArtifactStore(current_workspace) as opened:
            return status_flow(root, args, value=value, workspace=current_workspace, store=opened, model=model)
    current = value or snapshot(root)
    current_model = model or validate_flow_topology(current, args.feature, args.flow_id)
    assert current_model is not None
    if args.feature_node != current_model["intent"]["featureNodeId"]:
        raise FlowError("INTENT_CONFLICT", "status feature-node differs from immutable flow intent", exit_code=6)
    proposals = current_model["proposals"]
    gate = current_model["gate"]
    implementation = current_model["implementation"]
    improvements = current_model["improvements"]
    proposal_status = []
    for proposal in PROPOSALS:
        node = proposals[proposal]
        relative = node["metadata"]["designFlow"]["artifactPath"]
        proposal_status.append({
            "proposal": proposal, "nodeId": node["id"], "state": node["state"],
            "artifactPath": relative, "evidence": store.inventory(relative),
        })
    proposed = None if implementation is None else implementation["metadata"]["designFlow"]["selectedProposal"]
    selected = proposed if gate["state"] == "approved" else None
    implementation_status = None if implementation is None else {
        "nodeId": implementation["id"], "state": implementation["state"],
        "selectedProposal": selected, "proposedProposal": proposed, "loopOwnedExecution": True,
    }
    improvement_status = []
    for node in improvements:
        design = node["metadata"]["designFlow"]
        improvement_status.append({
            "sequence": design["sequence"], "nodeId": node["id"], "state": node["state"],
            "feedbackId": design["feedbackId"], "requestId": design["requestId"],
            "sourceNodeId": design["sourceNodeId"], "artifactPath": design["artifactPath"],
            "evidence": store.inventory(design["artifactPath"]),
        })
    data = {
        "schemaVersion": STATUS_VERSION, "featureId": args.feature, "flowId": args.flow_id,
        "graphId": current["graphId"], "revision": current["revision"],
        "definitionRevision": current["definitionRevision"], "workspace": str(current_workspace),
        "proposals": proposal_status,
        "selection": {"gateNodeId": gate["id"], "gateState": gate["state"], "approved": gate["state"] == "approved",
                      "selectedProposal": selected, "proposedProposal": proposed,
                      "durableGraphGate": gate["state"] in {"approved", "rejected"},
                      "materializationPending": gate["state"] == "approved" and implementation is None},
        "implementation": implementation_status, "improvements": improvement_status,
    }
    return {"ok": True, "command": "status", "data": data}


def parser() -> argparse.ArgumentParser:
    root = JSONArgumentParser(prog="operator-design-flow", description="Three-proposal design, feature promotion, and forward improvement flow")
    sub = root.add_subparsers(dest="command", required=True, parser_class=JSONArgumentParser)

    def common(command: argparse.ArgumentParser, lane: bool = False) -> None:
        command.add_argument("--feature", required=True)
        command.add_argument("--feature-node", default=None)
        command.add_argument("--flow-id", default="design")
        if lane:
            command.add_argument("--lane", required=True)
        command.add_argument("--json", action="store_true")

    start = sub.add_parser("start")
    common(start, lane=True)
    start.add_argument("--brief", required=True)
    start.add_argument("--title", default="Design proposal")
    start.add_argument("--priority", type=int, default=500)

    select = sub.add_parser("select")
    common(select, lane=True)
    select.add_argument("--proposal", required=True, choices=PROPOSALS)
    select.add_argument("--priority", type=int, default=600)

    reject = sub.add_parser("reject")
    common(reject)

    dissatisfied = sub.add_parser("dissatisfied")
    common(dissatisfied, lane=True)
    dissatisfied.add_argument("--request-id", required=True)
    dissatisfied.add_argument("--message", required=True)
    dissatisfied.add_argument("--evidence", action="append", default=[])
    dissatisfied.add_argument("--priority", type=int, default=550)

    status = sub.add_parser("status")
    common(status)
    promote = sub.add_parser("promote")
    common(promote, lane=True)
    promote.add_argument("--title", default="Publish accepted website to production")
    promote.add_argument("--priority", type=int, default=900)
    authorize = sub.add_parser("authorize-publish")
    common(authorize)
    return root


def print_text(payload: Mapping[str, Any]) -> None:
    data = payload["data"]
    print(f"Design flow {data['flowId']} for {data['featureId']}")
    print("Proposals: " + ", ".join(f"{item['proposal']}={item['state']}" for item in data["proposals"]))
    print(f"Selection gate: {data['selection']['gateState']}")
    if data["selection"]["selectedProposal"]:
        print(f"Selected: {data['selection']['selectedProposal']}")
    print(f"Forward improvements: {len(data['improvements'])}")


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        injected = sorted(PROVIDER_OVERRIDE_VARIABLES.intersection(os.environ))
        fail(not injected, "AUTHORITY_DENIED",
             "installed design flow rejects trusted-provider command overrides",
             {"variables": injected}, 4)
        args = parser().parse_args(argv)
        args.feature_node = args.feature_node or args.feature
        require_identifier(args.feature, "feature ID")
        require_identifier(args.feature_node, "feature node ID")
        require_identifier(args.flow_id, "flow ID", FLOW_RE)
        if hasattr(args, "lane"):
            require_identifier(args.lane, "lane node ID")
        if hasattr(args, "priority"):
            fail(0 <= args.priority <= 1000, "USAGE", "priority must be between 0 and 1000", exit_code=2)
        if hasattr(args, "title"):
            require_canonical_text(args.title, "title", 512)
        with OperatorRoot.open() as operator_root:
            if args.command == "start":
                payload = start_flow(operator_root, args)
            elif args.command == "promote":
                payload = promote_feature(operator_root, args)
            elif args.command == "authorize-publish":
                payload = authorize_publish(operator_root, args)
            elif args.command == "select":
                payload = select_flow(operator_root, args)
            elif args.command == "reject":
                payload = reject_flow(operator_root, args)
            elif args.command == "dissatisfied":
                payload = dissatisfied_flow(operator_root, args)
            else:
                payload = status_flow(operator_root, args)
            operator_root.verify_children()
        if args.json:
            sys.stdout.buffer.write(canonical(payload))
        else:
            print_text(payload)
        return 0
    except FlowError as exc:
        error: Dict[str, Any] = {"ok": False, "error": {"code": exc.code, "message": exc.message}}
        if exc.details is not None:
            error["error"]["details"] = exc.details
        sys.stderr.buffer.write(canonical(error))
        return exc.exit_code
    except (AttributeError, IndexError, KeyError, OverflowError, RecursionError, TypeError, ValueError) as exc:
        error = {"ok": False, "error": {"code": "DESIGN_FLOW_FAILED_CLOSED", "message": "design flow failed closed", "details": str(exc)}}
        sys.stderr.buffer.write(canonical(error))
        return 5
    except OSError as exc:
        error = {"ok": False, "error": {"code": "IO_ERROR", "message": "design flow I/O failed", "details": str(exc)}}
        sys.stderr.buffer.write(canonical(error))
        return 3
    except BrokenPipeError:
        return 0


raise SystemExit(main())
PY

PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
export PATH
unset PYTHONPATH PYTHONHOME
exec /usr/bin/python3 -E -s -c "$OPERATOR_DESIGN_FLOW_PROGRAM" "$@"
