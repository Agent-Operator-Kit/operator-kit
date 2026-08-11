#!/usr/bin/env python3
"""Descriptor-bound production adapters for the Operator V5 design flow."""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple


MAX_REQUEST_BYTES = 8 * 1024 * 1024
MAX_INBOX_BYTES = 1024 * 1024
MAX_EVIDENCE_BYTES = 64 * 1024 * 1024
MAX_EVIDENCE_TOTAL_BYTES = 256 * 1024 * 1024
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
REQUEST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+\-]{0,127}$")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+\-]*$")


class ProviderError(Exception):
    def __init__(self, code: str, message: str, details: Any = None, exit_code: int = 4):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details
        self.exit_code = exit_code


def fail(condition: bool, code: str, message: str, details: Any = None, exit_code: int = 4) -> None:
    if not condition:
        raise ProviderError(code, message, details, exit_code)


def reject_number(raw: str) -> None:
    raise ValueError(f"non-canonical number: {raw}")


def parse_integer(raw: str) -> int:
    if raw == "-0":
        raise ValueError("negative zero is not canonical")
    return int(raw)


def unique_pairs(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    value: Dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate key: {key}")
        value[key] = item
    return value


def validate_domain(value: Any) -> None:
    stack = [(value, 1)]
    count = 0
    while stack:
        item, depth = stack.pop()
        count += 1
        if depth > 40 or count > 200000:
            raise ValueError("JSON structure exceeds its bound")
        if isinstance(item, str):
            if any(ord(ch) < 32 or 127 <= ord(ch) <= 159 or 0xD800 <= ord(ch) <= 0xDFFF for ch in item):
                raise ValueError("JSON string contains a non-canonical character")
        elif isinstance(item, dict):
            for key, child in item.items():
                if not isinstance(key, str):
                    raise ValueError("JSON key is not text")
                stack.extend(((key, depth + 1), (child, depth + 1)))
        elif isinstance(item, list):
            stack.extend((child, depth + 1) for child in item)
        elif item is not None and not isinstance(item, (bool, int)):
            raise ValueError("JSON value is not canonical")


def canonical(value: Any) -> bytes:
    validate_domain(value)
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                       allow_nan=False) + "\n").encode("utf-8")


def strict_request(raw: bytes) -> Mapping[str, Any]:
    fail(len(raw) <= MAX_REQUEST_BYTES, "INTERFACE_LIMIT", "Design-flow provider request is too large")
    try:
        value = json.loads(raw.decode("utf-8"), parse_float=reject_number, parse_int=parse_integer,
                           parse_constant=reject_number, object_pairs_hook=unique_pairs)
        validate_domain(value)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise ProviderError("INTERFACE_PROTOCOL", "Design-flow provider request is not canonical JSON",
                            str(exc)) from exc
    fail(raw == canonical(value), "INTERFACE_PROTOCOL",
         "Design-flow provider request is not Operator Canonical JSON v1")
    fail(isinstance(value, dict), "INTERFACE_PROTOCOL", "Design-flow provider request must be an object")
    return value


class RootGuard:
    def __init__(self, exclusive: bool):
        raw_fd = os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_FD", "")
        raw_dev = os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_DEV", "")
        raw_ino = os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_INO", "")
        raw_path = os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_PATH", "")
        fail(re.fullmatch(r"[0-9]+", raw_fd) is not None
             and re.fullmatch(r"[0-9]+", raw_dev) is not None
             and re.fullmatch(r"[0-9]+", raw_ino) is not None,
             "IO_ERROR", "Inherited design-flow root capability is invalid")
        fail(bool(raw_path) and os.path.isabs(raw_path), "IO_ERROR",
             "Inherited design-flow root path is invalid")
        fail(os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_LOCK_MODE") == "exclusive-held",
             "IO_ERROR", "Production design provider requires the parent's held exclusive root lock")
        self.fd = os.dup(int(raw_fd))
        self.identity = (int(raw_dev), int(raw_ino))
        self.path = Path(os.path.abspath(raw_path))
        self.children: Dict[str, int] = {}
        self.leaves: Dict[str, Optional[int]] = {}
        self.binding_manifest_fd: Optional[int] = None
        held = os.fstat(self.fd)
        fail(stat.S_ISDIR(held.st_mode) and held.st_uid == os.geteuid()
             and (held.st_dev, held.st_ino) == self.identity,
             "IO_ERROR", "Inherited design-flow root descriptor identity changed")
        self.verify_path()
        try:
            for name in ("authority", "graph", "bindings", "host"):
                prefix = f"OPERATOR_DESIGN_FLOW_ROOT_{name.upper()}"
                child_fd = os.environ.get(f"{prefix}_FD", "")
                child_dev = os.environ.get(f"{prefix}_DEV", "")
                child_ino = os.environ.get(f"{prefix}_INO", "")
                fail(child_fd.isdigit() and child_dev.isdigit() and child_ino.isdigit(),
                     "IO_ERROR", f"Inherited {name} capability is invalid")
                descriptor = os.dup(int(child_fd))
                info = os.fstat(descriptor)
                fail(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid()
                     and (info.st_dev, info.st_ino) == (int(child_dev), int(child_ino)),
                     "IO_ERROR", f"Inherited {name} descriptor identity changed")
                self.children[name] = descriptor
            raw_leaves = json.loads(os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_LEAF_CAPS", ""))
            fail(isinstance(raw_leaves, dict), "IO_ERROR", "Inherited leaf capability cache is invalid")
            for label, record in raw_leaves.items():
                fail(isinstance(label, str) and label and ".." not in label.split("/"),
                     "IO_ERROR", "Inherited leaf capability path is invalid", label)
                if record is None:
                    self.leaves[label] = None
                    continue
                fail(isinstance(record, list) and len(record) == 3
                     and all(isinstance(item, int) and not isinstance(item, bool) for item in record),
                     "IO_ERROR", "Inherited leaf capability record is invalid", label)
                descriptor = os.dup(record[0]); info = os.fstat(descriptor)
                fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1
                     and (info.st_dev, info.st_ino) == (record[1], record[2]),
                     "IO_ERROR", "Inherited leaf capability identity changed", label)
                self.leaves[label] = descriptor
            raw_manifest_fd = os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_BINDING_MANIFEST_FD", "")
            fail(raw_manifest_fd.isdigit(), "IO_ERROR", "Inherited binding manifest capability is invalid")
            self.binding_manifest_fd = os.dup(int(raw_manifest_fd))
            os.lseek(self.binding_manifest_fd, 0, os.SEEK_SET)
            manifest_raw = os.read(self.binding_manifest_fd, MAX_REQUEST_BYTES + 1)
            manifest = strict_request(manifest_raw)
            fail(manifest.get("schemaVersion") == "operator.binding-capability-manifest/v1"
                 and isinstance(manifest.get("entries"), list)
                 and len(manifest["entries"]) <= 10000,
                 "IO_ERROR", "Inherited binding manifest is invalid")
            self.verify_children()
        except BaseException:
            if self.binding_manifest_fd is not None:
                os.close(self.binding_manifest_fd)
            for descriptor in self.leaves.values():
                if descriptor is not None:
                    os.close(descriptor)
            for descriptor in self.children.values():
                os.close(descriptor)
            os.close(self.fd)
            raise

    def verify_path(self) -> None:
        reopened: Optional[int] = None
        try:
            expected = os.lstat(self.path)
            fail(stat.S_ISDIR(expected.st_mode) and not stat.S_ISLNK(expected.st_mode)
                 and expected.st_uid == os.geteuid()
                 and (expected.st_dev, expected.st_ino) == self.identity,
                 "IO_ERROR", "OPERATOR_DIR identity changed at the production design provider",
                 str(self.path))
            reopened = os.open(self.path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                               | getattr(os, "O_NOFOLLOW", 0))
            actual = os.fstat(reopened)
            fail(stat.S_ISDIR(actual.st_mode) and actual.st_uid == os.geteuid()
                 and (actual.st_dev, actual.st_ino) == self.identity,
                 "IO_ERROR", "OPERATOR_DIR changed during production provider verification",
                 str(self.path))
        except ProviderError:
            raise
        except OSError as exc:
            raise ProviderError("IO_ERROR", "Cannot verify OPERATOR_DIR at the production design provider",
                                str(exc)) from exc
        finally:
            if reopened is not None:
                os.close(reopened)

    def open_directory(self, parts: Sequence[str]) -> int:
        descriptor = os.dup(self.fd)
        try:
            for part in parts:
                fail(bool(part) and part not in {".", ".."} and "/" not in part and "\x00" not in part,
                     "IO_ERROR", "Unsafe production provider path component", part)
                before = os.stat(part, dir_fd=descriptor, follow_symlinks=False)
                fail(stat.S_ISDIR(before.st_mode) and not stat.S_ISLNK(before.st_mode)
                     and before.st_uid == os.geteuid(), "IO_ERROR",
                     "Production provider directory is unsafe", part)
                child = os.open(part, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                                | getattr(os, "O_NOFOLLOW", 0), dir_fd=descriptor)
                actual = os.fstat(child)
                fail((actual.st_dev, actual.st_ino) == (before.st_dev, before.st_ino)
                     and stat.S_ISDIR(actual.st_mode) and actual.st_uid == os.geteuid(),
                     "IO_ERROR", "Production provider directory changed during traversal", part)
                os.close(descriptor)
                descriptor = child
            return descriptor
        except BaseException:
            with contextlib.suppress(OSError):
                os.close(descriptor)
            raise

    def verify_children(self, skip_mutable: bool = False) -> None:
        self.verify_path()
        for parent, entry, key in ((self.fd, "authority", "authority"),
                                   (self.fd, "graph", "graph"),
                                   (self.children["graph"], "bindings", "bindings"),
                                   (self.fd, "host", "host")):
            published = os.stat(entry, dir_fd=parent, follow_symlinks=False)
            held = os.fstat(self.children[key])
            fail(stat.S_ISDIR(published.st_mode) and not stat.S_ISLNK(published.st_mode)
                 and published.st_uid == os.geteuid()
                 and (published.st_dev, published.st_ino) == (held.st_dev, held.st_ino),
                 "IO_ERROR", f"Inherited {key} directory identity changed")
        for label, descriptor in self.leaves.items():
            if skip_mutable and label in {"graph/definition.json", "graph/projection.json"}:
                continue
            parts = label.split("/")
            fail(parts[0] in {"authority", "graph", "host"}, "IO_ERROR",
                 "Inherited leaf capability scope is invalid", label)
            parent = (self.children["authority"] if parts[0] == "authority" else
                      self.children["host"] if parts[0] == "host" else
                      self.children["bindings"] if parts[:2] == ["graph", "bindings"] else
                      self.children["graph"])
            try:
                published = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
                identity: Optional[Tuple[int, int]] = ((published.st_dev, published.st_ino)
                                                       if stat.S_ISREG(published.st_mode)
                                                       and not stat.S_ISLNK(published.st_mode)
                                                       and published.st_uid == os.geteuid()
                                                       and published.st_nlink == 1 else (-1, -1))
            except FileNotFoundError:
                identity = None
            held = None if descriptor is None else os.fstat(descriptor)
            held_identity = None if held is None else (held.st_dev, held.st_ino)
            fail(identity == held_identity, "IO_ERROR", "Inherited leaf identity changed", label)

    def close(self) -> None:
        if self.binding_manifest_fd is not None:
            with contextlib.suppress(OSError):
                os.close(self.binding_manifest_fd)
        for descriptor in self.children.values():
            with contextlib.suppress(OSError):
                os.close(descriptor)
        for descriptor in self.leaves.values():
            if descriptor is not None:
                with contextlib.suppress(OSError):
                    os.close(descriptor)
        with contextlib.suppress(OSError):
            os.close(self.fd)


def read_regular(parent_fd: int, name: str) -> bytes:
    before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    fail(stat.S_ISREG(before.st_mode) and not stat.S_ISLNK(before.st_mode)
         and before.st_uid == os.geteuid() and before.st_nlink == 1
         and before.st_size <= MAX_INBOX_BYTES,
         "IO_ERROR", "Feedback inbox entry is unsafe", name)
    descriptor = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)
    try:
        actual = os.fstat(descriptor)
        fail((actual.st_dev, actual.st_ino) == (before.st_dev, before.st_ino)
             and stat.S_ISREG(actual.st_mode) and actual.st_uid == os.geteuid()
             and actual.st_nlink == 1 and actual.st_size <= MAX_INBOX_BYTES,
             "IO_ERROR", "Feedback inbox entry changed during open", name)
        data = bytearray()
        while len(data) <= MAX_INBOX_BYTES:
            chunk = os.read(descriptor, min(65536, MAX_INBOX_BYTES + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        final = os.fstat(descriptor)
        fail(len(data) <= MAX_INBOX_BYTES
             and (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns)
             == (actual.st_dev, actual.st_ino, actual.st_size, actual.st_mtime_ns)
             and len(data) == final.st_size,
             "IO_ERROR", "Feedback inbox entry changed during read", name)
        return bytes(data)
    finally:
        os.close(descriptor)


def read_anchored_regular(parent_fd: int, name: str, maximum: int, label: str) -> bytes:
    descriptor: Optional[int] = None
    try:
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        fail(stat.S_ISREG(before.st_mode) and not stat.S_ISLNK(before.st_mode)
             and before.st_uid == os.geteuid() and before.st_nlink == 1
             and before.st_size <= maximum, "IO_ERROR", f"{label} is unsafe", name)
        descriptor = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)
        actual = os.fstat(descriptor)
        baseline = (actual.st_dev, actual.st_ino, actual.st_size, actual.st_mtime_ns,
                    actual.st_ctime_ns, actual.st_nlink)
        fail((actual.st_dev, actual.st_ino) == (before.st_dev, before.st_ino)
             and stat.S_ISREG(actual.st_mode) and actual.st_uid == os.geteuid()
             and actual.st_nlink == 1 and actual.st_size <= maximum,
             "IO_ERROR", f"{label} changed during open", name)
        chunks: List[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            fail(total <= maximum, "IO_ERROR", f"{label} exceeds its byte limit", name)
        after = os.fstat(descriptor)
        observed = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns,
                    after.st_ctime_ns, after.st_nlink)
        fail(observed == baseline and total == after.st_size,
             "IO_ERROR", f"{label} changed during read", name)
        return b"".join(chunks)
    except ProviderError:
        raise
    except OSError as exc:
        raise ProviderError("IO_ERROR", f"Cannot read {label} without following links", str(exc)) from exc
    finally:
        if descriptor is not None:
            os.close(descriptor)


def open_child_directory(parent_fd: int, parts: Sequence[str], label: str) -> int:
    current = os.dup(parent_fd)
    try:
        for part in parts:
            fail(bool(part) and part not in {".", ".."} and "/" not in part and "\x00" not in part,
                 "IO_ERROR", f"{label} contains an unsafe component", part)
            before = os.stat(part, dir_fd=current, follow_symlinks=False)
            fail(stat.S_ISDIR(before.st_mode) and not stat.S_ISLNK(before.st_mode)
                 and before.st_uid == os.geteuid(), "IO_ERROR", f"{label} is unsafe", part)
            child = os.open(part, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                            | getattr(os, "O_NOFOLLOW", 0), dir_fd=current)
            actual = os.fstat(child)
            fail((actual.st_dev, actual.st_ino) == (before.st_dev, before.st_ino)
                 and stat.S_ISDIR(actual.st_mode) and actual.st_uid == os.geteuid(),
                 "IO_ERROR", f"{label} changed during traversal", part)
            os.close(current)
            current = child
        return current
    except BaseException:
        with contextlib.suppress(OSError):
            os.close(current)
        raise


def parse_relaxed_object(raw: bytes, label: str) -> Mapping[str, Any]:
    try:
        value = json.loads(raw.decode("utf-8"), parse_float=reject_number, parse_int=parse_integer,
                           parse_constant=reject_number, object_pairs_hook=unique_pairs)
        validate_domain(value)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise ProviderError("IO_ERROR", f"{label} is invalid JSON", str(exc)) from exc
    fail(isinstance(value, dict), "IO_ERROR", f"{label} must be an object")
    return value


def open_feature_workspace(guard: RootGuard, feature_id: str) -> int:
    features_fd = guard.open_directory(("features",))
    matches: List[int] = []
    try:
        for name in sorted(os.listdir(features_fd)):
            candidate: Optional[int] = None
            try:
                candidate = open_child_directory(features_fd, (name,), "feature workspace")
                status_value = parse_relaxed_object(
                    read_anchored_regular(candidate, "status.json", 1024 * 1024, "feature status"),
                    "feature status")
                if status_value.get("id") == feature_id:
                    matches.append(candidate)
                    candidate = None
            except (FileNotFoundError, NotADirectoryError, ProviderError):
                continue
            finally:
                if candidate is not None:
                    os.close(candidate)
        fail(len(matches) == 1, "IO_ERROR", "Feature workspace identity is missing or ambiguous", feature_id)
        return matches.pop()
    finally:
        os.close(features_fd)
        for descriptor in matches:
            os.close(descriptor)


def verify_feedback_evidence(guard: RootGuard, request: Mapping[str, Any]) -> None:
    expected_message = ("# Dissatisfaction\n\n" + request["message"].strip() + "\n").encode("utf-8")
    fail("sha256:" + hashlib.sha256(expected_message).hexdigest() == request["messageHash"],
         "INTERFACE_PROTOCOL", "Feedback messageHash does not bind the canonical dissatisfaction content")
    feature_fd: Optional[int] = None
    evidence_root: Optional[int] = None
    files_fd: Optional[int] = None
    try:
        feature_fd = open_feature_workspace(guard, request["featureId"])
        evidence_root = open_child_directory(feature_fd, tuple(request["evidencePath"].split("/")),
                                             "feedback evidence path")
        actual_message = read_anchored_regular(evidence_root, "dissatisfaction.md", 1024 * 1024,
                                               "dissatisfaction artifact")
        fail(actual_message == expected_message, "INTERFACE_PROTOCOL",
             "Feedback message does not match the already-written dissatisfaction artifact")
        files_fd = open_child_directory(evidence_root, ("evidence",), "feedback evidence directory")
        listed = sorted(os.listdir(files_fd))
        expected_names = sorted(item["name"] for item in request["evidence"])
        fail(listed == expected_names, "INTERFACE_PROTOCOL",
             "Feedback evidence inventory does not exactly match the artifact directory",
             {"expected": expected_names, "actual": listed})
        total = 0
        for item in request["evidence"]:
            data = read_anchored_regular(files_fd, item["name"], MAX_EVIDENCE_BYTES, "feedback evidence")
            total += len(data)
            fail(total <= MAX_EVIDENCE_TOTAL_BYTES, "INTERFACE_LIMIT",
                 "Feedback evidence exceeds the aggregate byte limit")
            fail(len(data) == item["size"]
                 and "sha256:" + hashlib.sha256(data).hexdigest() == item["sha256"],
                 "INTERFACE_PROTOCOL", "Feedback evidence digest or size does not match", item["name"])
        guard.verify_children()
    finally:
        for descriptor in (files_fd, evidence_root, feature_fd):
            if descriptor is not None:
                os.close(descriptor)


def validate_feedback(value: Mapping[str, Any]) -> Mapping[str, Any]:
    fields = {"schemaVersion", "requestId", "featureId", "flowId", "improvementNodeId", "sourceNodeId",
              "message", "messageHash", "evidencePath", "evidence"}
    fail(set(value) == fields and value.get("schemaVersion") == "operator.design-flow-feedback-request/v1",
         "INTERFACE_PROTOCOL", "Design-flow feedback request fields are invalid")
    for key in ("featureId", "flowId", "improvementNodeId", "sourceNodeId"):
        fail(isinstance(value.get(key), str) and ID_RE.fullmatch(value[key]) is not None,
             "INTERFACE_PROTOCOL", f"Design-flow feedback {key} is invalid")
    fail(isinstance(value.get("requestId"), str) and REQUEST_RE.fullmatch(value["requestId"]) is not None,
         "INTERFACE_PROTOCOL", "Design-flow feedback requestId is invalid")
    fail(isinstance(value.get("message"), str) and 0 < len(value["message"]) <= 4096,
         "INTERFACE_PROTOCOL", "Design-flow feedback message is invalid")
    fail(isinstance(value.get("messageHash"), str) and HASH_RE.fullmatch(value["messageHash"]) is not None,
         "INTERFACE_PROTOCOL", "Design-flow feedback messageHash is invalid")
    evidence_path = value.get("evidencePath")
    fail(isinstance(evidence_path, str) and evidence_path.startswith("work/design-options/improvements/")
         and ".." not in Path(evidence_path).parts and not evidence_path.startswith("/"),
         "INTERFACE_PROTOCOL", "Design-flow feedback evidencePath is invalid")
    evidence = value.get("evidence")
    fail(isinstance(evidence, list) and len(evidence) < 1000,
         "INTERFACE_PROTOCOL", "Design-flow feedback evidence is invalid")
    for item in evidence:
        fail(isinstance(item, dict) and set(item) == {"name", "sha256", "size"}
             and isinstance(item["name"], str) and bool(item["name"])
             and "/" not in item["name"] and item["name"] not in {".", ".."}
             and isinstance(item["sha256"], str) and HASH_RE.fullmatch(item["sha256"]) is not None
             and isinstance(item["size"], int) and not isinstance(item["size"], bool)
             and 0 <= item["size"] <= 64 * 1024 * 1024,
             "INTERFACE_PROTOCOL", "Design-flow feedback evidence entry is invalid")
    return value


def feedback_result(request: Mapping[str, Any], feedback_id: str) -> Dict[str, Any]:
    return {"ok": True, "schemaVersion": "operator.design-flow-feedback-result/v1",
            "requestId": request["requestId"], "feedbackId": feedback_id,
            "status": "inbox", "evidencePath": request["evidencePath"]}


def feedback() -> int:
    request = validate_feedback(strict_request(sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)))
    guard = RootGuard(exclusive=True)
    inbox_fd: Optional[int] = None
    try:
        verify_feedback_evidence(guard, request)
        inbox_fd = guard.open_directory(("roadmap", "inbox"))
        fcntl.flock(inbox_fd, fcntl.LOCK_EX)
        guard.verify_children()
        request_marker = f"- Design request: {request['requestId']}"
        expected_markers = {
            request_marker,
            f"- Feature: {request['featureId']}",
            f"- Flow: {request['flowId']}",
            f"- Message hash: {request['messageHash']}",
            f"- Evidence path: {request['evidencePath']}",
            f"- Evidence hash: sha256:{hashlib.sha256(canonical(request['evidence'])).hexdigest()}",
        }
        maximum = 0
        for name in sorted(os.listdir(inbox_fd)):
            global_match = re.match(r"FB-([0-9]{4,})", name) if name.startswith("FB-") and name.endswith(".md") else None
            if global_match is not None:
                maximum = max(maximum, int(global_match.group(1)))
            match = re.fullmatch(r"FB-([0-9]{4,})-design-flow-[0-9a-f]{12}\.md", name)
            if match is None:
                continue
            data = read_regular(inbox_fd, name)
            text = data.decode("utf-8")
            if request_marker in text.splitlines():
                fail(expected_markers <= set(text.splitlines()), "REQUEST_CONFLICT",
                     "Existing feedback request does not match the reviewed design intent")
                result = feedback_result(request, f"FB-{int(match.group(1)):04d}")
                guard.verify_children()
                sys.stdout.buffer.write(canonical(result))
                return 0
        number = maximum + 1
        feedback_id = f"FB-{number:04d}"
        suffix = hashlib.sha256(request["requestId"].encode("utf-8")).hexdigest()[:12]
        destination = f"{feedback_id}-design-flow-{suffix}.md"
        evidence_hash = hashlib.sha256(canonical(request["evidence"])).hexdigest()
        content = (
            f"# Design feedback {feedback_id}\n\n"
            f"- ID: {feedback_id}\n"
            f"- Source: design-flow\n"
            f"- Status: inbox\n"
            f"- Design request: {request['requestId']}\n"
            f"- Feature: {request['featureId']}\n"
            f"- Flow: {request['flowId']}\n"
            f"- Improvement node: {request['improvementNodeId']}\n"
            f"- Source node: {request['sourceNodeId']}\n"
            f"- Message hash: {request['messageHash']}\n"
            f"- Evidence path: {request['evidencePath']}\n"
            f"- Evidence hash: sha256:{evidence_hash}\n\n"
            f"## Feedback\n\n{request['message']}\n\n"
            f"## Evidence inventory\n\n```json\n{canonical(request['evidence']).decode('utf-8')}```\n"
        ).encode("utf-8")
        temporary = f".{destination}.tmp.{os.getpid()}.{uuid.uuid4()}"
        descriptor: Optional[int] = None
        try:
            guard.verify_children()
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                 | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=inbox_fd)
            written = 0
            while written < len(content):
                count = os.write(descriptor, content[written:])
                fail(count > 0, "IO_ERROR", "Short design feedback write")
                written += count
            os.fchmod(descriptor, 0o644)
            os.fsync(descriptor)
            os.link(temporary, destination, src_dir_fd=inbox_fd, dst_dir_fd=inbox_fd,
                    follow_symlinks=False)
            os.fsync(inbox_fd)
            os.unlink(temporary, dir_fd=inbox_fd)
            temporary = ""
            os.fsync(inbox_fd)
            guard.verify_children()
        finally:
            if descriptor is not None:
                os.close(descriptor)
            if temporary:
                with contextlib.suppress(OSError):
                    os.unlink(temporary, dir_fd=inbox_fd)
        sys.stdout.buffer.write(canonical(feedback_result(request, feedback_id)))
        return 0
    finally:
        if inbox_fd is not None:
            with contextlib.suppress(OSError):
                fcntl.flock(inbox_fd, fcntl.LOCK_UN)
            os.close(inbox_fd)
        guard.close()


def host_module() -> Any:
    import operator_host  # type: ignore
    return operator_host


def graph_mutation() -> int:
    raw = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    request = strict_request(raw)
    guard = RootGuard(exclusive=False)
    try:
        host = host_module()
        try:
            binding = host.design_binding(guard.fd, request)
        except Exception as exc:
            raise ProviderError(getattr(exc, "code", "AUTHORITY_DENIED"),
                                getattr(exc, "message", "Design mutation policy refused the request"),
                                getattr(exc, "details", str(exc)), getattr(exc, "exit_code", 4)) from exc
        broker = Path(__file__).resolve().parent / "operator-proof-broker.sh"
        graph = Path(__file__).resolve().parent / "operator-graph.sh"
        fail(broker.is_file() and os.access(broker, os.X_OK)
             and graph.is_file() and os.access(graph, os.X_OK),
             "TRUSTED_INTERFACE_UNAVAILABLE", "Installed design mutation broker is unavailable", exit_code=3)
        broker_end, graph_end = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        policy_file = tempfile.TemporaryFile()
        definition_file: Optional[Any] = None
        policy_file.write(raw)
        policy_file.flush()
        policy_file.seek(0)
        if request["command"] == "replace-definition":
            definition_file = tempfile.TemporaryFile()
            definition_file.write(canonical(request["definition"]))
            definition_file.flush()
            definition_file.seek(0)
            graph_args = host.design_graph_mutation_args(request, binding, definition_file.fileno())
        else:
            graph_args = host.design_graph_mutation_args(request, binding)
        root_environment = {
            "OPERATOR_DIR": str(guard.path),
            "OPERATOR_DESIGN_FLOW_ROOT_FD": str(guard.fd),
            "OPERATOR_DESIGN_FLOW_ROOT_DEV": str(guard.identity[0]),
            "OPERATOR_DESIGN_FLOW_ROOT_INO": str(guard.identity[1]),
            "OPERATOR_DESIGN_FLOW_ROOT_PATH": str(guard.path),
            "OPERATOR_DESIGN_FLOW_ROOT_LOCK_MODE": "exclusive-held",
        }
        for name, descriptor in guard.children.items():
            info = os.fstat(descriptor)
            prefix = f"OPERATOR_DESIGN_FLOW_ROOT_{name.upper()}"
            root_environment[f"{prefix}_FD"] = str(descriptor)
            root_environment[f"{prefix}_DEV"] = str(info.st_dev)
            root_environment[f"{prefix}_INO"] = str(info.st_ino)
        leaf_caps: Dict[str, Any] = {}
        leaf_descriptors: List[int] = []
        for name, descriptor in sorted(guard.leaves.items()):
            if descriptor is None:
                leaf_caps[name] = None
            else:
                info = os.fstat(descriptor)
                leaf_caps[name] = [descriptor, info.st_dev, info.st_ino]
                leaf_descriptors.append(descriptor)
        root_environment["OPERATOR_DESIGN_FLOW_ROOT_LEAF_CAPS"] = json.dumps(
            leaf_caps, sort_keys=True, separators=(",", ":"))
        assert guard.binding_manifest_fd is not None
        root_environment["OPERATOR_DESIGN_FLOW_ROOT_BINDING_MANIFEST_FD"] = str(
            guard.binding_manifest_fd)
        trusted_home = pwd.getpwuid(os.geteuid()).pw_dir
        broker_environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "LC_ALL": "C", "LANG": "C", "HOME": trusted_home, "TMPDIR": "/tmp",
            "OPERATOR_DESIGN_FLOW_BROKER": "1",
            "OPERATOR_DESIGN_FLOW_BROKER_FD": str(broker_end.fileno()),
            "OPERATOR_DESIGN_FLOW_POLICY_FD": str(policy_file.fileno()),
            "OPERATOR_DESIGN_FLOW_BINDING_ID": binding["bindingId"],
            **{key: value for key, value in root_environment.items() if key != "OPERATOR_DIR"},
        }
        graph_environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "LC_ALL": "C", "LANG": "C", "HOME": trusted_home, "TMPDIR": "/tmp",
            "OPERATOR_DESIGN_FLOW_PROVIDER_MODE": "",
            **root_environment,
        }
        guard.verify_children()
        broker_process = subprocess.Popen([str(broker)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                          stderr=subprocess.PIPE, env=broker_environment,
                                          pass_fds=(guard.fd, *guard.children.values(), *leaf_descriptors,
                                                    guard.binding_manifest_fd,
                                                    broker_end.fileno(), policy_file.fileno()),
                                          start_new_session=True)
        pass_fds = [guard.fd, *guard.children.values(), *leaf_descriptors,
                    guard.binding_manifest_fd, graph_end.fileno()]
        if definition_file is not None:
            pass_fds.append(definition_file.fileno())
        graph_process = subprocess.Popen([str(graph), *graph_args, "--proof-fd", str(graph_end.fileno())],
                                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                         env=graph_environment, pass_fds=tuple(pass_fds), start_new_session=True)
        broker_end.close()
        graph_end.close()
        try:
            output, error = graph_process.communicate(timeout=45)
            broker_error = broker_process.communicate(timeout=5)[1]
        except subprocess.TimeoutExpired as exc:
            for process in (graph_process, broker_process):
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
            raise ProviderError("INTERFACE_TIMEOUT", "Production design mutation transaction timed out", str(exc)) from exc
        guard.verify_children(skip_mutable=(graph_process.returncode == 0 and broker_process.returncode == 0))
        fail(len(output) <= MAX_REQUEST_BYTES and len(error) <= MAX_REQUEST_BYTES
             and len(broker_error) <= MAX_REQUEST_BYTES, "INTERFACE_LIMIT",
             "Production design mutation output is too large")
        if graph_process.returncode == 0 and broker_process.returncode == 0:
            sys.stdout.buffer.write(output)
            return 0
        def diagnostic(raw_value: bytes) -> Any:
            if not raw_value.strip():
                return None
            try:
                return strict_request(raw_value)
            except ProviderError:
                return re.sub(r"[\x00-\x1f\x7f]", " ",
                              raw_value.decode("utf-8", errors="replace"))[:4096]
        raise ProviderError("TRUSTED_INTERFACE_FAILED",
                            "Production design mutation transaction failed closed",
                            {"graph": diagnostic(error or output),
                             "broker": diagnostic(broker_error),
                             "graphStatus": graph_process.returncode,
                             "brokerStatus": broker_process.returncode})
    finally:
        for name in ("broker_end", "graph_end"):
            channel = locals().get(name)
            if channel is not None:
                with contextlib.suppress(OSError):
                    channel.close()
        for name in ("definition_file", "policy_file"):
            handle = locals().get(name)
            if handle is not None:
                with contextlib.suppress(OSError):
                    handle.close()
        guard.close()


def main() -> int:
    try:
        fail(len(sys.argv) == 2 and sys.argv[1] in {"feedback", "graph-mutation"},
             "USAGE", "Unknown production design provider mode", exit_code=2)
        return feedback() if sys.argv[1] == "feedback" else graph_mutation()
    except ProviderError as exc:
        payload: Dict[str, Any] = {"ok": False, "error": {"code": exc.code, "message": exc.message}}
        if exc.details is not None:
            payload["error"]["details"] = exc.details
        sys.stderr.buffer.write(canonical(payload))
        return exc.exit_code
    except (OSError, UnicodeError, ValueError, TypeError, RecursionError) as exc:
        sys.stderr.buffer.write(canonical({"ok": False, "error": {
            "code": "IO_ERROR", "message": "Production design provider failed closed", "details": str(exc),
        }}))
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
