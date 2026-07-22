#!/usr/bin/env python3
"""Trusted Operator V5 Codex/Claude host boundary.

The lane-facing processes never receive proof keys or graph write access.  This
module is intentionally the only Python helper shared by operator-host.sh and
operator-proof-broker.sh.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import ctypes
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from functools import lru_cache
from typing import Any, Callable, Dict, Iterable, Mapping, Optional, Sequence, Tuple


HOST_BINDING_VERSION = "operator.host-session-binding/v2"
HOST_SCOPE_VERSION = "operator.host-scope/v1"
GOAL_CONTEXT_VERSION = "operator.host-goal-context/v1"
EFFECT_VERSION = "operator.host-effect/v1"
RUN_REQUEST_VERSION = "operator.runner-request/v1"
RUN_RESULT_VERSION = "operator.runner-result/v1"
CLOCK_VERSION = "operator.scheduler-clock/v1"
PROOF_CHALLENGE_VERSION = "operator.proof-challenge/v1"
PROOF_RESPONSE_VERSION = "operator.proof-response/v1"
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_RUNNER_BYTES = 1024 * 1024
MAX_EFFECT_BYTES = 1024 * 1024
MAX_INTERFACE_RELAY_HEADER_BYTES = 4096
MAX_INTERFACE_RELAY_REQUESTS = 40016
INTERFACE_RELAY_POLICY_VERSION = "operator.host-interface-relay-policy/v1"
INTERFACE_RELAY_REQUEST_VERSION = "operator.host-interface-relay-request/v1"
INTERFACE_RELAY_RESPONSE_VERSION = "operator.host-interface-relay-response/v1"
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+\-]*$")
BINDING_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]*$")
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
FORBIDDEN_TEST_ENV = {
    "OPERATOR_HOST_TEST_MODE", "OPERATOR_HOST_TEST_SIGNER", "OPERATOR_HOST_TEST_RUNNER",
    "OPERATOR_LOOP_TEST_MODE", "OPERATOR_LOOP_SCHEDULER", "OPERATOR_HOST_SCRIPT_DIR",
    "OPERATOR_DIR", "CODE_DIR", "OPERATOR_LANES", "OPERATOR_CONFIG",
}
FORBIDDEN_LAUNCH_TOKENS = {
    "dangerously-" + "bypass-approvals-and-sandbox",
    "dangerously-" + "skip-permissions",
    "bypass" + "Permissions",
}
SYSTEM_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"


@lru_cache(maxsize=1)
def trusted_path() -> str:
    account_home = Path(pwd.getpwuid(os.geteuid()).pw_dir)
    return ":".join((str(account_home / ".local" / "bin"), SYSTEM_PATH))


class HostError(Exception):
    def __init__(self, code: str, message: str, details: Any = None, exit_code: int = 5):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details
        self.exit_code = exit_code


class JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise HostError("USAGE", message, exit_code=2)


def fail(condition: bool, code: str, message: str, details: Any = None, exit_code: int = 5) -> None:
    if not condition:
        raise HostError(code, message, details, exit_code)


def reject_float(raw: str) -> None:
    raise ValueError(f"non-canonical JSON number: {raw}")


def parse_integer(raw: str) -> int:
    if raw == "-0":
        raise ValueError("negative zero is not canonical")
    return int(raw)


def strict_pairs(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def validate_domain(root: Any) -> None:
    stack = [(root, 1)]
    count = 0
    while stack:
        value, depth = stack.pop()
        fail(depth <= 40, "INTERFACE_PROTOCOL", "JSON exceeds maximum depth")
        count += 1
        fail(count <= 200000, "INTERFACE_PROTOCOL", "JSON exceeds maximum item count")
        if isinstance(value, str):
            fail(not any(ord(ch) < 32 or 127 <= ord(ch) <= 159 or 0xD800 <= ord(ch) <= 0xDFFF for ch in value),
                 "INTERFACE_PROTOCOL", "JSON contains a non-canonical string")
        elif isinstance(value, dict):
            for key, item in value.items():
                fail(isinstance(key, str), "INTERFACE_PROTOCOL", "JSON key is not a string")
                stack.extend(((key, depth + 1), (item, depth + 1)))
        elif isinstance(value, list):
            stack.extend((item, depth + 1) for item in value)
        else:
            fail(value is None or isinstance(value, (bool, int)), "INTERFACE_PROTOCOL", "JSON value is not canonical")


def loads(raw: bytes, label: str, maximum: int = MAX_JSON_BYTES) -> Any:
    fail(len(raw) <= maximum, "INTERFACE_PROTOCOL", f"{label} exceeds {maximum} bytes")
    try:
        value = json.loads(raw.decode("utf-8"), parse_float=reject_float, parse_int=parse_integer,
                           parse_constant=reject_float, object_pairs_hook=strict_pairs)
        validate_domain(value)
        return value
    except HostError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise HostError("INTERFACE_PROTOCOL", f"{label} is not canonical JSON", str(exc)) from exc


def canonical(value: Any) -> bytes:
    validate_domain(value)
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                       allow_nan=False) + "\n").encode("utf-8")


def exact(value: Any, fields: Iterable[str], label: str) -> Mapping[str, Any]:
    expected = set(fields)
    fail(isinstance(value, dict), "INTERFACE_PROTOCOL", f"{label} must be an object")
    actual = set(value)
    fail(actual == expected, "INTERFACE_PROTOCOL", f"{label} fields are invalid",
         {"missing": sorted(expected - actual), "unknown": sorted(actual - expected)})
    return value


def integer(value: Any, minimum: int = 0) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def valid_id(value: Any, maximum: int = 128) -> bool:
    return isinstance(value, str) and 1 <= len(value) <= maximum and ID_RE.fullmatch(value) is not None


def script_dir() -> Path:
    return Path(__file__).resolve().parent


@lru_cache(maxsize=1)
def trusted_policy() -> Mapping[str, str]:
    """Reconstruct policy from the config pinned beside the installed runtime."""
    config = script_dir().parent / "operator.config.env"
    try:
        info = os.lstat(config)
    except OSError as exc:
        raise HostError("TRUSTED_POLICY_UNAVAILABLE", "pinned operator config is unavailable", str(exc), 3) from exc
    fail(stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode) and info.st_uid == os.geteuid()
         and stat.S_IMODE(info.st_mode) & 0o022 == 0,
         "TRUSTED_POLICY_UNAVAILABLE", "pinned operator config ownership or mode is unsafe", str(config), 3)
    shell = ("set -eu; set -a; source \"$1\"; "
             "printf '%s\\0%s\\0%s\\0' \"$OPERATOR_DIR\" \"$CODE_DIR\" \"$OPERATOR_LANES\"")
    environment = {"PATH": SYSTEM_PATH, "LC_ALL": "C", "LANG": "C",
                   "HOME": pwd.getpwuid(os.geteuid()).pw_dir}
    try:
        completed = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", shell, "host-policy", str(config)],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=environment, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise HostError("TRUSTED_POLICY_UNAVAILABLE", "cannot load pinned operator config", str(exc), 3) from exc
    fail(completed.returncode == 0 and len(completed.stdout) <= MAX_JSON_BYTES,
         "TRUSTED_POLICY_UNAVAILABLE", "pinned operator config failed closed",
         completed.stderr[:2048].decode("utf-8", errors="replace"), 3)
    fields = completed.stdout.split(b"\0")
    fail(len(fields) == 4 and fields[-1] == b"", "TRUSTED_POLICY_UNAVAILABLE",
         "pinned operator config returned an invalid policy record", exit_code=3)
    try:
        values = [item.decode("utf-8") for item in fields[:-1]]
    except UnicodeDecodeError as exc:
        raise HostError("TRUSTED_POLICY_UNAVAILABLE", "pinned operator config is not UTF-8", str(exc), 3) from exc
    fail(all(values), "TRUSTED_POLICY_UNAVAILABLE", "pinned operator config is incomplete", exit_code=3)
    return {"operatorDir": values[0], "codeDir": values[1], "lanes": values[2], "config": str(config)}


def operator_dir() -> Path:
    raw = trusted_policy()["operatorDir"]
    path = Path(os.path.abspath(str(raw)))
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise HostError("IO_ERROR", "cannot inspect OPERATOR_DIR", str(exc), 3) from exc
    fail(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode), "IO_ERROR",
         "OPERATOR_DIR must be a real directory", str(path), 3)
    fail(info.st_uid == os.geteuid(), "IO_ERROR", "OPERATOR_DIR has unsafe ownership", str(path), 3)
    return path


def safe_component(value: str) -> str:
    fail(isinstance(value, str) and value not in {"", ".", ".."} and "/" not in value and "\x00" not in value,
         "IO_ERROR", "unsafe anchored path component", value, 3)
    return value


class AnchoredStore:
    """No-follow, descriptor-anchored access beneath one trusted directory."""

    def __init__(self, root: Path, acquire_exclusive: bool = False,
                 initialize_capability: bool = False):
        before = os.lstat(root)
        fail(stat.S_ISDIR(before.st_mode) and not stat.S_ISLNK(before.st_mode)
             and before.st_uid == os.geteuid(), "IO_ERROR", "trusted root path is unsafe", str(root), 3)
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        self.root_path = root
        self.root_fd = os.open(root, flags)
        info = os.fstat(self.root_fd)
        fail(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid()
             and (info.st_dev, info.st_ino) == (before.st_dev, before.st_ino), "IO_ERROR",
             "trusted root descriptor is unsafe", str(root), 3)
        self.root_identity = (info.st_dev, info.st_ino)
        if acquire_exclusive:
            fcntl.flock(self.root_fd, fcntl.LOCK_EX)
            self.verify_path()
        self.directory_identities: Dict[Tuple[str, ...], Optional[Tuple[int, int]]] = {}
        self.directory_fds: Dict[Tuple[str, ...], int] = {}
        self.directory_inventories: Dict[Tuple[str, ...], Set[str]] = {
            (): set(os.listdir(self.root_fd))
        }
        self.file_identities: Dict[Tuple[str, ...], Optional[Tuple[int, int]]] = {}
        self.file_fds: Dict[Tuple[str, ...], int] = {}
        self.file_manifest: Dict[Tuple[str, ...], Tuple[int, int, int, str]] = {}
        self.binding_manifest_file: Optional[Any] = None
        self.owns_directory_fds = True
        self.owns_file_fds = True
        if initialize_capability:
            self._initialize_capability()

    def _initialize_capability(self) -> None:
        # These are authority-bearing host inputs, so retain their exact
        # descriptors before any broker/session operation can be delayed.
        for parts in (("authority",), ("graph",), ("graph", "bindings")):
            descriptor = self._open_dir(parts, create=False, private=False)
            os.close(descriptor)
        for parts in (("authority", "control-graph-public-key.json"),
                      ("graph", "definition.json"), ("graph", "projection.json"),
                      ("graph", "events.jsonl")):
            self._pin_file(parts, required=parts[0] == "authority")
        self._snapshot_tree(("graph", "bindings"), include_files=True, maximum=10000,
                            depth=1, maximum_bytes=8 * 1024 * 1024)
        self._reset_binding_manifest()
        if "host" in self.directory_inventories[()]:
            descriptor = self._open_dir(("host",), create=False, private=False)
            os.close(descriptor)
            self._snapshot_tree(("host",), include_files=False, maximum=10000,
                                depth=6, maximum_bytes=0)
            for name in ("design-proof-signer.json", "design-proof-keychain.json"):
                self._pin_file(("host", name), required=False)
        else:
            self.directory_identities[("host",)] = None

    @classmethod
    def from_descriptor(cls, descriptor: int, root_path: Path,
                        directory_identities: Optional[Dict[Tuple[str, ...], Optional[Tuple[int, int]]]] = None,
                        directory_fds: Optional[Dict[Tuple[str, ...], int]] = None,
                        directory_inventories: Optional[Dict[Tuple[str, ...], Set[str]]] = None,
                        file_identities: Optional[Dict[Tuple[str, ...], Optional[Tuple[int, int]]]] = None,
                        file_fds: Optional[Dict[Tuple[str, ...], int]] = None,
                        file_manifest: Optional[Dict[Tuple[str, ...], Tuple[int, int, int, str]]] = None) -> "AnchoredStore":
        store = cls.__new__(cls)
        store.root_fd = os.dup(descriptor)
        store.root_path = root_path
        info = os.fstat(store.root_fd)
        fail(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(),
             "IO_ERROR", "held trusted root descriptor is unsafe", exit_code=3)
        store.root_identity = (info.st_dev, info.st_ino)
        store.directory_identities = (directory_identities if directory_identities is not None else {})
        store.directory_fds = (directory_fds if directory_fds is not None else {})
        store.owns_directory_fds = directory_fds is None
        store.directory_inventories = (directory_inventories if directory_inventories is not None else {
            (): set(os.listdir(store.root_fd))
        })
        store.file_identities = (file_identities if file_identities is not None else {})
        store.file_fds = (file_fds if file_fds is not None else {})
        store.owns_file_fds = file_fds is None
        store.file_manifest = (file_manifest if file_manifest is not None else {})
        store.binding_manifest_file = None
        for parts in (("authority",), ("graph",), ("graph", "bindings")):
            child = store._open_dir(parts, create=False, private=False)
            os.close(child)
        for parts in (("authority", "control-graph-public-key.json"),
                      ("graph", "definition.json"), ("graph", "projection.json"),
                      ("graph", "events.jsonl")):
            store._pin_file(parts, required=parts[0] == "authority")
        if not store.file_manifest:
            store._snapshot_tree(("graph", "bindings"), include_files=True, maximum=10000,
                                 depth=1, maximum_bytes=8 * 1024 * 1024)
        store._reset_binding_manifest()
        host_present = (store.directory_identities.get(("host",)) is not None
                        if ("host",) in store.directory_identities
                        else "host" in store.directory_inventories.get((), set()))
        if host_present:
            child = store._open_dir(("host",), create=False, private=False)
            os.close(child)
            if not store.file_manifest:
                store._snapshot_tree(("host",), include_files=False, maximum=10000,
                                     depth=6, maximum_bytes=0)
            for name in ("design-proof-signer.json", "design-proof-keychain.json"):
                store._pin_file(("host", name), required=False)
        else:
            store.directory_identities[("host",)] = None
        return store

    def verify_path(self) -> None:
        try:
            before = os.lstat(self.root_path)
            fail(stat.S_ISDIR(before.st_mode) and not stat.S_ISLNK(before.st_mode)
                 and before.st_uid == os.geteuid()
                 and (before.st_dev, before.st_ino) == self.root_identity,
                 "IO_ERROR", "trusted OPERATOR_DIR identity changed", str(self.root_path), 3)
            descriptor = os.open(self.root_path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                                 | getattr(os, "O_NOFOLLOW", 0))
            try:
                current = os.fstat(descriptor)
                fail((current.st_dev, current.st_ino) == self.root_identity
                     and stat.S_ISDIR(current.st_mode) and current.st_uid == os.geteuid(),
                     "IO_ERROR", "trusted OPERATOR_DIR changed during verification",
                     str(self.root_path), 3)
            finally:
                os.close(descriptor)
        except HostError:
            raise
        except OSError as exc:
            raise HostError("IO_ERROR", "cannot verify trusted OPERATOR_DIR identity", str(exc), 3) from exc

    def close(self) -> None:
        if self.binding_manifest_file is not None:
            with contextlib.suppress(OSError):
                self.binding_manifest_file.close()
            self.binding_manifest_file = None
        if self.owns_file_fds:
            for descriptor in self.file_fds.values():
                with contextlib.suppress(OSError):
                    os.close(descriptor)
            self.file_fds.clear()
        if self.owns_directory_fds:
            for descriptor in self.directory_fds.values():
                with contextlib.suppress(OSError):
                    os.close(descriptor)
            self.directory_fds.clear()
        os.close(self.root_fd)

    def _reset_binding_manifest(self) -> None:
        if self.binding_manifest_file is not None:
            with contextlib.suppress(OSError):
                self.binding_manifest_file.close()
        entries: List[Dict[str, Any]] = []
        for parts, record in sorted(self.file_manifest.items()):
            if len(parts) == 3 and parts[:2] == ("graph", "bindings"):
                entries.append({"name": parts[2], "dev": record[0], "ino": record[1],
                                "size": record[2], "sha256": record[3]})
        fail(len(entries) <= 10000, "IO_ERROR", "binding capability manifest exceeds its item bound", exit_code=3)
        encoded = canonical({"schemaVersion": "operator.binding-capability-manifest/v1",
                             "entries": entries})
        fail(len(encoded) <= MAX_JSON_BYTES, "IO_ERROR",
             "binding capability manifest exceeds its byte bound", exit_code=3)
        self.binding_manifest_file = tempfile.TemporaryFile()
        self.binding_manifest_file.write(encoded)
        self.binding_manifest_file.flush()
        self.binding_manifest_file.seek(0)

    def read_manifest_bytes(self, components: Sequence[str], maximum: int,
                            label: str) -> bytes:
        """Read one pre-inventoried leaf without retaining an FD."""
        key = tuple(components)
        record = self.file_manifest.get(key)
        fail(record is not None, "IO_ERROR", f"{label} was absent from the command-root manifest",
             "/".join(components), 3)
        parent = self._open_dir(components[:-1], create=False, private=False)
        descriptor: Optional[int] = None
        try:
            descriptor = os.open(safe_component(components[-1]), os.O_RDONLY
                                 | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent)
            before = os.fstat(descriptor)
            fail(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                 and before.st_nlink == 1 and before.st_size <= maximum
                 and (before.st_dev, before.st_ino, before.st_size) == record[:3],
                 "IO_ERROR", f"{label} differs from the command-root manifest",
                 "/".join(components), 3)
            data = bytearray()
            while len(data) <= maximum:
                chunk = os.read(descriptor, min(65536, maximum + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
            after = os.fstat(descriptor)
            fail(len(data) == before.st_size and len(data) <= maximum
                 and (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                 == (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                 and hashlib.sha256(data).hexdigest() == record[3],
                 "IO_ERROR", f"{label} changed during manifest-bound read",
                 "/".join(components), 3)
            return bytes(data)
        finally:
            if descriptor is not None:
                os.close(descriptor)
            os.close(parent)

    def open_candidate_bytes(self, components: Sequence[str], maximum: int,
                             label: str) -> Tuple[int, bytes, Tuple[int, int]]:
        """Open a possible authorized replacement without adopting its identity."""
        parent = self._open_dir(components[:-1], create=False, private=False)
        descriptor: Optional[int] = None
        try:
            descriptor = os.open(safe_component(components[-1]), os.O_RDONLY
                                 | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent)
            before = os.fstat(descriptor)
            fail(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                 and before.st_nlink == 1 and before.st_size <= maximum,
                 "IO_ERROR", f"{label} replacement is unsafe", "/".join(components), 3)
            data = bytearray()
            while len(data) <= maximum:
                chunk = os.pread(descriptor, min(65536, maximum + 1 - len(data)), len(data))
                if not chunk:
                    break
                data.extend(chunk)
            after = os.fstat(descriptor)
            published = os.stat(safe_component(components[-1]), dir_fd=parent, follow_symlinks=False)
            identity = (before.st_dev, before.st_ino)
            fail(len(data) == before.st_size and len(data) <= maximum
                 and (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                 == (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                 and stat.S_ISREG(published.st_mode) and not stat.S_ISLNK(published.st_mode)
                 and (published.st_dev, published.st_ino) == identity,
                 "IO_ERROR", f"{label} replacement changed during open", "/".join(components), 3)
            result = descriptor
            descriptor = None
            return result, bytes(data), identity
        finally:
            if descriptor is not None:
                os.close(descriptor)
            os.close(parent)

    def adopt_candidate(self, components: Sequence[str], descriptor: int,
                        identity: Tuple[int, int], data: bytes) -> None:
        key = tuple(components)
        parent = self._open_dir(components[:-1], create=False, private=False)
        try:
            current = os.stat(safe_component(components[-1]), dir_fd=parent, follow_symlinks=False)
            held = os.fstat(descriptor)
            fail(stat.S_ISREG(current.st_mode) and not stat.S_ISLNK(current.st_mode)
                 and current.st_uid == os.geteuid() and current.st_nlink == 1
                 and (current.st_dev, current.st_ino) == identity
                 and (held.st_dev, held.st_ino) == identity,
                 "IO_ERROR", "graph materialization changed before capability adoption",
                 "/".join(components), 3)
            old = self.file_fds.get(key)
            self.file_fds[key] = descriptor
            self.file_identities[key] = identity
            self.file_manifest[key] = (held.st_dev, held.st_ino, held.st_size,
                                       hashlib.sha256(data).hexdigest())
            if old is not None and old != descriptor:
                with contextlib.suppress(OSError):
                    os.close(old)
        finally:
            os.close(parent)

    def _pin_file(self, components: Sequence[str], required: bool = True) -> None:
        key = tuple(components)
        parent = self._open_dir(components[:-1], create=False, private=False)
        descriptor: Optional[int] = None
        try:
            try:
                access = (os.O_RDWR if key == ("graph", "events.jsonl") else os.O_RDONLY)
                descriptor = os.open(safe_component(components[-1]), access
                                     | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent)
            except FileNotFoundError:
                expected = self.file_identities.setdefault(key, None)
                fail(expected is None, "IO_ERROR", "anchored file disappeared",
                     "/".join(components), 3)
                if required:
                    raise
                return
            info = os.fstat(descriptor)
            fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
                 and info.st_nlink == 1, "IO_ERROR", "anchored file is unsafe",
                 "/".join(components), 3)
            identity = (info.st_dev, info.st_ino)
            manifest = self.file_manifest.get(key)
            if manifest is not None:
                fail((info.st_dev, info.st_ino, info.st_size) == manifest[:3], "IO_ERROR",
                     "anchored file differs from the command-root manifest", "/".join(components), 3)
                digest = hashlib.sha256()
                offset = 0
                while offset < info.st_size:
                    chunk = os.pread(descriptor, min(65536, info.st_size - offset), offset)
                    fail(bool(chunk), "IO_ERROR", "anchored file changed during manifest verification",
                         "/".join(components), 3)
                    digest.update(chunk); offset += len(chunk)
                fail(digest.hexdigest() == manifest[3], "IO_ERROR",
                     "anchored file content differs from the command-root manifest",
                     "/".join(components), 3)
            expected = self.file_identities.setdefault(key, identity)
            fail(expected == identity, "IO_ERROR", "anchored file identity changed",
                 "/".join(components), 3)
            if key not in self.file_fds:
                self.file_fds[key] = descriptor
                descriptor = None
        finally:
            if descriptor is not None:
                os.close(descriptor)
            os.close(parent)

    def pin_file_state(self, components: Sequence[str]) -> None:
        """Retain an existing regular leaf, or bind its exact absence."""
        self._pin_file(components, required=False)

    def _snapshot_tree(self, components: Sequence[str], include_files: bool,
                       maximum: int, depth: int, maximum_bytes: int) -> None:
        root = self._open_dir(components, create=False, private=False)
        count = 0
        total_bytes = 0
        def walk(descriptor: int, key: Tuple[str, ...], remaining: int) -> None:
            nonlocal count, total_bytes
            names = sorted(os.listdir(descriptor))
            self.directory_inventories[key] = set(names)
            for name in names:
                count += 1
                fail(count <= maximum, "IO_ERROR", "command-root inventory exceeds its bound",
                     "/".join(components), 3)
                info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                child_key = (*key, name)
                if stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode):
                    self.directory_identities[child_key] = (info.st_dev, info.st_ino)
                    if remaining > 0:
                        child = os.open(name, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                                        | getattr(os, "O_NOFOLLOW", 0), dir_fd=descriptor)
                        try:
                            walk(child, child_key, remaining - 1)
                        finally:
                            os.close(child)
                elif include_files and stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode):
                    total_bytes += info.st_size
                    fail(info.st_uid == os.geteuid() and info.st_nlink == 1
                         and info.st_size <= 65536 and total_bytes <= maximum_bytes, "IO_ERROR",
                         "command-root file inventory is unsafe", "/".join(child_key), 3)
                    leaf = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=descriptor)
                    try:
                        digest = hashlib.sha256()
                        offset = 0
                        while offset < info.st_size:
                            chunk = os.pread(leaf, min(65536, info.st_size - offset), offset)
                            fail(bool(chunk), "IO_ERROR", "command-root file changed during inventory",
                                 "/".join(child_key), 3)
                            digest.update(chunk); offset += len(chunk)
                        self.file_manifest[child_key] = (info.st_dev, info.st_ino,
                                                         info.st_size, digest.hexdigest())
                    finally:
                        os.close(leaf)
        try:
            walk(root, tuple(components), depth)
        finally:
            os.close(root)

    def _pin_existing_tree(self, components: Sequence[str], maximum: int) -> None:
        pending: List[Tuple[str, ...]] = [tuple(components)]
        seen = 0
        while pending:
            current_parts = pending.pop()
            directory = self._open_dir(current_parts, create=False, private=False)
            try:
                for name in sorted(os.listdir(directory)):
                    seen += 1
                    fail(seen <= maximum, "IO_ERROR", "anchored file inventory exceeds its bound",
                         "/".join(components), 3)
                    info = os.stat(name, dir_fd=directory, follow_symlinks=False)
                    child_parts = (*current_parts, name)
                    if stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode):
                        child = self._open_dir(child_parts, create=False, private=False)
                        os.close(child)
                        pending.append(child_parts)
                    elif stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode):
                        self._pin_file(child_parts, required=True)
                    else:
                        fail(False, "IO_ERROR", "anchored inventory contains an unsafe entry",
                             "/".join(child_parts), 3)
            finally:
                os.close(directory)

    def _pin_existing_directories(self, components: Sequence[str], maximum: int,
                                  depth: int) -> None:
        pending: List[Tuple[Tuple[str, ...], int]] = [(tuple(components), depth)]
        seen = 0
        while pending:
            current_parts, remaining = pending.pop()
            directory = self._open_dir(current_parts, create=False, private=False)
            try:
                if remaining == 0:
                    continue
                for name in sorted(os.listdir(directory)):
                    info = os.stat(name, dir_fd=directory, follow_symlinks=False)
                    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
                        continue
                    seen += 1
                    fail(seen <= maximum, "IO_ERROR", "anchored directory inventory exceeds its bound",
                         "/".join(components), 3)
                    child_parts = (*current_parts, name)
                    child = self._open_dir(child_parts, create=False, private=False)
                    os.close(child)
                    pending.append((child_parts, remaining - 1))
            finally:
                os.close(directory)

    def _pin_regular_children(self, components: Sequence[str]) -> None:
        directory = self._open_dir(components, create=False, private=False)
        try:
            for name in sorted(os.listdir(directory)):
                info = os.stat(name, dir_fd=directory, follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode):
                    continue
                fail(stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode),
                     "IO_ERROR", "host authority inventory contains an unsafe entry", name, 3)
                self._pin_file((*components, name), required=True)
        finally:
            os.close(directory)

    def assert_file(self, components: Sequence[str]) -> None:
        key = tuple(components)
        fail(key in self.file_identities, "IO_ERROR", "anchored file was not pinned",
             "/".join(components), 3)
        parent = self._open_dir(components[:-1], create=False, private=False)
        try:
            try:
                info = os.stat(safe_component(components[-1]), dir_fd=parent, follow_symlinks=False)
                current: Optional[Tuple[int, int]] = ((info.st_dev, info.st_ino)
                                                       if stat.S_ISREG(info.st_mode)
                                                       and not stat.S_ISLNK(info.st_mode)
                                                       and info.st_uid == os.geteuid()
                                                       and info.st_nlink == 1 else (-1, -1))
            except FileNotFoundError:
                current = None
            fail(current == self.file_identities[key], "IO_ERROR", "anchored file identity changed",
                 "/".join(components), 3)
        finally:
            os.close(parent)

    @property
    def descriptor(self) -> int:
        return self.root_fd

    @property
    def path(self) -> Path:
        return self.root_path

    def __enter__(self) -> "AnchoredStore":
        return self

    def __exit__(self, _kind: Any, _value: Any, _traceback: Any) -> None:
        self.close()

    def _open_dir(self, components: Sequence[str], create: bool = False,
                  private: bool = False) -> int:
        self.verify_path()
        descriptor = os.dup(self.root_fd)
        traversed: List[str] = []
        try:
            for raw in components:
                component = safe_component(raw)
                parent_key = tuple(traversed)
                traversed.append(component)
                key = tuple(traversed)
                if key not in self.directory_identities and parent_key in self.directory_inventories:
                    if component not in self.directory_inventories[parent_key]:
                        self.directory_identities[key] = None
                expected = self.directory_identities.get(key, "unknown")
                if expected is None:
                    if not create:
                        raise FileNotFoundError("/".join(traversed))
                    try:
                        os.mkdir(component, 0o700 if private else 0o755, dir_fd=descriptor)
                    except FileExistsError as exc:
                        raise HostError("IO_ERROR", "anchored directory appeared after its snapshot",
                                        "/".join(traversed), 3) from exc
                    self.directory_inventories.setdefault(parent_key, set()).add(component)
                flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
                if key in self.directory_fds:
                    published = os.stat(component, dir_fd=descriptor, follow_symlinks=False)
                    fail(stat.S_ISDIR(published.st_mode) and not stat.S_ISLNK(published.st_mode)
                         and (published.st_dev, published.st_ino) == self.directory_identities[key],
                         "IO_ERROR", "anchored directory identity changed", "/".join(traversed), 3)
                    next_descriptor = os.dup(self.directory_fds[key])
                else:
                    next_descriptor = os.open(component, flags, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = next_descriptor
                info = os.fstat(descriptor)
                fail(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(), "IO_ERROR",
                     "anchored directory is unsafe", component, 3)
                identity = (info.st_dev, info.st_ino)
                prior = self.directory_identities.setdefault(key, identity)
                if prior is None:
                    self.directory_identities[key] = identity
                    prior = identity
                fail(identity == prior, "IO_ERROR",
                     "anchored directory identity changed", "/".join(traversed), 3)
                if key not in self.directory_fds:
                    self.directory_fds[key] = os.dup(descriptor)
                    self.directory_inventories.setdefault(key, set(os.listdir(descriptor)))
                if private:
                    fail(info.st_nlink >= 2, "IO_ERROR", "anchored directory link count is invalid", component, 3)
                    os.fchmod(descriptor, 0o700)
            return descriptor
        except BaseException:
            with contextlib.suppress(OSError):
                os.close(descriptor)
            raise

    def ensure_dir(self, components: Sequence[str], private: bool = True) -> Path:
        descriptor = self._open_dir(components, create=True, private=private)
        os.close(descriptor)
        return self.root_path.joinpath(*components)

    def listdir(self, components: Sequence[str]) -> list[str]:
        descriptor = self._open_dir(components, create=False, private=False)
        try:
            return sorted(os.listdir(descriptor))
        finally:
            os.close(descriptor)

    def exists(self, components: Sequence[str]) -> bool:
        try:
            parent = self._open_dir(components[:-1], create=False, private=True)
        except FileNotFoundError:
            return False
        try:
            try:
                info = os.stat(safe_component(components[-1]), dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                return False
            return stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode)
        finally:
            os.close(parent)

    def read_bytes(self, components: Sequence[str], maximum: int,
                   private: bool = True) -> bytes:
        key = tuple(components)
        if key not in self.file_identities:
            self._pin_file(components, required=True)
        self.assert_file(components)
        descriptor = os.dup(self.file_fds[key])
        try:
            info = os.fstat(descriptor)
            fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1,
                 "IO_ERROR", "anchored file is unsafe", components[-1], 3)
            if private:
                fail(stat.S_IMODE(info.st_mode) & 0o077 == 0, "IO_ERROR",
                     "private anchored file permissions are unsafe", components[-1], 3)
            os.lseek(descriptor, 0, os.SEEK_SET)
            data = bytearray()
            while len(data) <= maximum:
                chunk = os.read(descriptor, min(65536, maximum + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
            final = os.fstat(descriptor)
            fail(len(data) <= maximum and len(data) == final.st_size
                 and (final.st_dev, final.st_ino) == self.file_identities[key],
                 "IO_ERROR", "anchored file changed during read", components[-1], 3)
            self.assert_file(components)
            return bytes(data)
        finally:
            os.close(descriptor)

    def read_json(self, components: Sequence[str], label: str, maximum: int = 65536,
                  private: bool = True) -> Mapping[str, Any]:
        value = loads(self.read_bytes(components, maximum, private), label, maximum)
        fail(isinstance(value, dict), "IO_ERROR", f"{label} must be an object", exit_code=3)
        return value

    def atomic_write_bytes(self, components: Sequence[str], encoded: bytes,
                           private: bool = True) -> None:
        parent = self._open_dir(components[:-1], create=True, private=private)
        key = tuple(components)
        leaf = safe_component(components[-1])
        temporary = f".{leaf}.{os.getpid()}.{os.urandom(8).hex()}"
        try:
            try:
                existing = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
                fail(stat.S_ISREG(existing.st_mode) and not stat.S_ISLNK(existing.st_mode)
                     and existing.st_uid == os.geteuid() and existing.st_nlink == 1,
                     "IO_ERROR", "anchored destination is unsafe", leaf, 3)
                identity = (existing.st_dev, existing.st_ino)
                expected = self.file_identities.setdefault(key, identity)
                fail(expected == identity, "IO_ERROR", "anchored destination identity changed", leaf, 3)
            except FileNotFoundError:
                expected = self.file_identities.setdefault(key, None)
                fail(expected is None, "IO_ERROR", "anchored destination disappeared", leaf, 3)
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(temporary, flags, 0o600 if private else 0o644, dir_fd=parent)
            try:
                os.fchmod(descriptor, 0o600 if private else 0o644)
                view = memoryview(encoded)
                while view:
                    written = os.write(descriptor, view)
                    view = view[written:]
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            self.verify_path()
            self.assert_file(components)
            os.rename(temporary, leaf, src_dir_fd=parent, dst_dir_fd=parent)
            final_descriptor = os.open(leaf, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent)
            try:
                final = os.fstat(final_descriptor)
                fail(stat.S_ISREG(final.st_mode) and final.st_uid == os.geteuid() and final.st_nlink == 1,
                     "IO_ERROR", "anchored destination changed during commit", leaf, 3)
            finally:
                os.close(final_descriptor)
            os.fsync(parent)
            old = self.file_fds.pop(key, None)
            if old is not None:
                os.close(old)
            self.file_identities.pop(key, None)
            self._pin_file(components, required=True)
            self.verify_path()
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary, dir_fd=parent)
            os.close(parent)

    def atomic_write_json(self, components: Sequence[str], value: Any,
                          private: bool = True) -> None:
        self.atomic_write_bytes(components, canonical(value), private)

    def open_lock(self, components: Sequence[str]) -> int:
        parent = self._open_dir(components[:-1], create=True, private=True)
        key = tuple(components)
        try:
            leaf = safe_component(components[-1])
            if key not in self.file_identities or self.file_identities[key] is None:
                try:
                    descriptor = os.open(leaf, os.O_RDWR | os.O_CREAT | os.O_EXCL
                                         | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=parent)
                    info = os.fstat(descriptor)
                    expected = self.file_identities.get(key)
                    fail(expected is None, "IO_ERROR", "anchored lock appeared after its pin boundary",
                         components[-1], 3)
                    self.file_identities[key] = (info.st_dev, info.st_ino)
                    self.file_fds[key] = os.dup(descriptor)
                except FileExistsError:
                    self._pin_file(components, required=True)
                    descriptor = os.open(leaf, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent)
            else:
                self.assert_file(components)
                descriptor = os.open(leaf, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent)
            info = os.fstat(descriptor)
            fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1,
                 "IO_ERROR", "anchored lock file is unsafe", components[-1], 3)
            fail((info.st_dev, info.st_ino) == self.file_identities[key], "IO_ERROR",
                 "anchored lock file identity changed", components[-1], 3)
            os.fchmod(descriptor, 0o600)
            return descriptor
        finally:
            os.close(parent)


_ACTIVE_HOST_ROOT: Optional[AnchoredStore] = None


def held_store() -> AnchoredStore:
    fail(_ACTIVE_HOST_ROOT is not None, "IO_ERROR",
         "host command has no held Operator root", exit_code=3)
    assert _ACTIVE_HOST_ROOT is not None
    _ACTIVE_HOST_ROOT.verify_path()
    return AnchoredStore.from_descriptor(_ACTIVE_HOST_ROOT.root_fd,
                                         _ACTIVE_HOST_ROOT.root_path,
                                         _ACTIVE_HOST_ROOT.directory_identities,
                                         _ACTIVE_HOST_ROOT.directory_fds,
                                         _ACTIVE_HOST_ROOT.directory_inventories,
                                         _ACTIVE_HOST_ROOT.file_identities,
                                         _ACTIVE_HOST_ROOT.file_fds,
                                         _ACTIVE_HOST_ROOT.file_manifest)


@contextlib.contextmanager
def borrowed_active_store() -> Any:
    """Borrow the command-root cache without re-pinning authorized mutations."""
    fail(_ACTIVE_HOST_ROOT is not None, "IO_ERROR",
         "host command has no held Operator root", exit_code=3)
    assert _ACTIVE_HOST_ROOT is not None
    _ACTIVE_HOST_ROOT.verify_path()
    yield _ACTIVE_HOST_ROOT


def capability_environment(prefix: str, store: AnchoredStore) -> Tuple[Dict[str, str], Tuple[int, ...]]:
    environment: Dict[str, str] = {}
    descriptors: List[int] = [store.root_fd]
    for name, key in (("AUTHORITY", ("authority",)), ("GRAPH", ("graph",)),
                      ("BINDINGS", ("graph", "bindings")), ("HOST", ("host",))):
        descriptor = store.directory_fds.get(key)
        if descriptor is None and name == "HOST":
            continue
        fail(descriptor is not None, "IO_ERROR", f"held {name.lower()} capability is unavailable", exit_code=3)
        assert descriptor is not None
        info = os.fstat(descriptor)
        environment[f"{prefix}_{name}_FD"] = str(descriptor)
        environment[f"{prefix}_{name}_DEV"] = str(info.st_dev)
        environment[f"{prefix}_{name}_INO"] = str(info.st_ino)
        descriptors.append(descriptor)
    leaves: Dict[str, Any] = {}
    for key, identity in sorted(store.file_identities.items()):
        fixed = key in {("authority", "control-graph-public-key.json"),
                        ("graph", "definition.json"), ("graph", "projection.json"),
                        ("graph", "events.jsonl")}
        exact_binding = key[:2] == ("graph", "bindings")
        exact_host = (key[:2] in {("host", "sessions"), ("host", "invocations")}
                      or (len(key) == 2 and key[0] == "host"
                          and key[1] in {"design-proof-signer.json", "design-proof-keychain.json"}))
        if not (fixed or exact_binding or exact_host):
            continue
        path = "/".join(key)
        if identity is None:
            leaves[path] = None
            continue
        descriptor = store.file_fds[key]
        info = os.fstat(descriptor)
        leaves[path] = [descriptor, info.st_dev, info.st_ino]
        descriptors.append(descriptor)
    fail(len(leaves) <= 32, "IO_ERROR", "child leaf capability set exceeds its bound", exit_code=3)
    environment[f"{prefix}_LEAF_CAPS"] = json.dumps(leaves, sort_keys=True, separators=(",", ":"))
    fail(store.binding_manifest_file is not None, "IO_ERROR",
         "child binding capability manifest is unavailable", exit_code=3)
    manifest_fd = store.binding_manifest_file.fileno()
    environment[f"{prefix}_BINDING_MANIFEST_FD"] = str(manifest_fd)
    descriptors.append(manifest_fd)
    return environment, tuple(dict.fromkeys(descriptors))


def host_root_environment() -> Tuple[Dict[str, str], Tuple[int, ...]]:
    fail(_ACTIVE_HOST_ROOT is not None, "IO_ERROR",
         "host graph child has no held Operator root", exit_code=3)
    assert _ACTIVE_HOST_ROOT is not None
    _ACTIVE_HOST_ROOT.verify_path()
    info = os.fstat(_ACTIVE_HOST_ROOT.root_fd)
    environment = {
        "OPERATOR_DIR": str(_ACTIVE_HOST_ROOT.root_path),
        "OPERATOR_HOST_ROOT_FD": str(_ACTIVE_HOST_ROOT.root_fd),
        "OPERATOR_HOST_ROOT_DEV": str(info.st_dev),
        "OPERATOR_HOST_ROOT_INO": str(info.st_ino),
        "OPERATOR_HOST_ROOT_PATH": str(_ACTIVE_HOST_ROOT.root_path),
        "OPERATOR_HOST_ROOT_LOCK_MODE": "exclusive-held",
    }
    child_environment, descriptors = capability_environment("OPERATOR_HOST_ROOT", _ACTIVE_HOST_ROOT)
    environment.update(child_environment)
    return environment, descriptors


def command_root() -> AnchoredStore:
    prefixes = [prefix for prefix in ("OPERATOR_HOST_ROOT", "OPERATOR_DESIGN_FLOW_ROOT")
                if f"{prefix}_FD" in os.environ]
    fail(len(prefixes) <= 1, "IO_ERROR", "host received ambiguous root capabilities", exit_code=3)
    if not prefixes:
        return AnchoredStore(operator_dir(), acquire_exclusive=True, initialize_capability=True)
    prefix = prefixes[0]
    raw_fd = os.environ.get(f"{prefix}_FD", "")
    raw_dev = os.environ.get(f"{prefix}_DEV", "")
    raw_ino = os.environ.get(f"{prefix}_INO", "")
    raw_path = os.environ.get(f"{prefix}_PATH", "")
    fail(raw_fd.isdigit() and raw_dev.isdigit() and raw_ino.isdigit()
         and os.path.isabs(raw_path)
         and os.environ.get(f"{prefix}_LOCK_MODE") == "exclusive-held", "IO_ERROR",
         "inherited host root capability is invalid", exit_code=3)
    root_descriptor = int(raw_fd)
    directory_identities: Dict[Tuple[str, ...], Optional[Tuple[int, int]]] = {}
    directory_fds: Dict[Tuple[str, ...], int] = {}
    file_identities: Dict[Tuple[str, ...], Optional[Tuple[int, int]]] = {}
    file_fds: Dict[Tuple[str, ...], int] = {}
    inherited_file_manifest: Dict[Tuple[str, ...], Tuple[int, int, int, str]] = {}

    def components(raw: str) -> Tuple[str, ...]:
        parts = tuple(raw.split("/")) if raw else ()
        fail(bool(parts) and all(part not in {"", ".", ".."} and "/" not in part for part in parts),
             "IO_ERROR", "inherited capability path is invalid", raw, 3)
        return parts

    try:
        raw_files = json.loads(os.environ.get(f"{prefix}_LEAF_CAPS", "{}"))
        fail(isinstance(raw_files, dict) and len(raw_files) <= 32, "IO_ERROR",
             "inherited child capability cache is invalid", exit_code=3)
        for name, key in (("AUTHORITY", ("authority",)), ("GRAPH", ("graph",)),
                          ("BINDINGS", ("graph", "bindings")), ("HOST", ("host",))):
            child_fd = os.environ.get(f"{prefix}_{name}_FD", "")
            child_dev = os.environ.get(f"{prefix}_{name}_DEV", "")
            child_ino = os.environ.get(f"{prefix}_{name}_INO", "")
            if name == "HOST" and not child_fd:
                directory_identities[key] = None
                continue
            fail(child_fd.isdigit() and child_dev.isdigit() and child_ino.isdigit(),
                 "IO_ERROR", "inherited directory capability is invalid", name, 3)
            descriptor = os.dup(int(child_fd)); info = os.fstat(descriptor)
            fail(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid()
                 and (info.st_dev, info.st_ino) == (int(child_dev), int(child_ino)),
                 "IO_ERROR", "inherited directory capability identity changed", name, 3)
            directory_fds[key] = descriptor
            directory_identities[key] = (info.st_dev, info.st_ino)
        for raw_name, record in raw_files.items():
            key = components(raw_name)
            if record is None:
                file_identities[key] = None
                continue
            fail(isinstance(record, list) and len(record) == 3
                 and all(isinstance(item, int) and not isinstance(item, bool) for item in record),
                 "IO_ERROR", "inherited leaf capability record is invalid", raw_name, 3)
            descriptor = os.dup(record[0]); info = os.fstat(descriptor)
            fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1
                 and (info.st_dev, info.st_ino) == (record[1], record[2]),
                 "IO_ERROR", "inherited leaf capability identity changed", raw_name, 3)
            file_fds[key] = descriptor
            file_identities[key] = (info.st_dev, info.st_ino)
            digest = hashlib.sha256()
            offset = 0
            while offset < info.st_size:
                chunk = os.pread(descriptor, min(65536, info.st_size - offset), offset)
                fail(bool(chunk), "IO_ERROR", "inherited leaf changed during verification", raw_name, 3)
                digest.update(chunk); offset += len(chunk)
            inherited_file_manifest[key] = (info.st_dev, info.st_ino, info.st_size,
                                            digest.hexdigest())
        store = AnchoredStore.from_descriptor(root_descriptor, Path(os.path.abspath(raw_path)),
                                              directory_identities, directory_fds, None,
                                              file_identities, file_fds, inherited_file_manifest)
        binding_manifest_fd = os.environ.get(f"{prefix}_BINDING_MANIFEST_FD", "")
        fail(binding_manifest_fd.isdigit(), "IO_ERROR",
             "inherited binding manifest FD is invalid", exit_code=3)
        if binding_manifest_fd:
            manifest_descriptor = os.dup(int(binding_manifest_fd))
            try:
                os.lseek(manifest_descriptor, 0, os.SEEK_SET)
                manifest_raw = os.read(manifest_descriptor, MAX_JSON_BYTES + 1)
            finally:
                os.close(manifest_descriptor)
            manifest = loads(manifest_raw, "binding capability manifest", MAX_JSON_BYTES)
            fail(manifest_raw == canonical(manifest)
                 and manifest.get("schemaVersion") == "operator.binding-capability-manifest/v1"
                 and isinstance(manifest.get("entries"), list)
                 and len(manifest["entries"]) <= 10000,
                 "IO_ERROR", "inherited binding capability manifest is invalid", exit_code=3)
            seen_binding_names: Set[str] = set()
            binding_bytes = 0
            for record in manifest["entries"]:
                fail(isinstance(record, dict)
                     and set(record) == {"name", "dev", "ino", "size", "sha256"}
                     and isinstance(record["name"], str) and record["name"].endswith(".json")
                     and record["name"] not in seen_binding_names
                     and "/" not in record["name"] and record["name"] not in {".", ".."}
                     and all(integer(record[field]) for field in ("dev", "ino", "size"))
                     and record["size"] <= 65536
                     and isinstance(record["sha256"], str)
                     and re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) is not None,
                     "IO_ERROR", "inherited binding capability entry is invalid", exit_code=3)
                seen_binding_names.add(record["name"])
                binding_bytes += record["size"]
                fail(binding_bytes <= 8 * 1024 * 1024, "IO_ERROR",
                     "inherited binding capability manifest exceeds its aggregate byte bound", exit_code=3)
                key = ("graph", "bindings", record["name"])
                value = (record["dev"], record["ino"], record["size"], record["sha256"])
                fail(key not in store.file_manifest or store.file_manifest[key] == value,
                     "IO_ERROR", "exact binding capability conflicts with its manifest", record["name"], 3)
                store.file_manifest[key] = value
            store._reset_binding_manifest()
        store.owns_directory_fds = True
        store.owns_file_fds = True
    except BaseException:
        for descriptor in (*directory_fds.values(), *file_fds.values()):
            with contextlib.suppress(OSError):
                os.close(descriptor)
        raise
    expected = (int(raw_dev), int(raw_ino))
    fail(store.root_identity == expected, "IO_ERROR",
         "inherited host root descriptor identity changed", exit_code=3)
    configured = operator_dir()
    fail(str(configured) == str(store.root_path), "IO_ERROR",
         "inherited host root path differs from trusted policy", exit_code=3)
    store.verify_path()
    return store


def session_parts(tool: str, session: str) -> Tuple[str, ...]:
    fail(tool in {"codex", "claude"} and valid_id(session, 256), "USAGE", "tool or session is invalid", exit_code=2)
    digest = hashlib.sha256(session.encode("utf-8")).hexdigest()
    return ("host", "sessions", tool, f"{digest}.json")


def process_identity(pid: int) -> Mapping[str, Any]:
    fail(integer(pid, 1), "AUTHORITY_DENIED", "host process identity is invalid")
    if sys.platform == "darwin":
        class ProcBSDInfo(ctypes.Structure):
            _fields_ = [("flags", ctypes.c_uint32), ("status", ctypes.c_uint32),
                        ("xstatus", ctypes.c_uint32), ("pid", ctypes.c_uint32),
                        ("ppid", ctypes.c_uint32), ("uid", ctypes.c_uint32),
                        ("gid", ctypes.c_uint32), ("ruid", ctypes.c_uint32),
                        ("rgid", ctypes.c_uint32), ("svuid", ctypes.c_uint32),
                        ("svgid", ctypes.c_uint32), ("rfu", ctypes.c_uint32),
                        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
                        ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
                        ("pjobc", ctypes.c_uint32), ("tdev", ctypes.c_uint32),
                        ("tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32),
                        ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)]
        info = ProcBSDInfo()
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        result = libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        fail(result == ctypes.sizeof(info) and info.pid == pid, "AUTHORITY_DENIED",
             "host process identity is unavailable", pid, 4)
        path_buffer = ctypes.create_string_buffer(4096)
        path_length = libproc.proc_pidpath(pid, path_buffer, ctypes.sizeof(path_buffer))
        fail(path_length > 0, "AUTHORITY_DENIED", "host process executable identity is unavailable", pid, 4)
        return {"pid": int(info.pid), "parentPid": int(info.ppid), "uid": int(info.uid),
                "startedAt": f"{info.start_sec}:{info.start_usec}",
                "executable": path_buffer.value.decode("utf-8", errors="strict")}
    if sys.platform.startswith("linux"):
        try:
            raw = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
            closing = raw.rfind(")")
            fields = raw[closing + 2:].split()
            executable = os.readlink(f"/proc/{pid}/exe")
        except (OSError, UnicodeError) as exc:
            raise HostError("AUTHORITY_DENIED", "host process identity is unavailable", str(exc), 4) from exc
        fail(closing > 1 and len(fields) > 19, "AUTHORITY_DENIED", "host process identity is invalid", pid, 4)
        return {"pid": pid, "parentPid": int(fields[1]), "uid": os.stat(f"/proc/{pid}").st_uid,
                "startedAt": fields[19], "executable": executable}
    raise HostError("AUTHORITY_DENIED", "host process identity is unsupported on this platform", sys.platform, 4)


def session_principal() -> Mapping[str, Any]:
    principal = process_identity(os.getppid())
    return {"pid": principal["pid"], "uid": principal["uid"],
            "startedAt": principal["startedAt"], "executable": principal["executable"]}


def principal_is_current(expected: Any) -> bool:
    if not isinstance(expected, dict) or set(expected) != {"pid", "uid", "startedAt", "executable"}:
        return False
    pid = os.getppid()
    for _ in range(64):
        try:
            identity = process_identity(pid)
        except HostError:
            return False
        observed = {"pid": identity["pid"], "uid": identity["uid"],
                    "startedAt": identity["startedAt"], "executable": identity["executable"]}
        if observed == expected:
            return True
        parent = identity["parentPid"]
        if parent <= 1 or parent == pid:
            return False
        pid = parent
    return False


def require_initial_bind_peer(tool: str, runner_executable: str) -> None:
    """Require the initial claimant to descend from the vetted native runner."""
    expected = Path(runner_executable)
    pid = os.getppid()
    for _ in range(64):
        try:
            identity = process_identity(pid)
            observed = Path(str(identity["executable"]))
            if identity["uid"] == os.geteuid() and observed.exists() and os.path.samefile(observed, expected):
                return
        except (HostError, OSError):
            break
        parent = int(identity["parentPid"])
        if parent <= 1 or parent == pid:
            break
        pid = parent
    raise HostError("AUTHORITY_DENIED", f"initial {tool} binding requires the vetted native runner peer", exit_code=4)


def invocation_parts(token: str) -> Tuple[str, ...]:
    fail(isinstance(token, str) and re.fullmatch(r"[0-9a-f]{64}", token) is not None,
         "AUTHORITY_DENIED", "host invocation credential is invalid")
    return ("host", "invocations", hashlib.sha256(token.encode("ascii")).hexdigest() + ".json")


def create_invocation(record: Mapping[str, Any]) -> Tuple[str, Tuple[str, ...]]:
    token = os.urandom(32).hex()
    parts = invocation_parts(token)
    graph = graph_module()
    source, monotonic_ns = graph.host_monotonic_sample()
    value = {"schemaVersion": "operator.host-invocation/v1", "tool": record["tool"],
             "sessionId": record["sessionId"], "nodeId": record["nodeId"],
             "hostId": graph.HOST_ID, "bootId": graph.BOOT_ID, "monotonicSource": source,
             "expiresMonotonicNs": monotonic_ns + 24 * 60 * 60 * 1_000_000_000}
    with held_store() as store:
        store.atomic_write_json(parts, value, private=True)
    return token, parts


def remove_invocation(parts: Sequence[str]) -> None:
    with held_store() as store:
        parent = store._open_dir(parts[:-1], create=False, private=True)
        try:
            os.unlink(safe_component(parts[-1]), dir_fd=parent)
            os.fsync(parent)
        except FileNotFoundError:
            pass
        finally:
            os.close(parent)


def validate_invocation(token: str, record: Mapping[str, Any]) -> None:
    with held_store() as store:
        value = store.read_json(invocation_parts(token), "host invocation credential", 65536, private=True)
    exact(value, {"schemaVersion", "tool", "sessionId", "nodeId", "hostId", "bootId",
                  "monotonicSource", "expiresMonotonicNs"}, "host invocation credential")
    graph = graph_module()
    source, monotonic_ns = graph.host_monotonic_sample()
    fail(value.get("schemaVersion") == "operator.host-invocation/v1" and value.get("tool") == record["tool"]
         and value.get("sessionId") == record["sessionId"] and value.get("nodeId") == record["nodeId"]
         and value.get("hostId") == graph.HOST_ID and value.get("bootId") == graph.BOOT_ID
         and value.get("monotonicSource") == source and integer(value.get("expiresMonotonicNs"), 1)
         and monotonic_ns < value["expiresMonotonicNs"],
         "AUTHORITY_DENIED", "host invocation credential is stale or bound to another session")


def graph_module() -> Any:
    directory = str(script_dir())
    if directory not in sys.path:
        sys.path.insert(0, directory)
    import operator_graph  # type: ignore
    return operator_graph


def validated_actor(binding_id: str, retain: bool = True) -> Mapping[str, Any]:
    fail(BINDING_RE.fullmatch(binding_id) is not None, "AUTHORITY_DENIED", "actor binding ID is invalid")
    graph = graph_module()
    try:
        with held_store() as store:
            authority_value = store.read_json(("authority", "control-graph-public-key.json"),
                                              "authority trust anchor", 65536, private=True)
            binding_parts = ("graph", "bindings", f"{binding_id}.json")
            if retain:
                binding_value = store.read_json(binding_parts, "actor binding", 65536, private=True)
            else:
                binding_value = loads(store.read_manifest_bytes(binding_parts, 65536, "actor binding"),
                                      "actor binding", 65536)
        authority = graph.validate_authority(authority_value)
        binding = graph.validate_binding(binding_value, binding_id, authority)
        now = graph.utc_now()
        fail(graph.parse_time(binding["issuedAt"], "AUTHORITY_DENIED") <= now
             < graph.parse_time(binding["expiresAt"], "AUTHORITY_DENIED"),
             "AUTHORITY_DENIED", "actor binding is not currently valid")
        return binding
    except HostError:
        raise
    except Exception as exc:
        code = getattr(exc, "code", "AUTHORITY_DENIED")
        message = getattr(exc, "message", "actor binding validation failed")
        details = getattr(exc, "details", str(exc))
        raise HostError(code, message, details, 4) from exc


def graph_snapshot() -> Mapping[str, Any]:
    command = script_dir() / "operator-graph.sh"
    fail(command.is_file() and os.access(command, os.X_OK), "TRUSTED_INTERFACE_UNAVAILABLE",
         "operator graph runtime is unavailable", str(command), 3)
    root_environment, root_fds = host_root_environment()
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C",
           **root_environment}
    try:
        code, output, error = bounded_child([str(command), "snapshot"], b"", env,
                                            script_dir(), 30, MAX_JSON_BYTES,
                                            pass_fds=root_fds)
    except (OSError, subprocess.SubprocessError) as exc:
        raise HostError("TRUSTED_INTERFACE_UNAVAILABLE", "trusted snapshot endpoint is unavailable", str(exc), 3) from exc
    if code != 0:
        diagnostic = error[:4096].decode("utf-8", errors="replace")
        raise HostError("TRUSTED_INTERFACE_FAILED", "trusted snapshot endpoint failed", diagnostic, 4)
    envelope = exact(loads(output, "graph snapshot"), {"ok", "command", "data"}, "graph snapshot envelope")
    fail(envelope.get("ok") is True and envelope.get("command") in {"status", "snapshot"},
         "INTERFACE_PROTOCOL", "graph snapshot envelope is invalid")
    snapshot = envelope.get("data")
    fail(isinstance(snapshot, dict) and snapshot.get("schemaVersion") == "operator.control-snapshot/v1",
         "INTERFACE_PROTOCOL", "graph snapshot payload is invalid")
    return snapshot


def parse_lanes() -> Dict[str, Dict[str, str]]:
    result: Dict[str, Dict[str, str]] = {}
    policy = trusted_policy()
    code_dir = policy["codeDir"]
    for raw in policy["lanes"].splitlines():
        if not raw.strip():
            continue
        fields = raw.split("|", 4)
        if len(fields) < 4:
            continue
        lane, owner, worktree, branch, invocation = fields
        if lane and lane not in result:
            result[lane] = {
                "lane": lane, "owner": owner, "worktreeName": worktree, "branch": branch,
                "worktree": str((Path(code_dir) / worktree).resolve()) if code_dir and worktree else "",
                "invocation": invocation,
            }
    return result


def tool_matches(tool: str, binding: Mapping[str, Any], lane: Mapping[str, str]) -> bool:
    owner = lane.get("owner", "").lower()
    subject = binding.get("subject", {})
    runner = subject.get("hostRunnerId", "") if isinstance(subject, dict) else ""
    if tool == "codex":
        return "codex" in owner or (isinstance(runner, str) and runner.startswith("codex"))
    return "claude" in owner or runner == "claude-code"


def validate_lane_invocation(tool: str, lane: Mapping[str, str]) -> None:
    try:
        tokens = shlex.split(lane.get("invocation", ""))
    except ValueError as exc:
        raise HostError("TRUSTED_POLICY_UNAVAILABLE", "lane invocation is not valid shell syntax", str(exc), 3) from exc
    expected = "codex" if tool == "codex" else "claude"
    fail(tokens and Path(tokens[0]).name == expected and not FORBIDDEN_LAUNCH_TOKENS.intersection(tokens),
         "TRUSTED_POLICY_UNAVAILABLE", "assigned lane invocation violates trusted runner policy",
         lane.get("lane"), 3)
    if tool == "codex":
        fail("--sandbox" in tokens and tokens[tokens.index("--sandbox") + 1:tokens.index("--sandbox") + 2]
             == ["workspace-write"], "TRUSTED_POLICY_UNAVAILABLE",
             "Codex lane invocation must select the restricted workspace sandbox", lane.get("lane"), 3)
    else:
        fail("--permission-mode" in tokens
             and tokens[tokens.index("--permission-mode") + 1:tokens.index("--permission-mode") + 2] == ["dontAsk"],
             "TRUSTED_POLICY_UNAVAILABLE", "Claude lane invocation must fail closed on permission prompts",
             lane.get("lane"), 3)


def find_binding(tool: str, node_id: str, snapshot: Mapping[str, Any]) -> Tuple[Mapping[str, Any], str, str, Mapping[str, str]]:
    nodes = {node.get("id"): node for node in snapshot.get("nodes", []) if isinstance(node, dict)}
    fail(node_id in nodes, "AUTHORITY_DENIED", "requested scope is not a graph node", {"nodeId": node_id})
    assigned = sorted({edge.get("to") for edge in snapshot.get("edges", []) if isinstance(edge, dict)
                       and edge.get("kind") == "assigned-to" and edge.get("from") == node_id
                       and isinstance(edge.get("to"), str)})
    fail(len(assigned) == 1, "AUTHORITY_DENIED", "graph node must have exactly one assigned lane",
         {"nodeId": node_id, "assigned": assigned})
    lane_node = assigned[0]
    lanes = parse_lanes()
    lane = lanes.get(lane_node)
    fail(lane is not None, "AUTHORITY_DENIED", "assigned graph lane is absent from trusted lane configuration",
         {"laneNodeId": lane_node})
    validate_lane_invocation(tool, lane)
    candidates = []
    with held_store() as store:
        try:
            binding_names = store.listdir(("graph", "bindings"))
        except OSError:
            binding_names = []
    for name in binding_names:
            if not name.endswith(".json"):
                continue
            binding_id = name[:-5]
            if BINDING_RE.fullmatch(binding_id) is None:
                continue
            try:
                binding = validated_actor(binding_id, retain=False)
            except HostError:
                continue
            if binding.get("subject", {}).get("type") not in {"lane", "host"} or "lease" not in binding.get("capabilities", []):
                continue
            scopes = [scope for scope in binding.get("leaseScopes", [])
                      if isinstance(scope, dict) and scope.get("laneNodeId") == lane_node]
            if len(scopes) == 1 and tool_matches(tool, binding, lane):
                candidates.append((binding, scopes[0]["scope"]))
    fail(len(candidates) == 1, "AUTHORITY_DENIED", "trusted policy did not resolve exactly one actor binding",
         {"nodeId": node_id, "laneNodeId": lane_node, "candidateCount": len(candidates)})
    binding, holder_scope = candidates[0]
    # Pin and revalidate only the selected actor. Candidate discovery remains
    # manifest-bound and never accumulates one retained FD per binding.
    binding = validated_actor(binding["bindingId"], retain=True)
    return binding, holder_scope, lane_node, lane


def validate_worktree(lane: Mapping[str, str]) -> Tuple[str, str]:
    worktree = Path(lane.get("worktree", ""))
    branch = lane.get("branch", "")
    fail(worktree.is_absolute() and worktree.is_dir() and not worktree.is_symlink(), "AUTHORITY_DENIED",
         "assigned worktree is unavailable", str(worktree))
    try:
        completed = subprocess.run(["/usr/bin/git", "-C", str(worktree), "branch", "--show-current"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False, text=True)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise HostError("AUTHORITY_DENIED", "cannot verify assigned worktree branch", str(exc), 4) from exc
    actual = completed.stdout.strip()
    fail(completed.returncode == 0 and actual == branch, "AUTHORITY_DENIED",
         "assigned worktree branch does not match trusted lane policy", {"expected": branch, "actual": actual})
    return str(worktree.resolve()), branch


def resolve_runner_executable(tool: str) -> str:
    executable = shutil.which("codex" if tool == "codex" else "claude", path=trusted_path())
    fail(bool(executable), "RUNNER_UNAVAILABLE", f"{tool} runner executable is unavailable", exit_code=3)
    resolved = Path(str(executable)).resolve(strict=True)
    info = os.stat(resolved, follow_symlinks=False)
    fail(stat.S_ISREG(info.st_mode) and info.st_uid in {0, os.geteuid()}
         and stat.S_IMODE(info.st_mode) & 0o022 == 0 and os.access(resolved, os.X_OK),
         "RUNNER_UNAVAILABLE", "runner executable ownership or mode is unsafe", str(resolved), 3)
    return str(resolved)


def runner_preflight(tool: str, executable: str) -> None:
    arguments = [executable, "exec", "--help"] if tool == "codex" else [executable, "--help"]
    environment = {"PATH": SYSTEM_PATH, "HOME": pwd.getpwuid(os.geteuid()).pw_dir,
                   "LC_ALL": "C", "LANG": "C"}
    try:
        completed = subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, env=environment, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise HostError("RUNNER_UNAVAILABLE", f"{tool} native sandbox preflight failed", str(exc), 3) from exc
    fail(completed.returncode == 0 and len(completed.stdout) <= 256 * 1024,
         "RUNNER_UNAVAILABLE", f"{tool} native sandbox preflight failed", exit_code=3)
    help_text = completed.stdout.decode("utf-8", errors="replace")
    required = ("--sandbox", "workspace-write", "--add-dir", "--ignore-user-config",
                "--ignore-rules", "--ephemeral") if tool == "codex" else (
                    "--permission-mode", "dontAsk", "--safe-mode", "--settings",
                    "--disallowedTools", "--no-session-persistence")
    fail(all(token in help_text for token in required), "RUNNER_UNAVAILABLE",
         f"{tool} installation lacks the required native sandbox controls", exit_code=3)
    if tool == "claude":
        try:
            authenticated = subprocess.run([executable, "auth", "status", "--json"], stdin=subprocess.DEVNULL,
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=environment,
                                           timeout=10, check=False)
        except (OSError, subprocess.SubprocessError) as exc:
            raise HostError("RUNNER_UNAVAILABLE", "Claude host credential preflight failed", str(exc), 3) from exc
        try:
            auth_status = json.loads(authenticated.stdout.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            auth_status = None
        fail(authenticated.returncode == 0 and isinstance(auth_status, dict)
             and auth_status.get("loggedIn") is True, "RUNNER_UNAVAILABLE",
             "Claude host credentials are unavailable; native sandbox launch fails closed", exit_code=3)


def bind_session(tool: str, session: str, node_id: str) -> Mapping[str, Any]:
    fail(valid_id(node_id), "USAGE", "--scope must be a valid graph node ID", exit_code=2)
    snapshot = graph_snapshot()
    binding, holder_scope, lane_node, lane = find_binding(tool, node_id, snapshot)
    worktree, branch = validate_worktree(lane)
    runner_executable = resolve_runner_executable(tool)
    require_initial_bind_peer(tool, runner_executable)
    runner_preflight(tool, runner_executable)
    handoff_parts = ("host", "handoffs", lane_node, node_id)
    with held_store() as store:
        handoff = store.ensure_dir(handoff_parts, private=True)
    record = {
        "schemaVersion": HOST_BINDING_VERSION,
        "tool": tool,
        "sessionId": session,
        "nodeId": node_id,
        "graphId": snapshot["graphId"],
        "actorBindingId": binding["bindingId"],
        "actorBindingGeneration": binding["generation"],
        "actorBindingHash": binding["bindingHash"],
        "actorType": binding["subject"]["type"],
        "actorId": binding["subject"]["id"],
        "proofKeyId": binding["proofKey"]["keyId"],
        "holderScope": holder_scope,
        "laneNodeId": lane_node,
        "laneId": lane["lane"],
        "worktree": worktree,
        "branch": branch,
        "runnerExecutable": runner_executable,
        "handoffDir": str(handoff),
        "principal": session_principal(),
    }
    parts = session_parts(tool, session)
    with held_store() as store:
        exists = store.exists(parts)
    if exists:
        existing = load_session(tool, session)
        if dict(existing) == record:
            return record
        lease = snapshot.get("leases", {}).get(existing["nodeId"])
        fail(not isinstance(lease, dict) or lease.get("holder", {}).get("bindingId") != existing["actorBindingId"],
             "AUTHORITY_DENIED", "an active graph lease prevents session rebinding")
    with held_store() as store:
        store.atomic_write_json(parts, record, private=True)
    return record


def load_session(tool: str, session: str, scope: Optional[str] = None,
                 invocation: Optional[str] = None) -> Mapping[str, Any]:
    with held_store() as store:
        record = store.read_json(session_parts(tool, session), "host session binding", 65536, private=True)
    fields = {"schemaVersion", "tool", "sessionId", "nodeId", "graphId", "actorBindingId",
              "actorBindingGeneration", "actorBindingHash", "actorType", "actorId", "proofKeyId", "holderScope", "laneNodeId",
              "laneId", "worktree", "branch", "runnerExecutable", "handoffDir", "principal"}
    exact(record, fields, "host session binding")
    fail(record.get("schemaVersion") == HOST_BINDING_VERSION and record.get("tool") == tool
         and record.get("sessionId") == session, "AUTHORITY_DENIED", "host session binding identity mismatch")
    fail(scope is None or record.get("nodeId") == scope, "AUTHORITY_DENIED", "session is bound to a different graph scope",
         {"requestedScope": scope, "boundScope": record.get("nodeId")})
    if invocation is None:
        fail(principal_is_current(record.get("principal")), "AUTHORITY_DENIED",
             "invoking process is not the durable host-session principal")
    else:
        validate_invocation(invocation, record)
    binding = validated_actor(str(record.get("actorBindingId")))
    fail(binding.get("generation") == record.get("actorBindingGeneration")
         and binding.get("bindingHash") == record.get("actorBindingHash")
         and binding.get("subject", {}).get("type") == record.get("actorType")
         and binding.get("subject", {}).get("id") == record.get("actorId")
         and binding.get("proofKey", {}).get("keyId") == record.get("proofKeyId"),
         "AUTHORITY_DENIED", "durable session binding no longer matches the signed actor binding")
    scopes = [item for item in binding.get("leaseScopes", []) if isinstance(item, dict)
              and item.get("scope") == record.get("holderScope") and item.get("laneNodeId") == record.get("laneNodeId")]
    fail(len(scopes) == 1, "AUTHORITY_DENIED", "durable session lease scope is no longer authorized")
    expected_handoff = operator_dir().joinpath("host", "handoffs", record["laneNodeId"], record["nodeId"])
    fail(record.get("handoffDir") == str(expected_handoff), "AUTHORITY_DENIED",
         "durable session handoff path is not canonical")
    with held_store() as store:
        store.ensure_dir(("host", "handoffs", record["laneNodeId"], record["nodeId"]), private=True)
    fail(record.get("runnerExecutable") == resolve_runner_executable(tool), "AUTHORITY_DENIED",
         "durable session runner executable no longer matches trusted host resolution")
    return record


def scope_payload(record: Mapping[str, Any]) -> Mapping[str, Any]:
    return {
        "schemaVersion": HOST_SCOPE_VERSION,
        "tool": record["tool"], "sessionId": record["sessionId"], "scope": record["nodeId"],
        "graphId": record["graphId"], "actorBindingId": record["actorBindingId"],
        "actorBindingGeneration": record["actorBindingGeneration"], "proofKeyId": record["proofKeyId"],
        "actorType": record["actorType"], "actorId": record["actorId"],
        "holderScope": record["holderScope"], "laneNodeId": record["laneNodeId"],
        "laneId": record["laneId"], "worktree": record["worktree"], "branch": record["branch"],
        "runnerExecutable": record["runnerExecutable"], "handoffDir": record["handoffDir"],
    }


def response(command: str, data: Mapping[str, Any]) -> Mapping[str, Any]:
    return {"ok": True, "command": command, "data": dict(data)}


def broker_environment() -> Dict[str, str]:
    names = ("OPERATOR_HOST_TOOL", "OPERATOR_HOST_SESSION", "OPERATOR_HOST_SCOPE",
             "OPERATOR_HOST_INVOCATION")
    env = {"PATH": SYSTEM_PATH, "LC_ALL": "C", "LANG": "C"}
    for name in names:
        if name in os.environ:
            env[name] = os.environ[name]
    return env


def private_key_secret(binding: Mapping[str, Any], keychain_path: Optional[Path] = None) -> Tuple[int, int]:
    key_id = binding["proofKey"]["keyId"]
    if sys.platform == "darwin":
        command = ["/usr/bin/security", "find-generic-password", "-s", "agent-operator-kit.proof-key",
                   "-a", key_id, "-w"]
        if keychain_path is not None:
            command.append(str(keychain_path))
    else:
        secret_tool = shutil.which("secret-tool")
        fail(bool(secret_tool), "BROKER_UNAVAILABLE", "OS keychain client is unavailable", exit_code=3)
        command = [str(secret_tool), "lookup", "service", "agent-operator-kit.proof-key", "key-id", key_id]
    try:
        completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise HostError("BROKER_UNAVAILABLE", "OS keychain lookup failed", str(exc), 3) from exc
    fail(completed.returncode == 0 and completed.stdout.strip(), "BROKER_UNAVAILABLE",
         "proof key is unavailable in the OS keychain", exit_code=3)
    raw = completed.stdout.strip()
    try:
        secret = loads(raw, "keychain proof key", 32768)
    except HostError:
        try:
            decoded = base64.urlsafe_b64decode(raw + b"=" * (-len(raw) % 4))
            secret = loads(decoded, "keychain proof key", 32768)
        except Exception as exc:
            raise HostError("BROKER_UNAVAILABLE", "keychain proof key has an invalid envelope", str(exc), 3) from exc
    exact(secret, {"schemaVersion", "keyId", "n", "d"}, "keychain proof key")
    fail(secret.get("schemaVersion") == "operator.proof-key/v1" and secret.get("keyId") == key_id,
         "BROKER_UNAVAILABLE", "keychain proof key identity mismatch", exit_code=3)
    try:
        modulus = int(secret["n"], 16)
        private_exponent = int(secret["d"], 16)
    except (TypeError, ValueError) as exc:
        raise HostError("BROKER_UNAVAILABLE", "keychain proof key parameters are invalid", str(exc), 3) from exc
    fail(secret["n"] == binding["proofKey"]["publicKey"]["n"] and 1024 <= modulus.bit_length() <= 8192
         and 1 < private_exponent < modulus, "BROKER_UNAVAILABLE", "keychain proof key does not match binding", exit_code=3)
    return modulus, private_exponent


def sign_payload(payload: Mapping[str, Any], binding: Mapping[str, Any],
                 keychain_path: Optional[Path] = None) -> str:
    modulus, private_exponent = private_key_secret(binding, keychain_path)
    digest_info = bytes.fromhex("3031300d060960864801650304020105000420") + hashlib.sha256(canonical(payload)).digest()
    width = (modulus.bit_length() + 7) // 8
    fail(width >= len(digest_info) + 11, "BROKER_UNAVAILABLE", "proof key is too small", exit_code=3)
    encoded = b"\x00\x01" + b"\xff" * (width - len(digest_info) - 3) + b"\x00" + digest_info
    signature = pow(int.from_bytes(encoded, "big"), private_exponent, modulus).to_bytes(width, "big")
    return base64.urlsafe_b64encode(signature).decode("ascii").rstrip("=")


def read_socket_record(channel: socket.socket, maximum: int) -> Optional[Mapping[str, Any]]:
    data = bytearray()
    while not data.endswith(b"\n"):
        chunk = channel.recv(min(65536, maximum + 1 - len(data)))
        if not chunk:
            fail(not data, "AUTHORITY_DENIED", "proof broker received a partial record")
            return None
        data.extend(chunk)
        fail(len(data) <= maximum, "AUTHORITY_DENIED", "proof broker challenge is too large")
    fail(b"\n" not in data[:-1], "AUTHORITY_DENIED", "proof broker received multiple records in one phase")
    value = loads(bytes(data), "proof broker challenge", maximum)
    fail(isinstance(value, dict), "AUTHORITY_DENIED", "proof broker challenge is invalid")
    return value


def require_socket_write_eof(channel: socket.socket) -> None:
    """Require the client to irrevocably finish the one-shot request."""
    try:
        trailing = channel.recv(1)
    except socket.timeout as exc:
        raise HostError("AUTHORITY_DENIED", "event proof requires client write EOF before signing", exit_code=4) from exc
    fail(trailing == b"", "AUTHORITY_DENIED", "proof broker received a delayed third record")


def authorize_challenge(challenge: Mapping[str, Any], record: Mapping[str, Any], binding: Mapping[str, Any]) -> Mapping[str, Any]:
    exact(challenge, {"schemaVersion", "operation", "phase", "proofKeyId", "payload"}, "proof challenge")
    fail(challenge.get("schemaVersion") == PROOF_CHALLENGE_VERSION and challenge.get("operation") == "sign"
         and challenge.get("phase") == "authorize" and challenge.get("proofKeyId") == record["proofKeyId"],
         "AUTHORITY_DENIED", "authorize challenge does not match durable host policy")
    payload = exact(challenge.get("payload"), {"schemaVersion", "command", "requestId", "bindingId",
                    "bindingGeneration", "bindingHash", "intent", "expectedRevision"}, "authorization payload")
    graph = graph_module()
    try:
        graph.validate_authorization_payload(payload, "AUTHORITY_DENIED")
    except Exception as exc:
        raise HostError(getattr(exc, "code", "AUTHORITY_DENIED"),
                        getattr(exc, "message", "authorization schema is invalid"),
                        getattr(exc, "details", str(exc)), 4) from exc
    fail(payload.get("schemaVersion") == "operator.mutation-proof-request/v1"
         and payload.get("bindingId") == record["actorBindingId"]
         and payload.get("bindingGeneration") == record["actorBindingGeneration"]
         and payload.get("bindingHash") == record["actorBindingHash"],
         "AUTHORITY_DENIED", "authorization payload uses the wrong actor binding")
    command = payload.get("command")
    fail(command in {"lease acquire", "lease renew", "lease release", "transition"},
         "AUTHORITY_DENIED", "host runner cannot perform this graph mutation")
    intent = payload["intent"]
    fail(intent.get("nodeId") == record["nodeId"],
         "AUTHORITY_DENIED", "authorization payload crosses the bound graph scope")
    if command == "lease acquire":
        fail(intent.get("holderScope") == record["holderScope"], "AUTHORITY_DENIED",
             "lease acquisition uses the wrong holder scope")
    fail(valid_id(payload.get("requestId"), 256) and integer(payload.get("expectedRevision"), 1),
         "AUTHORITY_DENIED", "authorization request identity or revision is invalid")
    fail(binding["proofKey"]["keyId"] == record["proofKeyId"], "AUTHORITY_DENIED",
         "signed binding proof key changed")
    return payload


def event_challenge(challenge: Mapping[str, Any], record: Mapping[str, Any], binding: Mapping[str, Any],
                    authorization: Mapping[str, Any]) -> Mapping[str, Any]:
    exact(challenge, {"schemaVersion", "operation", "phase", "proofKeyId", "payload"}, "proof challenge")
    fail(challenge.get("schemaVersion") == PROOF_CHALLENGE_VERSION and challenge.get("operation") == "sign"
         and challenge.get("phase") == "event" and challenge.get("proofKeyId") == record["proofKeyId"],
         "AUTHORITY_DENIED", "event challenge does not match durable host policy")
    payload = exact(challenge.get("payload"), {"schemaVersion", "event"}, "event proof payload")
    fail(payload.get("schemaVersion") == "operator.mutation-event-proof/v1", "AUTHORITY_DENIED",
         "event proof payload has the wrong version")
    event = exact(payload.get("event"), {"schemaVersion", "sequence", "eventId", "requestId",
                  "requestFingerprint", "occurredAt", "clock", "actor", "type", "intent",
                  "expectedRevision", "data", "result"}, "unsigned control event")
    graph = graph_module()
    command_types = {"lease acquire": "lease.acquired", "lease renew": "lease.renewed",
                     "lease release": "lease.released", "transition": "node.transitioned"}
    fail(event.get("schemaVersion") == "operator.control-event/v1"
         and event.get("type") == command_types[authorization["command"]]
         and event.get("requestId") == authorization["requestId"]
         and event.get("intent") == authorization["intent"]
         and event.get("expectedRevision") == authorization["expectedRevision"]
         and event.get("sequence") == authorization["expectedRevision"] + 1
         and valid_id(event.get("eventId"), 128),
         "AUTHORITY_DENIED", "event proof does not match the authorized mutation")
    actor = event.get("actor")
    try:
        graph.validate_actor_record(actor, "AUTHORITY_DENIED")
        expected_actor = graph.actor_record(binding)
        occurred = graph.parse_time(event.get("occurredAt"), "AUTHORITY_DENIED")
        issued = graph.parse_time(binding["issuedAt"], "AUTHORITY_DENIED")
        expires = graph.parse_time(binding["expiresAt"], "AUTHORITY_DENIED")
    except Exception as exc:
        raise HostError(getattr(exc, "code", "AUTHORITY_DENIED"),
                        getattr(exc, "message", "unsigned event schema is invalid"),
                        getattr(exc, "details", str(exc)), 4) from exc
    fail(actor == expected_actor and issued <= occurred < expires,
         "AUTHORITY_DENIED", "event proof actor does not match the signed durable binding")
    fail(event.get("requestFingerprint") == graph.sha256_value(authorization),
         "AUTHORITY_DENIED", "event request fingerprint is not canonical")
    clock = exact(event.get("clock"), {"hostId", "bootId", "monotonicSource", "monotonicNs"}, "event clock")
    source, current_ns = graph.host_monotonic_sample()
    fail(clock.get("hostId") == graph.HOST_ID and clock.get("bootId") == graph.BOOT_ID
         and clock.get("monotonicSource") == source and integer(clock.get("monotonicNs"), 0)
         and clock["monotonicNs"] <= current_ns,
         "AUTHORITY_DENIED", "event clock does not use the current trusted monotonic epoch")
    fail(isinstance(event.get("data"), dict), "AUTHORITY_DENIED", "event data is invalid")
    result = exact(event.get("result"), {"ok", "command", "requestId", "revision", "data"}, "event result")
    fail(result.get("ok") is True and result.get("command") == authorization["command"]
         and result.get("requestId") == authorization["requestId"]
         and result.get("revision") == event["sequence"] and isinstance(result.get("data"), dict),
         "AUTHORITY_DENIED", "event result is not bound to the authorized mutation")
    if authorization["command"] == "lease acquire":
        fail(set(event["data"]) == {"lease"} and set(result["data"]) == {"lease", "reclaimed"}
             and result["data"]["lease"] == event["data"]["lease"]
             and isinstance(result["data"]["reclaimed"], bool),
             "AUTHORITY_DENIED", "lease acquisition event result is invalid")
        try:
            graph.validate_lease(event["data"]["lease"], "AUTHORITY_DENIED")
        except Exception as exc:
            raise HostError(getattr(exc, "code", "AUTHORITY_DENIED"),
                            getattr(exc, "message", "lease acquisition data is invalid"),
                            getattr(exc, "details", str(exc)), 4) from exc
        lease = event["data"]["lease"]
        lease_expires = graph.parse_time(lease.get("expiresAt"), "AUTHORITY_DENIED")
        expected_holder = {"actorType": record["actorType"], "actorId": record["actorId"],
                           "bindingId": record["actorBindingId"],
                           "bindingGeneration": record["actorBindingGeneration"],
                           "bindingHash": record["actorBindingHash"], "scope": record["holderScope"],
                           "laneNodeId": record["laneNodeId"]}
        lease_clock = lease["clock"]
        fail(lease.get("nodeId") == record["nodeId"]
             and lease.get("leaseId") == authorization["intent"].get("leaseId")
             and lease.get("holder") == expected_holder
             and lease.get("acquiredAt") == event.get("occurredAt")
             and lease.get("renewedAt") == event.get("occurredAt")
             and lease_expires == occurred + dt.timedelta(seconds=authorization["intent"].get("ttlSeconds"))
             and lease_clock.get("hostId") == graph.HOST_ID and lease_clock.get("bootId") == graph.BOOT_ID
             and lease_clock.get("monotonicSource") == source
             and lease_clock.get("acquiredMonotonicNs") == clock.get("monotonicNs")
             and lease_clock.get("expiresMonotonicNs") == clock.get("monotonicNs")
                 + authorization["intent"].get("ttlSeconds") * 1_000_000_000,
             "AUTHORITY_DENIED", "lease acquisition data crosses durable host scope")
    elif authorization["command"] == "lease renew":
        fail(set(event["data"]) == {"lease"} and result["data"] == event["data"],
             "AUTHORITY_DENIED", "lease renewal data is invalid")
        try:
            graph.validate_lease(event["data"]["lease"], "AUTHORITY_DENIED")
        except Exception as exc:
            raise HostError(getattr(exc, "code", "AUTHORITY_DENIED"),
                            getattr(exc, "message", "lease renewal data is invalid"),
                            getattr(exc, "details", str(exc)), 4) from exc
        lease = event["data"]["lease"]
        lease_expires = graph.parse_time(lease.get("expiresAt"), "AUTHORITY_DENIED")
        expected_holder = {"actorType": record["actorType"], "actorId": record["actorId"],
                           "bindingId": record["actorBindingId"],
                           "bindingGeneration": record["actorBindingGeneration"],
                           "bindingHash": record["actorBindingHash"], "scope": record["holderScope"],
                           "laneNodeId": record["laneNodeId"]}
        lease_clock = lease["clock"]
        fail(lease.get("nodeId") == record["nodeId"]
             and lease.get("leaseId") == authorization["intent"].get("leaseId")
             and lease.get("fence") == authorization["intent"].get("fence"),
             "AUTHORITY_DENIED", "lease renewal data crosses authorized lease identity")
        fail(lease.get("holder") == expected_holder and lease.get("renewedAt") == event.get("occurredAt")
             and lease_expires == occurred + dt.timedelta(seconds=authorization["intent"].get("ttlSeconds"))
             and lease_clock.get("hostId") == graph.HOST_ID and lease_clock.get("bootId") == graph.BOOT_ID
             and lease_clock.get("monotonicSource") == source
             and lease_clock.get("acquiredMonotonicNs") <= clock.get("monotonicNs")
             and lease_clock.get("expiresMonotonicNs") == clock.get("monotonicNs")
                 + authorization["intent"].get("ttlSeconds") * 1_000_000_000,
             "AUTHORITY_DENIED", "lease renewal holder or clock diverges from durable host session")
    elif authorization["command"] == "lease release":
        fail(set(event["data"]) == {"nodeId", "leaseId", "fence"}
             and event["data"] == authorization["intent"] and result["data"] == event["data"],
             "AUTHORITY_DENIED", "lease release data is not exact")
    elif authorization["command"] == "transition":
        fail(set(event["data"]) == {"nodeId", "from", "to"}
             and event["data"].get("nodeId") == authorization["intent"].get("nodeId")
             and event["data"].get("to") == authorization["intent"].get("targetState")
             and isinstance(event["data"].get("from"), str) and result["data"] == event["data"],
             "AUTHORITY_DENIED", "transition event data is not exact")
    else:
        fail(result["data"] == event["data"], "AUTHORITY_DENIED",
             "event result data does not match committed event data")
    return payload


def serve_broker(channel: socket.socket, record: Mapping[str, Any], binding: Mapping[str, Any],
                 signer: Callable[[Mapping[str, Any], Mapping[str, Any]], str]) -> int:
    channel.settimeout(10)
    try:
        first = read_socket_record(channel, 64 * 1024)
        fail(first is not None, "AUTHORITY_DENIED", "proof broker closed before authorize")
        authorization = authorize_challenge(first, record, binding)
        signature = signer(authorization, binding)
        channel.sendall(canonical({"schemaVersion": PROOF_RESPONSE_VERSION, "phase": "authorize",
                                   "proofKeyId": record["proofKeyId"], "signature": signature}))
        second = read_socket_record(channel, MAX_JSON_BYTES + 64 * 1024)
        if second is None:
            return 0
        event_payload = event_challenge(second, record, binding, authorization)
        require_socket_write_eof(channel)
        event_signature = signer(event_payload, binding)
        channel.sendall(canonical({"schemaVersion": PROOF_RESPONSE_VERSION, "phase": "event",
                                   "proofKeyId": record["proofKeyId"], "signature": event_signature}))
        channel.shutdown(socket.SHUT_WR)
        return 0
    finally:
        channel.close()


def broker_main(check_only: bool = False) -> int:
    tool = os.environ.get("OPERATOR_HOST_TOOL", "")
    session = os.environ.get("OPERATOR_HOST_SESSION", "")
    scope = os.environ.get("OPERATOR_HOST_SCOPE")
    record = load_session(tool, session, scope, os.environ.get("OPERATOR_HOST_INVOCATION"))
    binding = validated_actor(record["actorBindingId"])
    if check_only:
        private_key_secret(binding)
        return 0
    raw_fd = os.environ.get("OPERATOR_HOST_BROKER_FD", "")
    fail(raw_fd.isdigit() and 3 <= int(raw_fd) <= 1024, "BROKER_UNAVAILABLE",
         "proof broker socket is unavailable", exit_code=3)
    return serve_broker(socket.socket(fileno=os.dup(int(raw_fd))), record, binding, sign_payload)


def validate_design_request(value: Any) -> Mapping[str, Any]:
    request = exact(value, {"schemaVersion", "command", "requestId", "graphId", "expectedRevision",
                            "cliIntent", "definition", "gateNodeId", "decision"},
                    "design mutation request")
    fail(request.get("schemaVersion") == "operator.design-flow-graph-mutation-request/v1"
         and request.get("command") in {"replace-definition", "gate decide"}
         and valid_id(request.get("requestId"), 256) and valid_id(request.get("graphId"), 128)
         and integer(request.get("expectedRevision"), 1),
         "INTERFACE_PROTOCOL", "design mutation request identity is invalid")
    intent = request.get("cliIntent")
    fail(isinstance(intent, dict), "INTERFACE_PROTOCOL", "design CLI intent is invalid")
    action = intent.get("action")
    expected_intent_fields = {
        "start": {"action", "featureId", "flowId"},
        "select": {"action", "featureId", "flowId", "proposal"},
        "reject": {"action", "featureId", "flowId"},
        "improve": {"action", "featureId", "flowId", "feedbackRequestId"},
    }
    fail(action in expected_intent_fields and set(intent) == expected_intent_fields[action]
         and valid_id(intent.get("featureId"), 128) and valid_id(intent.get("flowId"), 48),
         "INTERFACE_PROTOCOL", "design CLI intent fields are invalid")
    feature_id = intent["featureId"]
    flow_id = intent["flowId"]
    if action == "select":
        fail(intent.get("proposal") in {"proposal-a", "proposal-b", "proposal-c"},
             "INTERFACE_PROTOCOL", "design selection intent is invalid")
    if action == "improve":
        fail(valid_id(intent.get("feedbackRequestId"), 128), "INTERFACE_PROTOCOL",
             "design improvement intent is invalid")
    expected_request_ids = {
        "start": f"design-start-{feature_id}-{flow_id}",
        "reject": f"design-reject-gate-{feature_id}-{flow_id}",
        "improve": f"design-improvement-{intent.get('feedbackRequestId', '')}",
    }
    if action == "select":
        suffix = f"{feature_id}-{flow_id}-{intent['proposal']}"
        expected_request_ids["select"] = f"design-{'select-node' if request['command'] == 'replace-definition' else 'select-gate'}-{suffix}"
    fail(request["requestId"] == expected_request_ids[action], "AUTHORITY_DENIED",
         "design mutation request is not bound to the explicit CLI intent")
    graph = graph_module()
    if request["command"] == "replace-definition":
        fail(action in {"start", "select", "improve"} and request.get("gateNodeId") is None
             and request.get("decision") is None and isinstance(request.get("definition"), dict),
             "AUTHORITY_DENIED", "design definition replacement crosses CLI policy")
        try:
            definition = graph.validate_definition(request["definition"], materialized=False)
        except Exception as exc:
            raise HostError(getattr(exc, "code", "INVALID_GRAPH"),
                            getattr(exc, "message", "design definition is invalid"),
                            getattr(exc, "details", str(exc)), 4) from exc
        fail(definition == request["definition"] and definition["graphId"] == request["graphId"],
             "AUTHORITY_DENIED", "design definition is not exact or crosses graph identity")
    else:
        fail(action in {"select", "reject"} and request.get("definition") is None
             and valid_id(request.get("gateNodeId"), 128)
             and request.get("decision") == ("approved" if action == "select" else "rejected"),
             "AUTHORITY_DENIED", "human gate decision is not bound to explicit select/reject CLI intent")
        readable = re.sub(r"[^A-Za-z0-9._-]+", "-", f"{feature_id}-{flow_id}").strip("-")[:48] or "flow"
        digest = hashlib.sha256((feature_id + "\x00" + flow_id).encode("utf-8")).hexdigest()[:16]
        fail(request["gateNodeId"] == f"design-flow-{readable}-{digest}-selection-gate",
             "AUTHORITY_DENIED", "human gate ID does not match the explicit design-flow intent")
    return request


def descriptor_store(root_fd: int, root_path: Optional[Path] = None) -> AnchoredStore:
    if _ACTIVE_HOST_ROOT is not None:
        supplied = os.fstat(root_fd)
        if (supplied.st_dev, supplied.st_ino) == _ACTIVE_HOST_ROOT.root_identity:
            _ACTIVE_HOST_ROOT.verify_path()
            return AnchoredStore.from_descriptor(
                root_fd, _ACTIVE_HOST_ROOT.root_path,
                _ACTIVE_HOST_ROOT.directory_identities, _ACTIVE_HOST_ROOT.directory_fds,
                _ACTIVE_HOST_ROOT.directory_inventories,
                _ACTIVE_HOST_ROOT.file_identities, _ACTIVE_HOST_ROOT.file_fds,
                _ACTIVE_HOST_ROOT.file_manifest)
    if ("OPERATOR_DESIGN_FLOW_ROOT_FD" in os.environ
            or "OPERATOR_HOST_ROOT_FD" in os.environ):
        store = command_root()
        supplied = os.fstat(root_fd)
        fail((supplied.st_dev, supplied.st_ino) == store.root_identity, "IO_ERROR",
             "descriptor store root differs from inherited capability", exit_code=3)
        return store
    if root_path is None:
        raw = (os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_PATH")
               or os.environ.get("OPERATOR_HOST_ROOT_PATH"))
        fail(bool(raw) and os.path.isabs(str(raw)), "IO_ERROR",
             "descriptor store is missing its trusted root locator", exit_code=3)
        root_path = Path(os.path.abspath(str(raw)))
    return AnchoredStore.from_descriptor(root_fd, root_path)


def design_edge(kind: str, source: str, target: str, metadata: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    return {"id": f"{kind}:{source}:{target}", "kind": kind, "from": source, "to": target,
            "metadata": dict(metadata or {})}


def design_node_metadata(feature_id: str, flow_id: str, role: str, artifact: str,
                         details: Mapping[str, Any], proposal: Optional[str] = None,
                         reclaimable: bool = True) -> Dict[str, Any]:
    design: Dict[str, Any] = {"featureId": feature_id, "flowId": flow_id,
                              "role": role, "artifactPath": artifact, **dict(details)}
    if proposal is not None:
        design["proposal"] = proposal
    return {"designFlow": design,
            "execution": {"idempotent": reclaimable, "reclaimable": reclaimable},
            "scheduler": {"claims": {"contracts": ["design-flow"], "files": [], "resources": []}}}


def design_flow_prefix(feature_id: str, flow_id: str) -> str:
    readable = re.sub(r"[^A-Za-z0-9._-]+", "-", f"{feature_id}-{flow_id}").strip("-")[:48] or "flow"
    digest = hashlib.sha256((feature_id + "\x00" + flow_id).encode("utf-8")).hexdigest()[:16]
    return f"design-flow-{readable}-{digest}"


def design_feature_parts(store: AnchoredStore, feature_id: str) -> Tuple[str, ...]:
    matches = []
    for name in store.listdir(("features",)):
        if name in {"", ".", ".."} or "/" in name:
            continue
        try:
            status_value = loads(store.read_bytes(("features", name, "status.json"), 1024 * 1024,
                                                  private=False), "feature status")
            if isinstance(status_value, dict) and status_value.get("id") == feature_id:
                matches.append(("features", name))
        except (HostError, OSError):
            continue
    fail(len(matches) == 1, "AUTHORITY_DENIED", "design feature workspace is missing or ambiguous", feature_id)
    return matches[0]


def design_flow_nodes(definition: Mapping[str, Any], feature_id: str, flow_id: str) -> list[Mapping[str, Any]]:
    return [node for node in definition["nodes"]
            if node.get("metadata", {}).get("designFlow", {}).get("featureId") == feature_id
            and node.get("metadata", {}).get("designFlow", {}).get("flowId") == flow_id]


def validate_existing_start_flow(current: Mapping[str, Any], projection: Mapping[str, Any],
                                 feature_id: str, flow_id: str) -> Tuple[Mapping[str, Any], list[Dict[str, Any]]]:
    prefix = design_flow_prefix(feature_id, flow_id)
    proposals = ("proposal-a", "proposal-b", "proposal-c")
    scoped = design_flow_nodes(current, feature_id, flow_id)
    fail(len(scoped) >= 4, "AUTHORITY_DENIED", "canonical design-flow start topology is missing")
    proposal_a = next((node for node in scoped if node["id"] == f"{prefix}-proposal-a"), None)
    fail(isinstance(proposal_a, dict), "AUTHORITY_DENIED", "canonical proposal topology is missing")
    first = proposal_a["metadata"]["designFlow"]
    fields = {"featureNodeId", "proposalLaneNodeId", "flowTitle", "proposalPriority",
              "briefHash", "briefArtifact"}
    fail(fields <= set(first), "AUTHORITY_DENIED", "canonical start intent metadata is incomplete")
    details = {key: first[key] for key in fields}
    expected_nodes = []
    expected_edges = []
    for proposal in proposals:
        node_id = f"{prefix}-{proposal}"
        expected_nodes.append({"id": node_id, "kind": "task", "title": f"{details['flowTitle']}: {proposal}",
            "initialState": "pending", "priority": details["proposalPriority"],
            "metadata": design_node_metadata(feature_id, flow_id, "proposal",
                                              f"work/design-options/{proposal}", details, proposal)})
        expected_edges.extend((design_edge("contains", details["featureNodeId"], node_id),
                               design_edge("assigned-to", node_id, details["proposalLaneNodeId"])))
    gate_id = f"{prefix}-selection-gate"
    expected_nodes.append({"id": gate_id, "kind": "human-gate", "title": f"Select {details['flowTitle']}",
        "initialState": "pending", "priority": details["proposalPriority"],
        "metadata": design_node_metadata(feature_id, flow_id, "selection-gate", "work/design-options",
                                          {**details, "options": list(proposals)}, reclaimable=False)})
    expected_edges.append(design_edge("contains", details["featureNodeId"], gate_id))
    start_nodes = [node for node in scoped if node["id"] in {item["id"] for item in expected_nodes}]
    flow_ids = {item["id"] for item in expected_nodes}
    implementation_id = f"{prefix}-implementation"
    start_edges = [edge for edge in current["edges"]
                   if (edge["from"] in flow_ids or edge["to"] in flow_ids)
                   and not (edge["from"] == implementation_id and edge["kind"] in {"depends-on", "gated-by"})]
    fail(start_nodes == sorted(expected_nodes, key=lambda item: item["id"])
         and start_edges == sorted(expected_edges, key=lambda item: item["id"]),
         "AUTHORITY_DENIED", "preexisting design-flow start topology is not canonical")
    fail(all(projection["nodeStates"].get(f"{prefix}-{proposal}") == "completed" for proposal in proposals),
         "AUTHORITY_DENIED", "all canonical proposals must be complete before selection")
    return details, expected_edges


def validate_existing_implementation(current: Mapping[str, Any], feature_id: str,
                                     flow_id: str) -> Mapping[str, Any]:
    prefix = design_flow_prefix(feature_id, flow_id)
    node_id = f"{prefix}-implementation"
    node = next((item for item in current["nodes"] if item["id"] == node_id), None)
    fail(isinstance(node, dict), "AUTHORITY_DENIED", "canonical design implementation is missing")
    design = node.get("metadata", {}).get("designFlow", {})
    fields = {"featureNodeId", "implementationLaneNodeId", "implementationPriority",
              "selectedProposal", "selectionGate"}
    fail(isinstance(design, dict) and fields <= set(design)
         and design.get("selectedProposal") in {"proposal-a", "proposal-b", "proposal-c"},
         "AUTHORITY_DENIED", "canonical implementation metadata is invalid")
    details = {key: design[key] for key in fields}
    expected = {"id": node_id, "kind": "task", "title": f"Implement {details['selectedProposal']}",
        "initialState": "pending", "priority": details["implementationPriority"],
        "metadata": design_node_metadata(feature_id, flow_id, "implementation",
                                          f"work/design-options/{details['selectedProposal']}",
                                          details, reclaimable=False)}
    expected_edges = [design_edge("contains", details["featureNodeId"], node_id),
                      design_edge("assigned-to", node_id, details["implementationLaneNodeId"])]
    expected_edges.extend(design_edge("depends-on", node_id, f"{prefix}-{proposal}")
                          for proposal in ("proposal-a", "proposal-b", "proposal-c"))
    expected_edges.append(design_edge("gated-by", node_id, details["selectionGate"],
                                      {"protectedTransitions": ["active", "completed"]}))
    touching = [edge for edge in current["edges"] if edge["from"] == node_id or edge["to"] == node_id]
    required_ids = [edge["id"] for edge in expected_edges]
    required_actual = [edge for edge in touching if edge["id"] in set(required_ids)]
    later = [edge for edge in touching if edge["id"] not in set(required_ids)]
    fail(node == expected and required_actual == sorted(expected_edges, key=lambda item: item["id"])
         and all(edge["to"] == node_id and edge["kind"] in {"depends-on", "feedback-for"}
                 and edge["from"].startswith(f"{prefix}-improvement-") for edge in later),
         "AUTHORITY_DENIED", "preexisting design implementation topology is not canonical")
    return details


def validate_design_delta(store: AnchoredStore, request: Mapping[str, Any], graph: Any,
                          authority: Mapping[str, Any]) -> None:
    raw_definition = store.read_bytes(("graph", "definition.json"), MAX_JSON_BYTES, private=False)
    raw_projection = store.read_bytes(("graph", "projection.json"), MAX_JSON_BYTES, private=False)
    current = graph.validate_definition(loads(raw_definition, "current graph definition"), materialized=True)
    projection = loads(raw_projection, "current graph projection")
    graph.validate_projection(projection, current)
    raw_events = store.read_bytes(("graph", "events.jsonl"), graph.MAX_JOURNAL_BYTES, private=False)
    event_lines = raw_events.splitlines(keepends=True)
    fail(bool(event_lines) and all(line.endswith(b"\n") for line in event_lines), "AUTHORITY_DENIED",
         "design mutation requires a complete graph journal")
    events = [loads(line, "control event") for line in event_lines]
    replayed_definition, replayed_projection = graph.replay(events, authority)
    fail(raw_definition == graph.canonical_bytes(current)
         and raw_projection == graph.canonical_bytes(projection), "AUTHORITY_DENIED",
         "design mutation requires canonical materialized graph state")
    fail(replayed_definition == current and replayed_projection == projection,
         "AUTHORITY_DENIED", "design mutation requires replay-consistent graph state")
    fail(current["graphId"] == request["graphId"]
         and projection["revision"] == request["expectedRevision"], "REVISION_CONFLICT",
         "design mutation policy snapshot is stale")
    intent = request["cliIntent"]
    action = intent["action"]
    feature_id = intent["featureId"]
    flow_id = intent["flowId"]
    prefix = design_flow_prefix(feature_id, flow_id)
    old_nodes = {node["id"]: node for node in current["nodes"]}
    fail(len(old_nodes) == len(current["nodes"]), "AUTHORITY_DENIED", "current graph node identity is ambiguous")
    if request["command"] == "gate decide":
        validate_existing_start_flow(current, projection, feature_id, flow_id)
        gate_id = f"{prefix}-selection-gate"
        fail(len(design_flow_nodes(current, feature_id, flow_id)) == 4
             and request["gateNodeId"] == gate_id
             and gate_id in old_nodes and old_nodes[gate_id]["kind"] == "human-gate"
             and projection["nodeStates"].get(gate_id) == "pending"
             and f"{prefix}-implementation" not in old_nodes,
             "AUTHORITY_DENIED", "design gate decision requires a complete canonical undecided flow with no implementation")
        return
    replacement = request["definition"]
    current_nodes_by_id = {node["id"]: node for node in current["nodes"]}
    current_edges_by_id = {edge["id"]: edge for edge in current["edges"]}
    replacement_nodes_by_id = {node["id"]: node for node in replacement["nodes"]}
    replacement_edges_by_id = {edge["id"]: edge for edge in replacement["edges"]}
    fail(replacement["graphId"] == current["graphId"]
         and all(replacement_nodes_by_id.get(node_id) == node for node_id, node in current_nodes_by_id.items())
         and all(replacement_edges_by_id.get(edge_id) == edge for edge_id, edge in current_edges_by_id.items()),
         "AUTHORITY_DENIED", "design mutation changed preexisting graph definition bytes")
    added_nodes = [node for node in replacement["nodes"] if node["id"] not in current_nodes_by_id]
    added_edges = [edge for edge in replacement["edges"] if edge["id"] not in current_edges_by_id]
    if action == "start":
        fail(not design_flow_nodes(current, feature_id, flow_id)
             and not any(node["id"].startswith(prefix + "-") for node in current["nodes"]),
             "AUTHORITY_DENIED", "design start cannot overlap an existing flow identity")
        fail(len(added_nodes) == 4, "AUTHORITY_DENIED", "design start must add exactly three proposals and one gate")
        first_design = added_nodes[0].get("metadata", {}).get("designFlow", {})
        start_fields = {"featureNodeId", "proposalLaneNodeId", "flowTitle", "proposalPriority",
                        "briefHash", "briefArtifact"}
        fail(isinstance(first_design, dict) and start_fields <= set(first_design),
             "AUTHORITY_DENIED", "design start metadata is incomplete")
        details = {key: first_design[key] for key in start_fields}
        fail(details["featureNodeId"] in old_nodes and old_nodes[details["featureNodeId"]]["kind"] == "feature"
             and details["proposalLaneNodeId"] in old_nodes and old_nodes[details["proposalLaneNodeId"]]["kind"] == "lane"
             and isinstance(details["flowTitle"], str) and bool(details["flowTitle"])
             and integer(details["proposalPriority"], 0)
             and isinstance(details["briefHash"], str) and HASH_RE.fullmatch(details["briefHash"]) is not None
             and details["briefArtifact"] == "work/design-options/brief.md",
             "AUTHORITY_DENIED", "design start context is not anchored to existing feature/lane nodes")
        fail(old_nodes[details["featureNodeId"]].get("metadata", {}).get("featureSessionId") in {None, feature_id},
             "AUTHORITY_DENIED", "design start feature node belongs to another feature session")
        feature_parts = design_feature_parts(store, feature_id)
        brief = store.read_bytes((*feature_parts, "work", "design-options", "brief.md"),
                                 1024 * 1024, private=False)
        fail("sha256:" + hashlib.sha256(brief).hexdigest() == details["briefHash"],
             "AUTHORITY_DENIED", "design start brief hash does not bind the held feature artifact")
        proposals = ("proposal-a", "proposal-b", "proposal-c")
        expected_nodes = []
        expected_edges = []
        for proposal in proposals:
            node_id = f"{prefix}-{proposal}"
            expected_nodes.append({"id": node_id, "kind": "task",
                "title": f"{details['flowTitle']}: {proposal}", "initialState": "pending",
                "priority": details["proposalPriority"],
                "metadata": design_node_metadata(feature_id, flow_id, "proposal",
                                                  f"work/design-options/{proposal}", details, proposal)})
            expected_edges.extend((design_edge("contains", details["featureNodeId"], node_id),
                                   design_edge("assigned-to", node_id, details["proposalLaneNodeId"])))
        gate_id = f"{prefix}-selection-gate"
        gate_details = {**details, "options": list(proposals)}
        expected_nodes.append({"id": gate_id, "kind": "human-gate", "title": f"Select {details['flowTitle']}",
            "initialState": "pending", "priority": details["proposalPriority"],
            "metadata": design_node_metadata(feature_id, flow_id, "selection-gate",
                                              "work/design-options", gate_details, reclaimable=False)})
        expected_edges.append(design_edge("contains", details["featureNodeId"], gate_id))
    elif action == "select":
        validate_existing_start_flow(current, projection, feature_id, flow_id)
        fail(len(added_nodes) == 1, "AUTHORITY_DENIED", "design select must add exactly one implementation node")
        design = added_nodes[0].get("metadata", {}).get("designFlow", {})
        fields = {"featureNodeId", "implementationLaneNodeId", "implementationPriority",
                  "selectedProposal", "selectionGate"}
        fail(isinstance(design, dict) and fields <= set(design), "AUTHORITY_DENIED",
             "design selection metadata is incomplete")
        details = {key: design[key] for key in fields}
        proposal = intent["proposal"]
        gate_id = f"{prefix}-selection-gate"
        fail(details["selectedProposal"] == proposal and details["selectionGate"] == gate_id
             and gate_id in old_nodes and old_nodes[gate_id]["kind"] == "human-gate"
             and details["featureNodeId"] in old_nodes and old_nodes[details["featureNodeId"]]["kind"] == "feature"
             and details["implementationLaneNodeId"] in old_nodes
             and old_nodes[details["implementationLaneNodeId"]]["kind"] == "lane"
             and integer(details["implementationPriority"], 0),
             "AUTHORITY_DENIED", "design selection context is invalid")
        fail(projection["nodeStates"].get(gate_id) == "approved"
             and len([event for event in events
                      if event.get("type") == "gate.decided"
                      and event.get("requestId") == f"design-select-gate-{feature_id}-{flow_id}-{proposal}"
                      and event.get("intent") == {"nodeId": gate_id, "decision": "approved"}
                      and event.get("data") == {"nodeId": gate_id, "from": "pending", "to": "approved"}]) == 1,
             "AUTHORITY_DENIED", "implementation append is not backed by the same explicit human selection")
        node_id = f"{prefix}-implementation"
        expected_nodes = [{"id": node_id, "kind": "task", "title": f"Implement {proposal}",
            "initialState": "pending", "priority": details["implementationPriority"],
            "metadata": design_node_metadata(feature_id, flow_id, "implementation",
                                              f"work/design-options/{proposal}", details, reclaimable=False)}]
        expected_edges = [design_edge("contains", details["featureNodeId"], node_id),
                          design_edge("assigned-to", node_id, details["implementationLaneNodeId"])]
        expected_edges.extend(design_edge("depends-on", node_id, f"{prefix}-{item}")
                              for item in ("proposal-a", "proposal-b", "proposal-c"))
        expected_edges.append(design_edge("gated-by", node_id, gate_id,
                                          {"protectedTransitions": ["active", "completed"]}))
    elif action == "improve":
        validate_existing_start_flow(current, projection, feature_id, flow_id)
        validate_existing_implementation(current, feature_id, flow_id)
        fail(len(added_nodes) == 1, "AUTHORITY_DENIED", "design improve must add exactly one feedback node")
        design = added_nodes[0].get("metadata", {}).get("designFlow", {})
        fields = {"featureNodeId", "improvementLaneNodeId", "improvementPriority", "sequence",
                  "requestId", "feedbackId", "messageHash", "evidenceHash", "sourceNodeId"}
        fail(isinstance(design, dict) and fields <= set(design), "AUTHORITY_DENIED",
             "design improvement metadata is incomplete")
        details = {key: design[key] for key in fields}
        request_id = intent["feedbackRequestId"]
        token = hashlib.sha256(request_id.encode("utf-8")).hexdigest()[:12]
        implementation_id = f"{prefix}-implementation"
        prior = []
        for node in current["nodes"]:
            item = node.get("metadata", {}).get("designFlow", {})
            if isinstance(item, dict) and item.get("featureId") == feature_id and item.get("flowId") == flow_id \
                    and item.get("role") == "improvement":
                prior.append((item.get("sequence"), node["id"]))
        prior.sort()
        previous_id = implementation_id
        for index, (sequence, prior_id) in enumerate(prior, 1):
            prior_node = old_nodes[prior_id]
            prior_design = prior_node["metadata"]["designFlow"]
            prior_fields = {"featureNodeId", "improvementLaneNodeId", "improvementPriority", "sequence",
                            "requestId", "feedbackId", "messageHash", "evidenceHash", "sourceNodeId"}
            fail(sequence == index and prior_fields <= set(prior_design)
                 and prior_design["sourceNodeId"] == previous_id,
                 "AUTHORITY_DENIED", "preexisting design improvement chain is not canonical")
            prior_details = {key: prior_design[key] for key in prior_fields}
            prior_token = hashlib.sha256(prior_details["requestId"].encode("utf-8")).hexdigest()[:12]
            expected_prior_id = f"{prefix}-improvement-{prior_token}"
            expected_prior = {"id": expected_prior_id, "kind": "feedback",
                "title": f"Forward design improvement {index}", "initialState": "pending",
                "priority": prior_details["improvementPriority"],
                "metadata": design_node_metadata(feature_id, flow_id, "improvement",
                    f"work/design-options/improvements/improvement-{prior_token}", prior_details)}
            expected_prior_edges = [design_edge("contains", prior_details["featureNodeId"], expected_prior_id),
                                    design_edge("assigned-to", expected_prior_id,
                                                prior_details["improvementLaneNodeId"]),
                                    design_edge("depends-on", expected_prior_id, previous_id),
                                    design_edge("feedback-for", expected_prior_id, implementation_id)]
            actual_prior_edges = [edge for edge in current["edges"] if edge["from"] == expected_prior_id]
            fail(prior_id == expected_prior_id and prior_node == expected_prior
                 and actual_prior_edges == sorted(expected_prior_edges, key=lambda item: item["id"])
                 and projection["nodeStates"].get(prior_id) == "completed",
                 "AUTHORITY_DENIED", "preexisting design improvement topology is not canonical")
            previous_id = prior_id
        expected_sequence = len(prior) + 1
        source_id = prior[-1][1] if prior else implementation_id
        fail(details["requestId"] == request_id and details["sequence"] == expected_sequence
             and details["sourceNodeId"] == source_id and source_id in old_nodes
             and implementation_id in old_nodes and details["featureNodeId"] in old_nodes
             and old_nodes[details["featureNodeId"]]["kind"] == "feature"
             and details["improvementLaneNodeId"] in old_nodes
             and old_nodes[details["improvementLaneNodeId"]]["kind"] == "lane"
             and integer(details["improvementPriority"], 0)
             and re.fullmatch(r"FB-[0-9]{4,}", details["feedbackId"]) is not None
             and HASH_RE.fullmatch(details["messageHash"]) is not None
             and HASH_RE.fullmatch(details["evidenceHash"]) is not None,
             "AUTHORITY_DENIED", "design improvement context is invalid")
        fail(projection["nodeStates"].get(f"{prefix}-selection-gate") == "approved"
             and projection["nodeStates"].get(implementation_id) == "completed"
             and projection["nodeStates"].get(source_id) == "completed",
             "AUTHORITY_DENIED", "design improvement requires a terminal canonical implementation/prior chain")
        feature_parts = design_feature_parts(store, feature_id)
        artifact_parts = (*feature_parts, *str(added_nodes[0]["metadata"]["designFlow"]["artifactPath"]).split("/"))
        message_data = store.read_bytes((*artifact_parts, "dissatisfaction.md"), 1024 * 1024, private=False)
        fail("sha256:" + hashlib.sha256(message_data).hexdigest() == details["messageHash"],
             "AUTHORITY_DENIED", "design improvement message hash does not bind the held artifact")
        inbox_names = [name for name in store.listdir(("roadmap", "inbox"))
                       if name.startswith(details["feedbackId"] + "-") and name.endswith(".md")]
        fail(len(inbox_names) == 1, "AUTHORITY_DENIED", "design improvement feedback ID is missing or ambiguous")
        inbox = store.read_bytes(("roadmap", "inbox", inbox_names[0]), 1024 * 1024, private=False).decode("utf-8")
        markers = set(inbox.splitlines())
        fail({f"- Design request: {request_id}", f"- Feature: {feature_id}", f"- Flow: {flow_id}",
              f"- Message hash: {details['messageHash']}", f"- Evidence path: {added_nodes[0]['metadata']['designFlow']['artifactPath']}",
              f"- Evidence hash: {details['evidenceHash']}"} <= markers,
             "AUTHORITY_DENIED", "design improvement is not bound to the held feedback inbox record")
        inventory_match = re.search(r"## Evidence inventory\n\n```json\n([\s\S]*?)```\n?\Z", inbox)
        fail(inventory_match is not None, "AUTHORITY_DENIED", "feedback evidence inventory is missing")
        inventory_raw = inventory_match.group(1).encode("utf-8")
        inventory = loads(inventory_raw, "feedback evidence inventory")
        fail(isinstance(inventory, list) and inventory_raw == canonical(inventory)
             and "sha256:" + hashlib.sha256(inventory_raw).hexdigest() == details["evidenceHash"],
             "AUTHORITY_DENIED", "feedback evidence inventory hash is invalid")
        evidence_parts = (*artifact_parts, "evidence")
        names = store.listdir(evidence_parts)
        fail(names == sorted(item.get("name") for item in inventory if isinstance(item, dict)),
             "AUTHORITY_DENIED", "feedback evidence directory differs from its inventory")
        total = 0
        for item in inventory:
            fail(isinstance(item, dict) and set(item) == {"name", "sha256", "size"}
                 and isinstance(item["name"], str) and isinstance(item["size"], int)
                 and not isinstance(item["size"], bool) and 0 <= item["size"] <= 64 * 1024 * 1024
                 and isinstance(item["sha256"], str) and HASH_RE.fullmatch(item["sha256"]) is not None,
                 "AUTHORITY_DENIED", "feedback evidence inventory entry is invalid")
            data = store.read_bytes((*evidence_parts, item["name"]), 64 * 1024 * 1024, private=False)
            total += len(data)
            fail(total <= 256 * 1024 * 1024 and len(data) == item["size"]
                 and "sha256:" + hashlib.sha256(data).hexdigest() == item["sha256"],
                 "AUTHORITY_DENIED", "feedback evidence artifact differs from its inventory")
        node_id = f"{prefix}-improvement-{token}"
        artifact = f"work/design-options/improvements/improvement-{token}"
        expected_nodes = [{"id": node_id, "kind": "feedback",
            "title": f"Forward design improvement {expected_sequence}", "initialState": "pending",
            "priority": details["improvementPriority"],
            "metadata": design_node_metadata(feature_id, flow_id, "improvement", artifact, details)}]
        expected_edges = [design_edge("contains", details["featureNodeId"], node_id),
                          design_edge("assigned-to", node_id, details["improvementLaneNodeId"]),
                          design_edge("depends-on", node_id, source_id),
                          design_edge("feedback-for", node_id, implementation_id)]
    else:
        raise HostError("AUTHORITY_DENIED", "unsupported design definition action")
    fail(added_nodes == sorted(expected_nodes, key=lambda item: item["id"])
         and added_edges == sorted(expected_edges, key=lambda item: item["id"]),
         "AUTHORITY_DENIED", "design definition delta exceeds the canonical action policy")


def design_binding(root_fd: int, request_value: Any, explicit_id: Optional[str] = None) -> Mapping[str, Any]:
    request = validate_design_request(request_value)
    graph = graph_module()
    capability = "graph-replace" if request["command"] == "replace-definition" else "gate-decision"
    allowed_types = {"operator", "system"} if capability == "graph-replace" else {"human"}
    try:
        with descriptor_store(root_fd) as store:
            authority_value = store.read_json(("authority", "control-graph-public-key.json"),
                                              "authority trust anchor", 65536, private=False)
            authority = graph.validate_authority(authority_value)
            validate_design_delta(store, request, graph, authority)
            fail(authority["canonicalHostId"] == graph.HOST_ID, "AUTHORITY_DENIED",
                 "design mutations must run on the authority's canonical host")
            names = store.listdir(("graph", "bindings"))
            candidates = []
            for name in names:
                match = re.fullmatch(r"([A-Za-z0-9][A-Za-z0-9._-]*)\.json", name)
                if match is None or (explicit_id is not None and match.group(1) != explicit_id):
                    continue
                try:
                    value = store.read_json(("graph", "bindings", name), "design actor binding",
                                            65536, private=False)
                    binding = graph.validate_binding(value, match.group(1), authority)
                    now = graph.utc_now()
                    if (graph.parse_time(binding["issuedAt"], "AUTHORITY_DENIED") <= now
                            < graph.parse_time(binding["expiresAt"], "AUTHORITY_DENIED")
                            and binding["graphId"] == request["graphId"]
                            and binding["subject"]["type"] in allowed_types
                            and capability in binding["capabilities"]):
                        candidates.append(binding)
                except Exception:
                    continue
    except HostError:
        raise
    except Exception as exc:
        raise HostError(getattr(exc, "code", "AUTHORITY_DENIED"),
                        getattr(exc, "message", "cannot validate design actor bindings"),
                        getattr(exc, "details", str(exc)), 4) from exc
    fail(len(candidates) == 1, "AUTHORITY_DENIED",
         "design mutation requires exactly one current capability-compatible actor binding",
         {"capability": capability, "candidates": sorted(item["bindingId"] for item in candidates)})
    return candidates[0]


def design_graph_mutation_args(request_value: Any, binding: Mapping[str, Any],
                               definition_fd: Optional[int] = None) -> list[str]:
    request = validate_design_request(request_value)
    common = ["--request-id", request["requestId"], "--expected-revision", str(request["expectedRevision"]),
              "--actor-binding", binding["bindingId"]]
    if request["command"] == "replace-definition":
        fail(definition_fd is not None and definition_fd >= 3, "IO_ERROR",
             "design definition descriptor is unavailable", exit_code=3)
        return ["replace-definition", f"/dev/fd/{definition_fd}", *common]
    return ["gate", "decide", request["gateNodeId"], request["decision"], *common]


def design_authorization(request: Mapping[str, Any], binding: Mapping[str, Any]) -> Mapping[str, Any]:
    graph = graph_module()
    intent = ({"definitionHash": graph.definition_hash(request["definition"])}
              if request["command"] == "replace-definition"
              else {"nodeId": request["gateNodeId"], "decision": request["decision"]})
    return {"schemaVersion": "operator.mutation-proof-request/v1", "command": request["command"],
            "requestId": request["requestId"], "bindingId": binding["bindingId"],
            "bindingGeneration": binding["generation"], "bindingHash": binding["bindingHash"],
            "intent": intent, "expectedRevision": request["expectedRevision"]}


def serve_design_broker(channel: socket.socket, request: Mapping[str, Any], binding: Mapping[str, Any],
                        signer: Callable[[Mapping[str, Any], Mapping[str, Any]], str]) -> int:
    graph = graph_module()
    authorization = design_authorization(request, binding)
    channel.settimeout(10)
    try:
        first = read_socket_record(channel, 64 * 1024)
        fail(first is not None, "AUTHORITY_DENIED", "design proof channel closed before authorize")
        exact(first, {"schemaVersion", "operation", "phase", "proofKeyId", "payload"}, "design proof challenge")
        fail(first.get("schemaVersion") == PROOF_CHALLENGE_VERSION and first.get("operation") == "sign"
             and first.get("phase") == "authorize" and first.get("proofKeyId") == binding["proofKey"]["keyId"]
             and first.get("payload") == authorization, "AUTHORITY_DENIED",
             "design authorize challenge exceeds the reviewed one-shot policy")
        channel.sendall(canonical({"schemaVersion": PROOF_RESPONSE_VERSION, "phase": "authorize",
                                   "proofKeyId": binding["proofKey"]["keyId"],
                                   "signature": signer(authorization, binding)}))
        second = read_socket_record(channel, MAX_JSON_BYTES + 64 * 1024)
        if second is None:
            return 0
        exact(second, {"schemaVersion", "operation", "phase", "proofKeyId", "payload"}, "design event challenge")
        fail(second.get("schemaVersion") == PROOF_CHALLENGE_VERSION and second.get("operation") == "sign"
             and second.get("phase") == "event" and second.get("proofKeyId") == binding["proofKey"]["keyId"],
             "AUTHORITY_DENIED", "design event challenge identity is invalid")
        payload = exact(second.get("payload"), {"schemaVersion", "event"}, "design event proof payload")
        event = exact(payload.get("event"), {"schemaVersion", "sequence", "eventId", "requestId",
                      "requestFingerprint", "occurredAt", "clock", "actor", "type", "intent",
                      "expectedRevision", "data", "result"}, "unsigned design event")
        expected_type = "definition.replaced" if request["command"] == "replace-definition" else "gate.decided"
        fail(payload.get("schemaVersion") == "operator.mutation-event-proof/v1"
             and event.get("schemaVersion") == "operator.control-event/v1"
             and event.get("sequence") == request["expectedRevision"] + 1
             and valid_id(event.get("eventId"), 128)
             and event.get("requestId") == request["requestId"] and event.get("type") == expected_type
             and event.get("intent") == authorization["intent"]
             and event.get("expectedRevision") == request["expectedRevision"]
             and event.get("requestFingerprint") == graph.sha256_value(authorization)
             and event.get("actor") == graph.actor_record(binding), "AUTHORITY_DENIED",
             "design event does not match the reviewed one-shot policy")
        try:
            occurred = graph.parse_time(event.get("occurredAt"), "AUTHORITY_DENIED")
            issued = graph.parse_time(binding["issuedAt"], "AUTHORITY_DENIED")
            expires = graph.parse_time(binding["expiresAt"], "AUTHORITY_DENIED")
        except Exception as exc:
            raise HostError(getattr(exc, "code", "AUTHORITY_DENIED"),
                            getattr(exc, "message", "design event time is invalid"),
                            getattr(exc, "details", str(exc)), 4) from exc
        clock = exact(event.get("clock"), {"hostId", "bootId", "monotonicSource", "monotonicNs"},
                      "design event clock")
        source, current_ns = graph.host_monotonic_sample()
        fail(issued <= occurred < expires and clock.get("hostId") == graph.HOST_ID
             and clock.get("bootId") == graph.BOOT_ID and clock.get("monotonicSource") == source
             and integer(clock.get("monotonicNs"), 0) and clock["monotonicNs"] <= current_ns,
             "AUTHORITY_DENIED", "design event time or monotonic clock is invalid")
        result = exact(event.get("result"), {"ok", "command", "requestId", "revision", "data"},
                       "design event result")
        fail(result.get("ok") is True and result.get("command") == request["command"]
             and result.get("requestId") == request["requestId"]
             and result.get("revision") == event["sequence"], "AUTHORITY_DENIED",
             "design event result is not bound to the request")
        if request["command"] == "replace-definition":
            data = exact(event.get("data"), {"definition"}, "design definition event data")
            committed = graph.validate_definition(data.get("definition"), materialized=True)
            reviewed = dict(committed)
            reviewed.pop("definitionRevision", None)
            fail(reviewed == request["definition"] and result["data"] == {
                    "graphId": committed["graphId"], "definitionRevision": committed["definitionRevision"],
                    "nodes": len(committed["nodes"]), "edges": len(committed["edges"]),
                 }, "AUTHORITY_DENIED", "committed definition differs from the reviewed design request")
        else:
            expected_data = {"nodeId": request["gateNodeId"], "from": "pending", "to": request["decision"]}
            fail(event.get("data") == expected_data and result.get("data") == expected_data,
                 "AUTHORITY_DENIED", "committed gate decision differs from explicit CLI intent")
        require_socket_write_eof(channel)
        channel.sendall(canonical({"schemaVersion": PROOF_RESPONSE_VERSION, "phase": "event",
                                   "proofKeyId": binding["proofKey"]["keyId"],
                                   "signature": signer(payload, binding)}))
        channel.shutdown(socket.SHUT_WR)
        return 0
    finally:
        channel.close()


def design_root_capability() -> Tuple[int, Path, Tuple[int, int]]:
    raw_fd = os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_FD", "")
    raw_dev = os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_DEV", "")
    raw_ino = os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_INO", "")
    raw_path = os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_PATH", "")
    fail(raw_fd.isdigit() and raw_dev.isdigit() and raw_ino.isdigit() and os.path.isabs(raw_path),
         "IO_ERROR", "design broker root capability is invalid", exit_code=3)
    fail(os.environ.get("OPERATOR_DESIGN_FLOW_ROOT_LOCK_MODE") == "exclusive-held",
         "IO_ERROR", "design broker requires a held exclusive root capability", exit_code=3)
    descriptor = os.dup(int(raw_fd))
    identity = (int(raw_dev), int(raw_ino))
    path = Path(os.path.abspath(raw_path))
    info = os.fstat(descriptor)
    fail(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid()
         and (info.st_dev, info.st_ino) == identity, "IO_ERROR",
         "design broker root descriptor identity changed", exit_code=3)
    current = os.lstat(path)
    fail(stat.S_ISDIR(current.st_mode) and not stat.S_ISLNK(current.st_mode)
         and current.st_uid == os.geteuid() and (current.st_dev, current.st_ino) == identity,
         "IO_ERROR", "design broker root path identity changed", exit_code=3)
    return descriptor, path, identity


def design_keychain_path(root_fd: int) -> Optional[Path]:
    if sys.platform != "darwin":
        return None
    try:
        with descriptor_store(root_fd) as store:
            raw = store.read_bytes(("host", "design-proof-keychain.json"), 65536, private=False)
    except FileNotFoundError:
        return None
    value = loads(raw, "design proof keychain locator")
    exact(value, {"schemaVersion", "path"}, "design proof keychain locator")
    fail(raw == canonical(value) and value.get("schemaVersion") == "operator.design-proof-keychain/v1"
         and isinstance(value.get("path"), str) and os.path.isabs(value["path"]),
         "BROKER_UNAVAILABLE", "design proof keychain locator is invalid", exit_code=3)
    path = Path(os.path.abspath(value["path"]))
    expected = os.lstat(path)
    fail(stat.S_ISREG(expected.st_mode) and not stat.S_ISLNK(expected.st_mode)
         and expected.st_uid == os.geteuid() and stat.S_IMODE(expected.st_mode) & 0o022 == 0,
         "BROKER_UNAVAILABLE", "design proof keychain file is unsafe", str(path), 3)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        actual = os.fstat(descriptor)
        fail((actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino)
             and stat.S_ISREG(actual.st_mode) and actual.st_uid == os.geteuid(),
             "BROKER_UNAVAILABLE", "design proof keychain changed during open", str(path), 3)
    finally:
        os.close(descriptor)
    return path


def design_external_signer(root_fd: int) -> Optional[Callable[[Mapping[str, Any], Mapping[str, Any]], str]]:
    try:
        with descriptor_store(root_fd) as store:
            raw = store.read_bytes(("host", "design-proof-signer.json"), 65536, private=False)
    except FileNotFoundError:
        return None
    value = loads(raw, "design proof signer locator")
    exact(value, {"schemaVersion", "command"}, "design proof signer locator")
    fail(raw == canonical(value) and value.get("schemaVersion") == "operator.design-proof-signer/v1"
         and isinstance(value.get("command"), str) and os.path.isabs(value["command"]),
         "BROKER_UNAVAILABLE", "design proof signer locator is invalid", exit_code=3)
    command = Path(os.path.abspath(value["command"]))

    def open_absolute_directory(path: Path, label: str) -> int:
        fail(path.is_absolute(), "BROKER_UNAVAILABLE", f"{label} is not absolute", exit_code=3)
        current = os.open("/", os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                          | getattr(os, "O_NOFOLLOW", 0))
        try:
            for component in path.parts[1:]:
                child = os.open(safe_component(component), os.O_RDONLY
                                | getattr(os, "O_DIRECTORY", 0)
                                | getattr(os, "O_NOFOLLOW", 0), dir_fd=current)
                info = os.fstat(child)
                fail(stat.S_ISDIR(info.st_mode), "BROKER_UNAVAILABLE",
                     f"{label} contains an unsafe component", component, 3)
                os.close(current)
                current = child
            return current
        except BaseException:
            os.close(current)
            raise

    operator_identity_info = os.fstat(root_fd)
    fail(stat.S_ISDIR(operator_identity_info.st_mode), "BROKER_UNAVAILABLE",
         "design proof signer Operator root capability is unsafe", exit_code=3)
    operator_identity = (operator_identity_info.st_dev, operator_identity_info.st_ino)
    # The shell launcher passes this module by its physical SCRIPT_DIR path.
    # Open that installed repository root component-by-component without
    # resolve(), so containment policy is bound to a held real directory
    # identity rather than to a textual prefix or a symlink-followed path.
    project_root = Path(os.path.abspath(__file__)).parent.parent
    project_fd = open_absolute_directory(project_root, "installed project repository root")
    try:
        project_info = os.fstat(project_fd)
        fail(stat.S_ISDIR(project_info.st_mode) and project_info.st_uid == os.geteuid(),
             "BROKER_UNAVAILABLE", "installed project repository root is unsafe",
             str(project_root), 3)
        project_identity = (project_info.st_dev, project_info.st_ino)
    finally:
        os.close(project_fd)
    excluded_roots = {operator_identity, project_identity}

    def open_command() -> int:
        current = os.open("/", os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
        try:
            for component in command.parts[1:-1]:
                child = os.open(safe_component(component), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                                | getattr(os, "O_NOFOLLOW", 0), dir_fd=current)
                info = os.fstat(child)
                fail(stat.S_ISDIR(info.st_mode), "BROKER_UNAVAILABLE",
                     "design proof signer parent is unsafe", component, 3)
                fail((info.st_dev, info.st_ino) not in excluded_roots,
                     "BROKER_UNAVAILABLE",
                     "design proof signer must be outside OPERATOR_DIR and the installed project repository",
                     str(command), 3)
                os.close(current)
                current = child
            descriptor = os.open(safe_component(command.name), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                                 dir_fd=current)
            info = os.fstat(descriptor)
            fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
                 and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) & 0o022 == 0
                 and stat.S_IMODE(info.st_mode) & 0o111,
                 "BROKER_UNAVAILABLE", "design proof signer executable is unsafe", str(command), 3)
            return descriptor
        finally:
            os.close(current)

    def command_bytes(descriptor: int) -> bytes:
        maximum = 8 * 1024 * 1024
        info_before = os.fstat(descriptor)
        fail(stat.S_ISREG(info_before.st_mode) and info_before.st_nlink == 1
             and info_before.st_size <= maximum,
             "BROKER_UNAVAILABLE", "design proof signer executable exceeds its bound",
             str(command), 3)
        chunks = bytearray()
        offset = 0
        while True:
            chunk = os.pread(descriptor, min(65536, maximum + 1 - len(chunks)), offset)
            if not chunk:
                break
            chunks.extend(chunk)
            offset += len(chunk)
            fail(len(chunks) <= maximum, "BROKER_UNAVAILABLE",
                 "design proof signer executable exceeds its bound", str(command), 3)
        info_after = os.fstat(descriptor)
        fail((info_before.st_dev, info_before.st_ino, info_before.st_size, info_before.st_mtime_ns)
             == (info_after.st_dev, info_after.st_ino, info_after.st_size, info_after.st_mtime_ns)
             and stat.S_ISREG(info_after.st_mode) and info_after.st_nlink == 1
             and len(chunks) == info_after.st_size,
             "BROKER_UNAVAILABLE", "design proof signer changed while it was read",
             str(command), 3)
        return bytes(chunks)

    verified = open_command()
    expected = os.fstat(verified)
    expected_bytes = command_bytes(verified)
    expected_hash = hashlib.sha256(expected_bytes).digest()
    os.close(verified)

    def external(payload: Mapping[str, Any], binding: Mapping[str, Any]) -> str:
        descriptor = open_command()
        current = os.fstat(descriptor)
        if (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
            os.close(descriptor)
            raise HostError("BROKER_UNAVAILABLE", "design proof signer executable identity changed", str(command), 3)
        executable = command_bytes(descriptor)
        if hashlib.sha256(executable).digest() != expected_hash:
            os.close(descriptor)
            raise HostError("BROKER_UNAVAILABLE", "design proof signer executable content changed", str(command), 3)
        request = {"schemaVersion": "operator.proof-sign-request/v1",
                   "proofKeyId": binding["proofKey"]["keyId"], "payload": dict(payload)}
        with tempfile.TemporaryDirectory(prefix="operator-design-signer-") as snapshot_dir, \
                tempfile.TemporaryFile() as output_file, tempfile.TemporaryFile() as error_file:
            os.chmod(snapshot_dir, 0o700)
            snapshot = Path(snapshot_dir) / "signer"
            snapshot_fd = os.open(snapshot, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                  | getattr(os, "O_NOFOLLOW", 0), 0o500)
            try:
                written = 0
                while written < len(executable):
                    count = os.write(snapshot_fd, executable[written:])
                    fail(count > 0, "BROKER_UNAVAILABLE",
                         "external design proof signer snapshot write failed", exit_code=3)
                    written += count
                os.fsync(snapshot_fd)
            finally:
                os.close(snapshot_fd)
            try:
                process = subprocess.Popen([str(snapshot)], stdin=subprocess.PIPE,
                                           stdout=output_file, stderr=error_file,
                                           env={"PATH": SYSTEM_PATH, "LC_ALL": "C", "LANG": "C",
                                                "HOME": pwd.getpwuid(os.geteuid()).pw_dir,
                                                "TMPDIR": "/tmp"},
                                           start_new_session=True)
                assert process.stdin is not None
                process.stdin.write(canonical(request))
                process.stdin.close()
                deadline = time.monotonic() + 10
                while process.poll() is None:
                    if os.fstat(output_file.fileno()).st_size > 4096 or os.fstat(error_file.fileno()).st_size > 4096:
                        with contextlib.suppress(ProcessLookupError):
                            os.killpg(process.pid, signal.SIGKILL)
                        raise HostError("BROKER_UNAVAILABLE", "external design proof signer output exceeded its live bound", exit_code=3)
                    if time.monotonic() >= deadline:
                        with contextlib.suppress(ProcessLookupError):
                            os.killpg(process.pid, signal.SIGKILL)
                        raise HostError("BROKER_UNAVAILABLE", "external design proof signer timed out", exit_code=3)
                    time.sleep(0.01)
                output_file.seek(0)
                response_bytes = output_file.read(4097)
                fail(process.returncode == 0 and len(response_bytes) <= 4096
                     and os.fstat(error_file.fileno()).st_size <= 4096,
                     "BROKER_UNAVAILABLE", "external design proof signer failed closed", exit_code=3)
            finally:
                os.close(descriptor)
        try:
            response_value = loads(response_bytes, "external design proof response", 4096)
            response_record = exact(response_value, {"schemaVersion", "proofKeyId", "signature"},
                                    "external design proof response")
            fail(response_bytes == canonical(response_record)
                 and response_record.get("schemaVersion") == "operator.proof-sign-response/v1"
                 and response_record.get("proofKeyId") == binding["proofKey"]["keyId"],
                 "BROKER_UNAVAILABLE", "external design proof response identity is invalid", exit_code=3)
            signature = response_record.get("signature")
            graph_module().verify_rsa_signature(payload, signature, binding["proofKey"]["publicKey"]["n"],
                                                binding["proofKey"]["publicKey"]["e"],
                                                "BROKER_UNAVAILABLE", "External design proof")
        except Exception as exc:
            raise HostError("BROKER_UNAVAILABLE",
                            "external design proof response is invalid",
                            getattr(exc, "details", str(exc)), 3) from exc
        rebound = open_command()
        after = os.fstat(rebound)
        after_bytes = command_bytes(rebound)
        os.close(rebound)
        fail((after.st_dev, after.st_ino) == (expected.st_dev, expected.st_ino)
             and hashlib.sha256(after_bytes).digest() == expected_hash,
             "BROKER_UNAVAILABLE", "design proof signer changed during signing", exit_code=3)
        return str(signature)
    return external


def design_broker_main() -> int:
    raw_channel = os.environ.get("OPERATOR_DESIGN_FLOW_BROKER_FD", "")
    raw_policy = os.environ.get("OPERATOR_DESIGN_FLOW_POLICY_FD", "")
    binding_id = os.environ.get("OPERATOR_DESIGN_FLOW_BINDING_ID", "")
    fail(raw_channel.isdigit() and raw_policy.isdigit() and BINDING_RE.fullmatch(binding_id) is not None,
         "BROKER_UNAVAILABLE", "design proof broker capability is unavailable", exit_code=3)
    root_fd, root_path, identity = design_root_capability()
    try:
        policy_fd = os.dup(int(raw_policy))
        try:
            os.lseek(policy_fd, 0, os.SEEK_SET)
            raw = os.read(policy_fd, MAX_JSON_BYTES + 1)
        finally:
            os.close(policy_fd)
        request = validate_design_request(loads(raw, "design broker policy"))
        fail(raw == canonical(request), "AUTHORITY_DENIED", "design broker policy is not canonical")
        binding = design_binding(root_fd, request, binding_id)
        signer = design_external_signer(root_fd)
        if signer is None:
            keychain_path = design_keychain_path(root_fd)
            private_key_secret(binding, keychain_path)
            signer = lambda payload, actor: sign_payload(payload, actor, keychain_path)
        code = serve_design_broker(socket.socket(fileno=os.dup(int(raw_channel))), request, binding, signer)
        current = os.lstat(root_path)
        fail(stat.S_ISDIR(current.st_mode) and not stat.S_ISLNK(current.st_mode)
             and (current.st_dev, current.st_ino) == identity, "IO_ERROR",
             "design broker root changed during mutation", exit_code=3)
        return code
    finally:
        os.close(root_fd)


def mutation_request(value: Any, record: Mapping[str, Any]) -> Mapping[str, Any]:
    fields = {"schemaVersion", "action", "graphId", "nodeId", "tickId", "requestId",
              "expectedRevision", "leaseId", "fence", "targetState", "ttlSeconds"}
    request = exact(value, fields, "loop mutation request")
    fail(request.get("schemaVersion") == "operator.loop-mutation-request/v1"
         and request.get("graphId") == record["graphId"] and request.get("nodeId") == record["nodeId"],
         "AUTHORITY_DENIED", "loop mutation request crosses durable host scope")
    fail(request.get("action") in {"acquire", "renew", "release", "transition"}
         and valid_id(request.get("tickId"), 256) and valid_id(request.get("requestId"), 256)
         and integer(request.get("expectedRevision"), 1), "INTERFACE_PROTOCOL", "loop mutation identity is invalid")
    action = request["action"]
    if action == "acquire":
        fail(valid_id(request.get("leaseId"), 256) and request.get("fence") is None
             and request.get("targetState") is None and integer(request.get("ttlSeconds"), 1)
             and request["ttlSeconds"] <= 86400,
             "INTERFACE_PROTOCOL", "lease acquire request is invalid")
    elif action == "renew":
        fail(valid_id(request.get("leaseId"), 256) and integer(request.get("fence"), 1)
             and request.get("targetState") is None and integer(request.get("ttlSeconds"), 1)
             and request["ttlSeconds"] <= 86400,
             "INTERFACE_PROTOCOL", "lease renew request is invalid")
    elif action == "release":
        fail(valid_id(request.get("leaseId"), 256) and integer(request.get("fence"), 1)
             and request.get("targetState") is None and request.get("ttlSeconds") is None,
             "INTERFACE_PROTOCOL", "lease release request is invalid")
    else:
        fail(valid_id(request.get("leaseId"), 256) and integer(request.get("fence"), 1)
             and request.get("targetState") in {"active", "completed", "failed"}
             and request.get("ttlSeconds") is None, "INTERFACE_PROTOCOL", "transition request is invalid")
    return request


def graph_mutation_args(request: Mapping[str, Any], record: Mapping[str, Any], proof_fd: int) -> list[str]:
    common = ["--request-id", request["requestId"], "--expected-revision", str(request["expectedRevision"]),
              "--actor-binding", record["actorBindingId"], "--proof-fd", str(proof_fd)]
    action = request["action"]
    if action == "acquire":
        return ["lease", "acquire", request["nodeId"], "--lease-id", request["leaseId"],
                "--holder-scope", record["holderScope"], "--ttl-seconds", str(request["ttlSeconds"]), *common]
    if action == "renew":
        return ["lease", "renew", request["nodeId"], "--lease-id", request["leaseId"],
                "--fence", str(request["fence"]), "--ttl-seconds", str(request["ttlSeconds"]), *common]
    if action == "release":
        return ["lease", "release", request["nodeId"], "--lease-id", request["leaseId"],
                "--fence", str(request["fence"]), *common]
    return ["transition", request["nodeId"], request["targetState"], "--lease-id", request["leaseId"],
            "--fence", str(request["fence"]), *common]


def _strict_host_graph_capabilities(before: Optional[Mapping[str, bytes]] = None) -> None:
    fail(_ACTIVE_HOST_ROOT is not None, "IO_ERROR",
         "host graph verification has no held Operator root", exit_code=3)
    assert _ACTIVE_HOST_ROOT is not None
    _ACTIVE_HOST_ROOT.verify_path()
    for parts in (("authority", "control-graph-public-key.json"),
                  ("graph", "definition.json"), ("graph", "projection.json"),
                  ("graph", "events.jsonl")):
        _ACTIVE_HOST_ROOT.assert_file(parts)
    if before is not None:
        graph = graph_module()
        for name, maximum in (("definition.json", graph.MAX_GRAPH_BYTES),
                              ("projection.json", graph.MAX_GRAPH_BYTES),
                              ("events.jsonl", graph.MAX_JOURNAL_BYTES)):
            actual = _ACTIVE_HOST_ROOT.read_bytes(("graph", name), maximum, private=True)
            fail(actual == before[name], "IO_ERROR",
                 "failed graph mutation changed retained state", name, 3)


def _mutation_graph_prestate() -> Mapping[str, bytes]:
    graph = graph_module()
    try:
        with held_store() as store:
            state = {
                "definition.json": store.read_bytes(("graph", "definition.json"), graph.MAX_GRAPH_BYTES, private=True),
                "projection.json": store.read_bytes(("graph", "projection.json"), graph.MAX_GRAPH_BYTES, private=True),
                "events.jsonl": store.read_bytes(("graph", "events.jsonl"), graph.MAX_JOURNAL_BYTES, private=True),
            }
        graph.parse_committed_events(state["events.jsonl"])
        return state
    except HostError:
        raise
    except Exception as exc:
        raise HostError(getattr(exc, "code", "CORRUPT_JOURNAL"),
                        getattr(exc, "message", "cannot validate the pre-mutation journal"),
                        getattr(exc, "details", str(exc)), 4) from exc


def _expected_loop_event(request: Mapping[str, Any], record: Mapping[str, Any]) -> Tuple[str, str, Mapping[str, Any]]:
    action = request["action"]
    if action == "acquire":
        return "lease acquire", "lease.acquired", {
            "nodeId": request["nodeId"], "leaseId": request["leaseId"],
            "holderScope": record["holderScope"], "ttlSeconds": request["ttlSeconds"],
        }
    if action == "renew":
        return "lease renew", "lease.renewed", {
            "nodeId": request["nodeId"], "leaseId": request["leaseId"],
            "fence": request["fence"], "ttlSeconds": request["ttlSeconds"],
        }
    if action == "release":
        return "lease release", "lease.released", {
            "nodeId": request["nodeId"], "leaseId": request["leaseId"],
            "fence": request["fence"],
        }
    return "transition", "node.transitioned", {
        "nodeId": request["nodeId"], "targetState": request["targetState"],
        "leaseId": request["leaseId"], "fence": request["fence"],
    }


def validate_refresh_host_mutation(record: Mapping[str, Any], request: Mapping[str, Any],
                                   output: bytes, before_journal: bytes) -> Mapping[str, Any]:
    """Validate result+journal+replay before adopting mutable graph leaf inodes."""
    result = exact(loads(output, "graph mutation result"),
                   {"ok", "command", "requestId", "revision", "data"},
                   "graph mutation result")
    command, event_type, expected_intent = _expected_loop_event(request, record)
    fail(result.get("ok") is True and result.get("command") == command
         and result.get("requestId") == request["requestId"]
         and integer(result.get("revision"), 1) and isinstance(result.get("data"), dict),
         "INTERFACE_PROTOCOL", "graph mutation result identity is invalid")
    graph = graph_module()
    candidate_descriptors: Dict[str, int] = {}
    try:
        with borrowed_active_store() as store:
            graph_fd = store.directory_fds.get(("graph",))
            fail(graph_fd is not None, "IO_ERROR", "held graph directory is unavailable", exit_code=3)
            lock = graph.DirectoryLock(Path(".lock"), parent_fd=graph_fd)
            with lock:
                store.verify_path()
                store.assert_file(("authority", "control-graph-public-key.json"))
                store.assert_file(("graph", "events.jsonl"))
                after_journal = store.read_bytes(("graph", "events.jsonl"),
                                                 graph.MAX_JOURNAL_BYTES, private=True)
                fail(after_journal.startswith(before_journal), "CORRUPT_JOURNAL",
                     "graph mutation rewrote the committed journal prefix")
                before_events = graph.parse_committed_events(before_journal)
                events = graph.parse_committed_events(after_journal)
                fail(len(events) in {len(before_events), len(before_events) + 1}, "CORRUPT_JOURNAL",
                     "graph mutation appended an unexpected number of events")
                matches = [event for event in events if event["requestId"] == request["requestId"]]
                fail(len(matches) == 1 and events[-1] is matches[0], "INTERFACE_PROTOCOL",
                     "graph mutation request is not the exact journal tail")
                event = matches[0]
                fail(event["type"] == event_type and event["intent"] == expected_intent
                     and event["expectedRevision"] == request["expectedRevision"]
                     and event["actor"]["bindingId"] == record["actorBindingId"]
                     and event["result"] == result and event["sequence"] == result["revision"],
                     "INTERFACE_PROTOCOL", "graph mutation result is not bound to the authorized journal event")
                authority_raw = store.read_bytes(("authority", "control-graph-public-key.json"),
                                                 65536, private=True)
                authority_value = graph.parse_json_bytes(authority_raw, Path("authority"), "CORRUPT_JOURNAL")
                authority = graph.validate_authority(authority_value)
                replayed_definition, replayed_projection = graph.replay(events, authority)
                candidates: Dict[str, Tuple[int, bytes, Tuple[int, int], Mapping[str, Any]]] = {}
                for name, expected_value in (("definition.json", replayed_definition),
                                             ("projection.json", replayed_projection)):
                    descriptor, raw, identity = store.open_candidate_bytes(
                        ("graph", name), graph.MAX_GRAPH_BYTES, f"graph {name}")
                    candidate_descriptors[name] = descriptor
                    parsed = graph.parse_json_bytes(raw, Path(name), "CORRUPT_JOURNAL")
                    fail(raw == graph.canonical_bytes(parsed) and parsed == expected_value,
                         "REPLAY_DRIFT", f"graph {name} does not match the validated journal replay")
                    candidates[name] = (descriptor, raw, identity, parsed)
                final_journal = store.read_bytes(("graph", "events.jsonl"),
                                                 graph.MAX_JOURNAL_BYTES, private=True)
                fail(final_journal == after_journal
                     and hashlib.sha256(final_journal).digest() == hashlib.sha256(after_journal).digest(),
                     "CORRUPT_JOURNAL", "graph journal changed during host post-commit validation")
                for name in ("definition.json", "projection.json"):
                    descriptor, raw, identity, _parsed = candidates[name]
                    store.adopt_candidate(("graph", name), descriptor, identity, raw)
                    candidate_descriptors.pop(name, None)
                store.assert_file(("graph", "events.jsonl"))
        return result
    except HostError:
        raise
    except Exception as exc:
        raise HostError(getattr(exc, "code", "INTERFACE_PROTOCOL"),
                        getattr(exc, "message", "graph mutation post-commit validation failed"),
                        getattr(exc, "details", str(exc)), 4) from exc
    finally:
        for descriptor in candidate_descriptors.values():
            with contextlib.suppress(OSError):
                os.close(descriptor)


@contextlib.contextmanager
def host_commit_boundary() -> Any:
    with held_store() as store:
        root_identity = os.fstat(store.root_fd)
        root_key = (root_identity.st_dev, root_identity.st_ino)
        descriptor = store.open_lock(("host", "mutation-effect.lock"))
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            store.assert_file(("host", "mutation-effect.lock"))
            current = os.lstat(store.root_path)
            fail((current.st_dev, current.st_ino) == root_key and stat.S_ISDIR(current.st_mode)
                 and not stat.S_ISLNK(current.st_mode), "IO_ERROR",
                 "host transaction root changed before commit", exit_code=3)
            yield
            store.assert_file(("host", "mutation-effect.lock"))
            current = os.lstat(store.root_path)
            fail((current.st_dev, current.st_ino) == root_key and stat.S_ISDIR(current.st_mode)
                 and not stat.S_ISLNK(current.st_mode), "IO_ERROR",
                 "host transaction root changed during commit", exit_code=3)
        finally:
            with contextlib.suppress(OSError):
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)


def _execute_mutation(record: Mapping[str, Any], request: Mapping[str, Any]) -> int:
    broker = script_dir() / "operator-proof-broker.sh"
    graph = script_dir() / "operator-graph.sh"
    fail(broker.is_file() and os.access(broker, os.X_OK), "BROKER_UNAVAILABLE", "proof broker is unavailable", exit_code=3)
    environment = broker_environment()
    root_environment, root_fds = host_root_environment()
    environment.update(root_environment)
    checked = subprocess.run([str(broker), "--check"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             env=environment, timeout=15, check=False, pass_fds=root_fds)
    fail(checked.returncode == 0, "BROKER_UNAVAILABLE", "proof broker or keychain state is unavailable", exit_code=3)
    before_state = _mutation_graph_prestate()
    broker_end, graph_end = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        broker_env = dict(environment)
        broker_env["OPERATOR_HOST_BROKER_FD"] = str(broker_end.fileno())
        broker_process = subprocess.Popen([str(broker)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL, env=broker_env,
                                          pass_fds=(broker_end.fileno(), *root_fds), start_new_session=True)
        graph_env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C",
                     **root_environment}
        with tempfile.TemporaryFile() as output_file, tempfile.TemporaryFile() as error_file:
            graph_process = subprocess.Popen([str(graph), *graph_mutation_args(request, record, graph_end.fileno())],
                                             stdin=subprocess.DEVNULL, stdout=output_file, stderr=error_file,
                                             env=graph_env, pass_fds=(graph_end.fileno(), *root_fds),
                                             start_new_session=True)
            broker_end.close()
            graph_end.close()
            deadline = time.monotonic() + 45
            while graph_process.poll() is None:
                if os.fstat(output_file.fileno()).st_size > MAX_JSON_BYTES or os.fstat(error_file.fileno()).st_size > MAX_JSON_BYTES:
                    for process in (graph_process, broker_process):
                        with contextlib.suppress(ProcessLookupError):
                            os.killpg(process.pid, signal.SIGKILL)
                    raise HostError("INTERFACE_PROTOCOL", "graph mutation output exceeded its live bound")
                if time.monotonic() >= deadline:
                    for process in (graph_process, broker_process):
                        with contextlib.suppress(ProcessLookupError):
                            os.killpg(process.pid, signal.SIGKILL)
                    raise HostError("BROKER_UNAVAILABLE", "mutation broker transaction timed out", exit_code=3)
                time.sleep(0.02)
            try:
                broker_code = broker_process.wait(timeout=5)
            except subprocess.TimeoutExpired as exc:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(broker_process.pid, signal.SIGKILL)
                raise HostError("BROKER_UNAVAILABLE", "proof broker did not close after mutation", str(exc), 3) from exc
            output_file.seek(0)
            error_file.seek(0)
            output = output_file.read(MAX_JSON_BYTES + 1)
            error = error_file.read(MAX_JSON_BYTES + 1)
            fail(len(output) <= MAX_JSON_BYTES and len(error) <= MAX_JSON_BYTES, "INTERFACE_PROTOCOL",
                 "graph mutation output exceeded its bound")
            if graph_process.returncode == 0 and broker_code == 0:
                validate_refresh_host_mutation(record, request, output, before_state["events.jsonl"])
                sys.stdout.buffer.write(output)
                return 0
            _strict_host_graph_capabilities(before_state)
            if error.strip():
                sys.stderr.buffer.write(error)
                return graph_process.returncode or 4
            raise HostError("BROKER_UNAVAILABLE", "proof broker failed closed", exit_code=3)
    finally:
        for channel in (broker_end, graph_end):
            with contextlib.suppress(OSError):
                channel.close()


def internal_mutation() -> int:
    record = load_session(os.environ.get("OPERATOR_HOST_TOOL", ""), os.environ.get("OPERATOR_HOST_SESSION", ""),
                          os.environ.get("OPERATOR_HOST_SCOPE"), os.environ.get("OPERATOR_HOST_INVOCATION"))
    request = mutation_request(loads(sys.stdin.buffer.read(MAX_JSON_BYTES + 1), "loop mutation request"), record)
    with host_commit_boundary():
        return _execute_mutation(record, request)


def internal_snapshot() -> int:
    load_session(os.environ.get("OPERATOR_HOST_TOOL", ""), os.environ.get("OPERATOR_HOST_SESSION", ""),
                 os.environ.get("OPERATOR_HOST_SCOPE"), os.environ.get("OPERATOR_HOST_INVOCATION"))
    command = script_dir() / "operator-graph.sh"
    root_environment, root_fds = host_root_environment()
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C",
                   **root_environment}
    code, output, error = bounded_child([str(command), "snapshot"], b"", environment,
                                        script_dir(), 30, MAX_JSON_BYTES,
                                        pass_fds=root_fds)
    stream = sys.stdout.buffer if code == 0 else sys.stderr.buffer
    stream.write(output if code == 0 else error)
    return code


def internal_clock() -> int:
    load_session(os.environ.get("OPERATOR_HOST_TOOL", ""), os.environ.get("OPERATOR_HOST_SESSION", ""),
                 os.environ.get("OPERATOR_HOST_SCOPE"), os.environ.get("OPERATOR_HOST_INVOCATION"))
    graph = graph_module()
    source, monotonic_ns = graph.host_monotonic_sample()
    sys.stdout.buffer.write(canonical({"schemaVersion": CLOCK_VERSION, "hostId": graph.HOST_ID,
                                       "bootId": graph.BOOT_ID, "monotonicSource": source,
                                       "monotonicNs": monotonic_ns}))
    return 0


def validate_live_lease(record: Mapping[str, Any], request: Mapping[str, Any]) -> Mapping[str, Any]:
    snapshot = graph_snapshot()
    fail(snapshot.get("graphId") == record["graphId"], "FENCE_STALE", "graph identity changed")
    snapshot_node = next((node for node in snapshot.get("nodes", [])
                          if isinstance(node, dict) and node.get("id") == record["nodeId"]), None)
    fail(isinstance(snapshot_node, dict), "FENCE_STALE", "runner node disappeared from the trusted snapshot")
    claim_kinds = ("files", "contracts", "resources", "lanes")
    expected_claims: Dict[str, list[str]] = {name: [] for name in claim_kinds}
    metadata = snapshot_node.get("metadata", {})
    scheduler = metadata.get("scheduler", {}) if isinstance(metadata, dict) else {}
    configured_claims = scheduler.get("claims", {}) if isinstance(scheduler, dict) else {}
    if isinstance(configured_claims, dict):
        for name in claim_kinds:
            values = configured_claims.get(name, [])
            if isinstance(values, list):
                expected_claims[name].extend(item for item in values if isinstance(item, str))
    for edge in snapshot.get("edges", []):
        if (isinstance(edge, dict) and edge.get("kind") == "assigned-to"
                and edge.get("from") == record["nodeId"] and isinstance(edge.get("to"), str)):
            expected_claims["lanes"].append(edge["to"])
    expected_claims = {name: sorted(set(values)) for name, values in expected_claims.items()}
    request_node = request.get("node", {})
    fail(request_node.get("kind") == snapshot_node.get("kind")
         and request_node.get("title") == snapshot_node.get("title")
         and request_node.get("claims") == expected_claims,
         "RUNNER_PROTOCOL", "runner node title, kind, or claims changed after scheduling")
    lease = snapshot.get("leases", {}).get(record["nodeId"])
    fail(isinstance(lease, dict) and lease.get("leaseId") == request.get("lease", {}).get("leaseId")
         and lease.get("fence") == request.get("lease", {}).get("fence")
         and lease.get("expiresAt") == request.get("lease", {}).get("expiresAt"),
         "FENCE_STALE", "runner lease is no longer current")
    holder = lease.get("holder", {})
    fail(holder.get("actorType") == record["actorType"]
         and holder.get("actorId") == record["actorId"]
         and holder.get("bindingId") == record["actorBindingId"] and holder.get("scope") == record["holderScope"]
         and holder.get("laneNodeId") == record["laneNodeId"]
         and holder.get("bindingGeneration") == record["actorBindingGeneration"]
         and holder.get("bindingHash") == record["actorBindingHash"], "FENCE_STALE", "runner lease holder changed")
    fail(snapshot.get("leaseFences", {}).get(record["nodeId"]) == lease.get("fence"), "FENCE_STALE",
         "a higher fence exists for this graph node")
    lease_clock = exact(lease.get("clock"), {"hostId", "bootId", "monotonicSource",
                         "acquiredMonotonicNs", "expiresMonotonicNs"}, "runner lease clock")
    graph = graph_module()
    source, monotonic_ns = graph.host_monotonic_sample()
    fail(lease_clock.get("hostId") == graph.HOST_ID and lease_clock.get("bootId") == graph.BOOT_ID
         and lease_clock.get("monotonicSource") == source
         and integer(lease_clock.get("acquiredMonotonicNs"), 0)
         and integer(lease_clock.get("expiresMonotonicNs"), 1)
         and lease_clock["acquiredMonotonicNs"] <= monotonic_ns < lease_clock["expiresMonotonicNs"],
         "LEASE_EXPIRED", "runner lease is expired or from another trusted monotonic epoch")
    return lease


def validate_runner_request(value: Any, record: Mapping[str, Any]) -> Mapping[str, Any]:
    request = exact(value, {"schemaVersion", "tickId", "runId", "idempotencyKey", "graphId", "node", "lease"},
                    "runner request")
    fail(request.get("schemaVersion") == RUN_REQUEST_VERSION and request.get("graphId") == record["graphId"]
         and valid_id(request.get("tickId"), 256) and valid_id(request.get("runId"), 256)
         and isinstance(request.get("idempotencyKey"), str) and HASH_RE.fullmatch(request["idempotencyKey"]),
         "RUNNER_PROTOCOL", "runner request identity is invalid")
    expected_key = "sha256:" + hashlib.sha256((record["graphId"] + "\0" + record["nodeId"]).encode("utf-8")).hexdigest()
    fail(request["idempotencyKey"] == expected_key, "RUNNER_PROTOCOL", "runner idempotency key is invalid")
    node = exact(request.get("node"), {"nodeId", "kind", "title", "claims"}, "runner node")
    fail(node.get("nodeId") == record["nodeId"] and node.get("kind") in {"task", "validation", "integration", "feedback"}
         and isinstance(node.get("title"), str) and 1 <= len(node["title"]) <= 512
         and isinstance(node.get("claims"), dict),
         "RUNNER_PROTOCOL", "runner node crosses durable host scope")
    claims = node["claims"]
    fail(set(claims) == {"files", "contracts", "resources", "lanes"}
         and all(isinstance(claims[name], list) and all(isinstance(item, str) for item in claims[name])
                 and claims[name] == sorted(set(claims[name]))
                 for name in claims), "RUNNER_PROTOCOL", "runner claims are invalid")
    lease = exact(request.get("lease"), {"leaseId", "fence", "expiresAt"}, "runner lease")
    fail(valid_id(lease.get("leaseId"), 256) and integer(lease.get("fence"), 1)
         and isinstance(lease.get("expiresAt"), str), "RUNNER_PROTOCOL", "runner lease is invalid")
    validate_live_lease(record, request)
    return request


def bounded_child(command: Sequence[str], input_bytes: bytes, environment: Mapping[str, str],
                  cwd: Path, timeout: int, maximum: int,
                  pass_fds: Sequence[int] = ()) -> Tuple[int, bytes, bytes]:
    with tempfile.TemporaryFile() as input_file, tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
        input_file.write(input_bytes)
        input_file.seek(0)
        process = subprocess.Popen(list(command), stdin=input_file, stdout=stdout_file, stderr=stderr_file,
                                   env=dict(environment), cwd=str(cwd), start_new_session=True,
                                   pass_fds=tuple(pass_fds))
        deadline = time.monotonic() + timeout
        while process.poll() is None:
            if os.fstat(stdout_file.fileno()).st_size > maximum or os.fstat(stderr_file.fileno()).st_size > maximum:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
                raise HostError("RUNNER_PROTOCOL", "runner output exceeded its live bound")
            if time.monotonic() >= deadline:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
                raise HostError("RUNNER_TIMEOUT", "runner exceeded its bounded execution time")
            time.sleep(0.05)
        stdout_file.seek(0)
        stderr_file.seek(0)
        output = stdout_file.read(maximum + 1)
        error = stderr_file.read(maximum + 1)
    fail(len(output) <= maximum and len(error) <= maximum, "RUNNER_PROTOCOL", "runner output exceeds its bound")
    return process.returncode, output, error


def runner_result(value: Any, request: Mapping[str, Any]) -> Mapping[str, Any]:
    result = exact(value, {"schemaVersion", "runId", "nodeId", "leaseId", "fence", "status", "summary", "error"},
                   "runner result")
    fail(result.get("schemaVersion") == RUN_RESULT_VERSION and result.get("runId") == request["runId"]
         and result.get("nodeId") == request["node"]["nodeId"]
         and result.get("leaseId") == request["lease"]["leaseId"]
         and result.get("fence") == request["lease"]["fence"], "RUNNER_PROTOCOL", "runner result identity mismatch")
    fail(result.get("status") in {"succeeded", "failed"} and isinstance(result.get("summary"), str)
         and len(result["summary"]) <= 4096, "RUNNER_PROTOCOL", "runner result status or summary is invalid")
    fail((result["status"] == "succeeded" and result.get("error") is None)
         or (result["status"] == "failed" and isinstance(result.get("error"), dict)),
         "RUNNER_PROTOCOL", "runner result error shape is invalid")
    return result


def result_schema() -> Mapping[str, Any]:
    return {"type": "object", "additionalProperties": False, "required": ["status", "summary", "error"],
            "properties": {"status": {"enum": ["succeeded", "failed"]},
                           "summary": {"type": "string", "maxLength": 4096},
                           "error": {"type": ["object", "null"]}}}


def production_runner(record: Mapping[str, Any], request: Mapping[str, Any], worktree: Path, run_dir: Path,
                      environment: Mapping[str, str]) -> Mapping[str, Any]:
    tool = str(record["tool"])
    request_text = canonical(request).decode("utf-8").strip()
    prompt = ("Execute only the leased Operator graph node below. The graph lease and fence are authoritative. "
              "Do not lease, reprioritize, integrate, decide gates, or access another lane. Run relevant validation. "
              "Return the requested structured result; use succeeded only when the assigned work and validation are complete.\n\n"
              + request_text)
    if tool == "codex":
        with tempfile.TemporaryFile() as schema_file, tempfile.TemporaryFile() as result_file:
            schema_file.write(canonical(result_schema()))
            schema_file.flush()
            schema_file.seek(0)
            command = [record["runnerExecutable"], "-a", "never", "exec", "-s", "workspace-write",
                       "-C", str(worktree), "--ignore-user-config", "--strict-config", "--ignore-rules",
                       "-c", 'shell_environment_policy.inherit="none"', "--ephemeral",
                       "--add-dir", str(run_dir), "--disable", "apps", "--disable", "browser_use",
                       "--disable", "computer_use", "--output-schema", f"/dev/fd/{schema_file.fileno()}",
                       "--output-last-message", f"/dev/fd/{result_file.fileno()}", "-"]
            code, _output, _error = bounded_child(command, prompt.encode("utf-8"), environment, worktree,
                                                   3600, MAX_RUNNER_BYTES,
                                                   (schema_file.fileno(), result_file.fileno()))
            fail(code == 0, "RUNNER_FAILED", "Codex runner failed", {"exitCode": code}, 4)
            result_file.seek(0)
            short = loads(result_file.read(65537), "Codex structured runner result", 65536)
    else:
        claude_settings = {"sandbox": {"enabled": True, "autoAllowBashIfSandboxed": False,
                                       "allowUnsandboxedCommands": False,
                                       "network": {"allowLocalBinding": False, "allowUnixSockets": []}}}
        command = [record["runnerExecutable"], "--print", "--safe-mode", "--permission-mode", "dontAsk",
                   "--tools", "Read,Edit,Write,Glob,Grep", "--disallowedTools",
                   "Bash,WebFetch,WebSearch,Task,Agent,Computer", "--no-session-persistence",
                   "--output-format", "json", "--json-schema", json.dumps(result_schema(), separators=(",", ":")),
                   "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                   "--settings", json.dumps(claude_settings, separators=(",", ":")),
                   "--add-dir", str(run_dir), prompt]
        code, output, _error = bounded_child(command, b"", environment, worktree, 3600, MAX_RUNNER_BYTES)
        fail(code == 0, "RUNNER_FAILED", "Claude runner failed", {"exitCode": code}, 4)
        wrapper = loads(output, "Claude structured runner result", MAX_RUNNER_BYTES)
        short = wrapper.get("structured_output") if isinstance(wrapper, dict) else None
    exact(short, {"status", "summary", "error"}, "structured agent result")
    status = short["status"]
    error = short["error"]
    fail(status in {"succeeded", "failed"} and isinstance(short["summary"], str)
         and ((status == "succeeded" and error is None) or (status == "failed" and isinstance(error, dict))),
         "RUNNER_PROTOCOL", "structured agent result is invalid")
    return {"schemaVersion": RUN_RESULT_VERSION, "runId": request["runId"],
            "nodeId": request["node"]["nodeId"], "leaseId": request["lease"]["leaseId"],
            "fence": request["lease"]["fence"], "status": status, "summary": short["summary"], "error": error}


def internal_runner() -> int:
    record = load_session(os.environ.get("OPERATOR_HOST_TOOL", ""), os.environ.get("OPERATOR_HOST_SESSION", ""),
                          os.environ.get("OPERATOR_HOST_SCOPE"), os.environ.get("OPERATOR_HOST_INVOCATION"))
    request = validate_runner_request(loads(sys.stdin.buffer.read(MAX_RUNNER_BYTES + 1), "runner request", MAX_RUNNER_BYTES), record)
    worktree = Path(record["worktree"])
    validate_worktree({"worktree": str(worktree), "branch": record["branch"]})
    runner_preflight(record["tool"], record["runnerExecutable"])
    run_parts = ("host", "handoffs", record["laneNodeId"], record["nodeId"], "runs",
                 request["idempotencyKey"].split(":", 1)[1], str(request["lease"]["fence"]))
    with held_store() as store:
        run_dir = store.ensure_dir(run_parts, private=True)
        temporary = store.ensure_dir((*run_parts, "tmp"), private=True)
    environment = {"PATH": trusted_path(), "LC_ALL": "C", "LANG": "C",
                   "HOME": pwd.getpwuid(os.geteuid()).pw_dir, "TMPDIR": str(temporary)}
    result = runner_result(production_runner(record, request, worktree, run_dir, environment), request)
    validate_live_lease(record, request)
    with held_store() as store:
        store.atomic_write_json((*run_parts, "accepted.json"), {"schemaVersion": EFFECT_VERSION,
                                                                 "idempotencyKey": request["idempotencyKey"],
                                                                 "fence": request["lease"]["fence"],
                                                                 "runId": request["runId"], "result": result},
                                private=True)
    sys.stdout.buffer.write(canonical(result))
    return 0


def receive_relay_frame(raw: bytes, label: str,
                        maximum_payload: int) -> Tuple[Mapping[str, Any], bytes]:
    line, separator, remainder = raw.partition(b"\n")
    fail(separator == b"\n" and len(line) + 1 <= MAX_INTERFACE_RELAY_HEADER_BYTES,
         "INTERFACE_PROTOCOL", f"{label} header is invalid")
    header = loads(line + b"\n", f"{label} header", MAX_INTERFACE_RELAY_HEADER_BYTES)
    fail(isinstance(header, dict) and integer(header.get("payloadBytes"), 0)
         and header["payloadBytes"] <= maximum_payload,
         "INTERFACE_PROTOCOL", f"{label} payload bound is invalid")
    expected = header["payloadBytes"]
    fail(len(remainder) == expected, "INTERFACE_PROTOCOL",
         f"{label} payload length is invalid")
    return header, remainder


def relay_interface_result(interface: str, payload: bytes) -> Tuple[int, bytes, bytes]:
    functions = {"snapshot": internal_snapshot, "clock": internal_clock,
                 "mutation": internal_mutation, "runner": internal_runner}
    with tempfile.TemporaryFile() as input_file, tempfile.TemporaryFile() as output_file, \
            tempfile.TemporaryFile() as error_file:
        input_file.write(payload); input_file.seek(0)
        saved = (os.dup(0), os.dup(1), os.dup(2))
        try:
            sys.stdout.flush(); sys.stderr.flush()
            os.dup2(input_file.fileno(), 0)
            os.dup2(output_file.fileno(), 1)
            os.dup2(error_file.fileno(), 2)
            try:
                code = functions[interface]()
            except HostError as exc:
                code = emit_error(exc)
            except KeyError as exc:
                code = emit_error(HostError("HOST_FAILED_CLOSED", "host runtime failed closed", str(exc)))
            except (OSError, subprocess.SubprocessError, ValueError, TypeError, RecursionError) as exc:
                code = emit_error(HostError("IO_ERROR", "host runtime I/O failed", str(exc), 3))
            sys.stdout.buffer.flush(); sys.stderr.buffer.flush()
        finally:
            os.dup2(saved[0], 0); os.dup2(saved[1], 1); os.dup2(saved[2], 2)
            for descriptor in saved:
                os.close(descriptor)
        output_file.seek(0); error_file.seek(0)
        output = output_file.read(MAX_JSON_BYTES + 1)
        error = error_file.read(MAX_JSON_BYTES + 1)
    fail(len(output) <= MAX_JSON_BYTES and len(error) <= MAX_JSON_BYTES,
         "INTERFACE_PROTOCOL", "interface relay output exceeded its bound")
    return code, output, error


def read_relay_file(directory_fd: int, name: str, maximum: int) -> bytes:
    descriptor = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
    try:
        before = os.fstat(descriptor)
        fail(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
             and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) & 0o077 == 0
             and before.st_size <= maximum,
             "INTERFACE_PROTOCOL", "interface relay file is unsafe", name, 4)
        data = bytearray()
        while len(data) <= maximum:
            chunk = os.read(descriptor, min(65536, maximum + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        after = os.fstat(descriptor)
        fail(len(data) == before.st_size and len(data) <= maximum
             and (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
             == (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns),
             "INTERFACE_PROTOCOL", "interface relay file changed during read", name, 4)
        return bytes(data)
    finally:
        os.close(descriptor)


def atomic_relay_file(directory_fd: int, name: str, data: bytes) -> None:
    fail(SAFE_NAME_RE.fullmatch(name) is not None, "INTERFACE_PROTOCOL",
         "interface relay filename is invalid", name, 4)
    temporary = f".{name}.{os.urandom(8).hex()}.tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                         | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=directory_fd)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(descriptor, data[offset:])
        os.fsync(descriptor)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary, dir_fd=directory_fd)
        raise
    finally:
        os.close(descriptor)
    os.replace(temporary, name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
    os.fsync(directory_fd)


def open_relay_liveness(directory_fd: int, expected: Tuple[int, int]) -> int:
    descriptor = os.open("liveness", os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
                         dir_fd=directory_fd)
    try:
        info = os.fstat(descriptor)
        fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
             and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) & 0o077 == 0
             and (info.st_dev, info.st_ino) == expected,
             "HOST_CONTAINMENT_UNAVAILABLE",
             "interface relay liveness capability is unsafe", exit_code=3)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def assert_relay_alive(descriptor: int) -> None:
    try:
        fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    else:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        raise HostError("HOST_SUPERVISION", "interface relay parent lifetime ended",
                        exit_code=4)


class RelayParentDeathGuard:
    """Kill a relay and every child it starts as soon as its parent pipe closes."""

    def __init__(self, parent_lifetime: int):
        self.parent_lifetime = parent_lifetime
        self.lock = threading.Lock()
        self.dead = threading.Event()
        self.armed = threading.Event()
        self.children: Dict[int, Tuple[subprocess.Popen[Any], bool]] = {}
        self.original_popen = subprocess.Popen

    def tracked_popen(self, *args: Any, **kwargs: Any) -> subprocess.Popen[Any]:
        separate_group = bool(kwargs.get("start_new_session", False))
        with self.lock:
            fail(not self.dead.is_set(), "HOST_SUPERVISION",
                 "interface relay parent lifetime ended", exit_code=4)
            process = self.original_popen(*args, **kwargs)
            self.children[process.pid] = (process, separate_group)
            return process

    def _watch(self) -> None:
        try:
            # The parent never writes. EOF or unexpected input both revoke the
            # relay capability immediately, including during a long request.
            self.armed.set()
            os.read(self.parent_lifetime, 1)
        except OSError:
            pass
        with self.lock:
            self.dead.set()
            for process, separate_group in tuple(self.children.values()):
                if process.poll() is not None:
                    continue
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    if separate_group:
                        os.killpg(process.pid, signal.SIGKILL)
                    else:
                        process.kill()
            # The relay is a dedicated session/process group. Killing the
            # whole group also terminates non-session children and closes all
            # duplicated authority descriptors in one kernel operation.
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(os.getpgrp(), signal.SIGKILL)
        os._exit(4)

    def discard_completed(self) -> None:
        with self.lock:
            for pid, (process, _separate_group) in tuple(self.children.items()):
                if process.poll() is not None:
                    self.children.pop(pid, None)

    def start(self) -> None:
        subprocess.Popen = self.tracked_popen  # type: ignore[assignment]
        threading.Thread(target=self._watch, name="operator-parent-lifetime",
                         daemon=True).start()
        fail(self.armed.wait(timeout=1), "HOST_CONTAINMENT_UNAVAILABLE",
             "interface relay parent-lifetime monitor did not start", exit_code=3)


def interface_relay_main() -> int:
    policy_fd = os.environ.get("OPERATOR_HOST_INTERFACE_POLICY_FD", "")
    relay_fd = os.environ.get("OPERATOR_HOST_INTERFACE_RELAY_DIR_FD", "")
    parent_fd = os.environ.get("OPERATOR_HOST_INTERFACE_PARENT_FD", "")
    fail(policy_fd.isdigit(), "HOST_CONTAINMENT_UNAVAILABLE",
         "interface relay policy capability is unavailable", exit_code=3)
    fail(relay_fd.isdigit(), "HOST_CONTAINMENT_UNAVAILABLE",
         "interface relay directory capability is unavailable", exit_code=3)
    fail(parent_fd.isdigit(), "HOST_CONTAINMENT_UNAVAILABLE",
         "interface relay parent-lifetime capability is unavailable", exit_code=3)
    parent_lifetime = os.dup(int(parent_fd))
    relay_directory = os.dup(int(relay_fd))
    relay_info = os.fstat(relay_directory)
    fail(stat.S_ISDIR(relay_info.st_mode) and relay_info.st_uid == os.geteuid()
         and stat.S_IMODE(relay_info.st_mode) & 0o077 == 0,
         "HOST_CONTAINMENT_UNAVAILABLE", "interface relay directory capability is unsafe", exit_code=3)
    descriptor = os.dup(int(policy_fd))
    try:
        os.lseek(descriptor, 0, os.SEEK_SET)
        raw_policy = os.read(descriptor, MAX_INTERFACE_RELAY_HEADER_BYTES + 1)
    finally:
        os.close(descriptor)
    policy = exact(loads(raw_policy, "interface relay policy", MAX_INTERFACE_RELAY_HEADER_BYTES),
                   {"schemaVersion", "tokens", "maxRequests", "livenessDev", "livenessIno"},
                   "interface relay policy")
    tokens = policy.get("tokens")
    fail(raw_policy == canonical(policy)
         and policy.get("schemaVersion") == INTERFACE_RELAY_POLICY_VERSION
         and isinstance(tokens, dict) and set(tokens) == {"snapshot", "clock", "mutation", "runner"}
         and all(isinstance(token, str) and re.fullmatch(r"[0-9a-f]{64}", token)
                 for token in tokens.values())
         and integer(policy.get("maxRequests"), 1)
         and policy["maxRequests"] <= MAX_INTERFACE_RELAY_REQUESTS,
         "HOST_CONTAINMENT_UNAVAILABLE", "interface relay policy is invalid", exit_code=3)
    fail(integer(policy.get("livenessDev"), 0) and integer(policy.get("livenessIno"), 1),
         "HOST_CONTAINMENT_UNAVAILABLE", "interface relay liveness identity is invalid",
         exit_code=3)
    liveness = open_relay_liveness(relay_directory,
                                   (policy["livenessDev"], policy["livenessIno"]))
    try:
        fcntl.flock(liveness, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        os.close(liveness)
        raise HostError("HOST_CONTAINMENT_UNAVAILABLE",
                        "interface relay liveness capability is already owned",
                        exit_code=3) from exc
    parent_guard = RelayParentDeathGuard(parent_lifetime)
    parent_guard.start()
    try:
        atomic_relay_file(relay_directory, "ready", canonical({
            "schemaVersion": INTERFACE_RELAY_POLICY_VERSION, "pid": os.getpid()}))
        served = 0
        while served < policy["maxRequests"]:
            requests = sorted(name for name in os.listdir(relay_directory)
                              if re.fullmatch(r"request-[0-9a-f]{64}\.frame", name))
            if not requests:
                time.sleep(0.005)
                continue
            name = requests[0]
            nonce = name[len("request-"):-len(".frame")]
            raw_request = read_relay_file(relay_directory, name,
                                          MAX_INTERFACE_RELAY_HEADER_BYTES + MAX_JSON_BYTES)
            os.unlink(name, dir_fd=relay_directory); os.fsync(relay_directory)
            header, payload = receive_relay_frame(raw_request, "interface relay request", MAX_JSON_BYTES)
            request = exact(header, {"schemaVersion", "interface", "token", "nonce", "payloadBytes"},
                            "interface relay request")
            interface = request.get("interface")
            fail(request.get("schemaVersion") == INTERFACE_RELAY_REQUEST_VERSION
                 and request.get("nonce") == nonce and interface in tokens
                 and request.get("token") == tokens[interface],
                 "AUTHORITY_DENIED", "interface relay request is not authorized")
            maximum = MAX_RUNNER_BYTES if interface == "runner" else MAX_JSON_BYTES
            fail(len(payload) <= maximum and (bool(payload) == (interface in {"mutation", "runner"})),
                 "INTERFACE_PROTOCOL", "interface relay payload is invalid for the requested interface")
            code, output, error = relay_interface_result(str(interface), payload)
            parent_guard.discard_completed()
            response = {"schemaVersion": INTERFACE_RELAY_RESPONSE_VERSION,
                        "nonce": nonce, "exitCode": code, "stdoutBytes": len(output),
                        "stderrBytes": len(error), "payloadBytes": len(output) + len(error)}
            atomic_relay_file(relay_directory, f"response-{nonce}.frame",
                              canonical(response) + output + error)
            served += 1
        raise HostError("HOST_SUPERVISION", "interface relay request bound was exhausted", exit_code=4)
    finally:
        os.close(liveness)
        os.close(parent_lifetime)
        os.close(relay_directory)


def interface_client_main(interface: str, relay_path: str, relay_dev: str,
                          relay_ino: str, liveness_dev: str,
                          liveness_ino: str, token: str) -> int:
    fail(interface in {"snapshot", "clock", "mutation", "runner"}
         and os.path.isabs(relay_path) and relay_dev.isdigit() and relay_ino.isdigit()
         and liveness_dev.isdigit() and liveness_ino.isdigit()
         and re.fullmatch(r"[0-9a-f]{64}", token) is not None,
         "AUTHORITY_DENIED", "interface relay client arguments are invalid")
    maximum = MAX_RUNNER_BYTES if interface == "runner" else MAX_JSON_BYTES
    payload = sys.stdin.buffer.read(maximum + 1)
    fail(len(payload) <= maximum and (bool(payload) == (interface in {"mutation", "runner"})),
         "INTERFACE_PROTOCOL", "interface relay client payload is invalid")
    expected = (int(relay_dev), int(relay_ino))
    before = os.lstat(relay_path)
    directory_fd = os.open(relay_path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                           | getattr(os, "O_NOFOLLOW", 0))
    liveness: Optional[int] = None
    try:
        actual = os.fstat(directory_fd)
        fail(stat.S_ISDIR(before.st_mode) and not stat.S_ISLNK(before.st_mode)
             and before.st_uid == os.geteuid() and stat.S_IMODE(before.st_mode) & 0o077 == 0
             and (before.st_dev, before.st_ino) == expected
             and (actual.st_dev, actual.st_ino) == expected,
             "AUTHORITY_DENIED", "interface relay directory identity changed")
        liveness = open_relay_liveness(directory_fd,
                                       (int(liveness_dev), int(liveness_ino)))
        assert_relay_alive(liveness)
        nonce = os.urandom(32).hex()
        request = {"schemaVersion": INTERFACE_RELAY_REQUEST_VERSION, "interface": interface,
                   "token": token, "nonce": nonce, "payloadBytes": len(payload)}
        atomic_relay_file(directory_fd, f"request-{nonce}.frame", canonical(request) + payload)
        response_name = f"response-{nonce}.frame"
        deadline = time.monotonic() + (3700 if interface == "runner" else 90)
        while True:
            assert_relay_alive(liveness)
            try:
                os.stat(response_name, dir_fd=directory_fd, follow_symlinks=False)
                break
            except FileNotFoundError:
                fail(time.monotonic() < deadline, "INTERFACE_TIMEOUT",
                     "interface relay response timed out", interface, 4)
                time.sleep(0.005)
        assert_relay_alive(liveness)
        raw_response = read_relay_file(directory_fd, response_name,
                                       MAX_INTERFACE_RELAY_HEADER_BYTES + 2 * MAX_JSON_BYTES)
        assert_relay_alive(liveness)
        os.unlink(response_name, dir_fd=directory_fd); os.fsync(directory_fd)
        header, body = receive_relay_frame(raw_response, "interface relay response", 2 * MAX_JSON_BYTES)
        response = exact(header, {"schemaVersion", "nonce", "exitCode", "stdoutBytes", "stderrBytes", "payloadBytes"},
                         "interface relay response")
        fail(response.get("schemaVersion") == INTERFACE_RELAY_RESPONSE_VERSION
             and response.get("nonce") == nonce
             and integer(response.get("exitCode"), 0) and response["exitCode"] <= 255
             and integer(response.get("stdoutBytes"), 0) and response["stdoutBytes"] <= MAX_JSON_BYTES
             and integer(response.get("stderrBytes"), 0) and response["stderrBytes"] <= MAX_JSON_BYTES
             and response["payloadBytes"] == response["stdoutBytes"] + response["stderrBytes"]
             and len(body) == response["payloadBytes"],
             "INTERFACE_PROTOCOL", "interface relay response is invalid")
        current = os.stat(relay_path, follow_symlinks=False)
        fail(stat.S_ISDIR(current.st_mode) and not stat.S_ISLNK(current.st_mode)
             and (current.st_dev, current.st_ino) == expected,
             "AUTHORITY_DENIED", "interface relay directory changed during the request")
        assert_relay_alive(liveness)
        split = response["stdoutBytes"]
        sys.stdout.buffer.write(body[:split]); sys.stderr.buffer.write(body[split:])
        return int(response["exitCode"])
    finally:
        if liveness is not None:
            os.close(liveness)
        os.close(directory_fd)


class InterfaceRelay:
    def __init__(self, record: Mapping[str, Any], invocation: str, root: Path,
                 max_requests: int):
        self.path = root / "interface-capability"
        self.path.mkdir(mode=0o700)
        self.directory_fd = os.open(self.path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                                    | getattr(os, "O_NOFOLLOW", 0))
        relay_info = os.fstat(self.directory_fd)
        self.identity = (relay_info.st_dev, relay_info.st_ino)
        self.tokens = {name: os.urandom(32).hex()
                       for name in ("snapshot", "clock", "mutation", "runner")}
        atomic_relay_file(self.directory_fd, "liveness", b"operator-interface-relay\n")
        liveness_info = os.stat("liveness", dir_fd=self.directory_fd,
                                follow_symlinks=False)
        self.liveness_identity = (liveness_info.st_dev, liveness_info.st_ino)
        self.policy = tempfile.TemporaryFile()
        policy = {"schemaVersion": INTERFACE_RELAY_POLICY_VERSION, "tokens": self.tokens,
                  "maxRequests": min(MAX_INTERFACE_RELAY_REQUESTS, max_requests),
                  "livenessDev": self.liveness_identity[0],
                  "livenessIno": self.liveness_identity[1]}
        self.policy.write(canonical(policy)); self.policy.flush(); self.policy.seek(0)
        parent_read, self.parent_lifetime = os.pipe()
        root_environment, root_fds = host_root_environment()
        environment = {"PATH": SYSTEM_PATH, "LC_ALL": "C", "LANG": "C",
                       "OPERATOR_HOST_TOOL": record["tool"],
                       "OPERATOR_HOST_SESSION": record["sessionId"],
                       "OPERATOR_HOST_SCOPE": record["nodeId"],
                       "OPERATOR_HOST_INVOCATION": invocation,
                       "OPERATOR_HOST_INTERFACE_POLICY_FD": str(self.policy.fileno()),
                       "OPERATOR_HOST_INTERFACE_RELAY_DIR_FD": str(self.directory_fd),
                       "OPERATOR_HOST_INTERFACE_PARENT_FD": str(parent_read),
                       **root_environment}
        self.output = tempfile.TemporaryFile(); self.error = tempfile.TemporaryFile()
        self.process = subprocess.Popen(
            [str(script_dir() / "operator-host.sh"), "__interface_relay"],
            stdin=subprocess.DEVNULL, stdout=self.output, stderr=self.error,
            env=environment, pass_fds=(*root_fds, self.policy.fileno(), self.directory_fd, parent_read),
            start_new_session=True)
        os.close(parent_read)
        deadline = time.monotonic() + 5
        ready = False
        while self.process.poll() is None and time.monotonic() < deadline:
            try:
                os.stat("ready", dir_fd=self.directory_fd, follow_symlinks=False)
                ready = True
                break
            except FileNotFoundError:
                time.sleep(0.01)
        if not ready or self.process.poll() is not None:
            diagnostic = self.diagnostic()
            self.close()
            raise HostError("HOST_CONTAINMENT_UNAVAILABLE", "interface capability relay did not become ready",
                            diagnostic, 3)

    def diagnostic(self) -> str:
        self.error.seek(0)
        return self.error.read(4096).decode("utf-8", errors="replace")

    def close(self) -> None:
        process = getattr(self, "process", None)
        parent_lifetime = getattr(self, "parent_lifetime", None)
        if parent_lifetime is not None:
            with contextlib.suppress(OSError):
                os.close(parent_lifetime)
            self.parent_lifetime = None
        if process is not None and process.poll() is None:
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=2)
        for stream_name in ("policy", "output", "error"):
            stream = getattr(self, stream_name, None)
            if stream is not None:
                with contextlib.suppress(OSError):
                    stream.close()
                setattr(self, stream_name, None)
        directory_fd = getattr(self, "directory_fd", None)
        if directory_fd is not None:
            with contextlib.suppress(OSError):
                os.close(directory_fd)
            self.directory_fd = None

    def __enter__(self) -> "InterfaceRelay":
        return self

    def __exit__(self, _kind: Any, _value: Any, _traceback: Any) -> None:
        self.close()


def interface_wrapper(path: Path, interface: str, relay: InterfaceRelay) -> None:
    lines = ["#!/bin/sh", "set -eu", "exec /usr/bin/env -i \\"]
    lines.append(f"  PATH={shlex.quote(SYSTEM_PATH)} LC_ALL=C LANG=C \\")
    lines.append(
        f"  {shlex.quote(str(script_dir() / 'operator-host.sh'))} __interface_client "
        f"{shlex.quote(interface)} {shlex.quote(str(relay.path))} "
        f"{relay.identity[0]} {relay.identity[1]} "
        f"{relay.liveness_identity[0]} {relay.liveness_identity[1]} "
        f"{shlex.quote(relay.tokens[interface])}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(path, 0o700)


def launchd_target(label: str) -> str:
    uid = os.geteuid()
    for domain in (f"gui/{uid}/{label}", f"user/{uid}/{label}"):
        checked = subprocess.run(["/bin/launchctl", "print", domain], stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, timeout=5, check=False)
        if checked.returncode == 0:
            return domain
    raise HostError("HOST_CONTAINMENT_UNAVAILABLE", "launchd job identity is unavailable", label, 3)


def supervised_darwin_job(arguments: Sequence[str], environment: Mapping[str, str], root: Path,
                          deadline_seconds: int = 86400) -> Tuple[int, bytes, bytes]:
    """Supervise the trusted loop as a launchd process-group job.

    launchd owns ordinary process-group teardown. A runner-created daemon may
    leave that group, but it cannot leave the native Codex/Claude sandbox it
    inherited. The runner sandbox, not unsupported EVFILT_PROC tracking, is the
    kernel boundary for such a survivor. An abnormal parent exit always
    remains a failed tick and is surfaced by tick_session.
    """
    fail(Path("/bin/launchctl").is_file(), "HOST_CONTAINMENT_UNAVAILABLE", "launchd is unavailable", exit_code=3)
    nonce = os.urandom(16).hex()
    label = f"com.agentoperatorkit.host.{os.getpid()}.{nonce}"
    wrapper = root / "darwin-job-wrapper.sh"
    status_path = root / "darwin-job-status"
    ready_path = root / "darwin-job-ready"
    start_path = root / "darwin-job-start"
    output_path = root / "darwin-job-stdout"
    error_path = root / "darwin-job-stderr"
    hold_path = root / "darwin-job-hold"
    os.mkfifo(hold_path, 0o600)
    lines = ["#!/bin/sh", "set +e"]
    for key, value in environment.items():
        lines.append(f"export {key}={shlex.quote(value)}")
    command = " ".join(shlex.quote(item) for item in arguments)
    lines.extend([
        f"umask 077; printf '%s %s\\n' {shlex.quote(nonce)} \"$$\" > {shlex.quote(str(ready_path))}.tmp",
        f"mv {shlex.quote(str(ready_path))}.tmp {shlex.quote(str(ready_path))}",
        f"while [ ! -f {shlex.quote(str(start_path))} ]; do :; done",
        f"{command}", "result=$?",
        f"umask 077; printf '%s %s %s\\n' {shlex.quote(nonce)} \"$$\" \"$result\" > {shlex.quote(str(status_path))}.tmp",
        f"mv {shlex.quote(str(status_path))}.tmp {shlex.quote(str(status_path))}",
        f"read _ < {shlex.quote(str(hold_path))}",
        "exit \"$result\"",
    ])
    wrapper.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(wrapper, 0o700)
    submitted = subprocess.run(["/bin/launchctl", "submit", "-l", label, "-o", str(output_path),
                                "-e", str(error_path), "--", str(wrapper)], stdout=subprocess.DEVNULL,
                               stderr=subprocess.PIPE, timeout=10, check=False)
    fail(submitted.returncode == 0, "HOST_CONTAINMENT_UNAVAILABLE", "launchd rejected the host job",
         {"returncode": submitted.returncode,
          "stderr": submitted.stderr.decode("utf-8", errors="replace")[:2048]}, 3)
    target = launchd_target(label)
    fail(1 <= deadline_seconds <= 86400, "HOST_SUPERVISION",
         "launchd supervision deadline is invalid", exit_code=4)
    deadline = time.monotonic() + deadline_seconds
    wrapper_pid = 0
    wrapper_identity: Optional[Mapping[str, Any]] = None
    try:
        while not ready_path.exists():
            fail(time.monotonic() < deadline, "HOST_SUPERVISION", "launchd wrapper did not report readiness", exit_code=4)
            time.sleep(0.01)
        ready = ready_path.read_text(encoding="utf-8").strip().split()
        fail(len(ready) == 2 and ready[0] == nonce and ready[1].isdigit(), "HOST_SUPERVISION",
             "launchd wrapper readiness identity is invalid", exit_code=4)
        wrapper_pid = int(ready[1])
        wrapper_identity = process_identity(wrapper_pid)
        fail(wrapper_identity.get("uid") == os.geteuid(), "HOST_SUPERVISION",
             "launchd wrapper ownership is invalid", exit_code=4)
        start_path.touch(mode=0o600)
        while not status_path.exists():
            for path in (output_path, error_path):
                if path.exists() and path.stat().st_size > MAX_JSON_BYTES:
                    raise HostError("INTERFACE_PROTOCOL", "contained loop output exceeded its live bound")
            fail(time.monotonic() < deadline, "HOST_SUPERVISION", "contained loop did not report completion", exit_code=4)
            time.sleep(0.005)
        parts = status_path.read_text(encoding="utf-8").strip().split()
        fail(len(parts) == 3 and parts[0] == nonce and parts[1].isdigit() and re.fullmatch(r"-?[0-9]+", parts[2]),
             "HOST_SUPERVISION", "launchd process-start identity record is invalid", exit_code=4)
        fail(int(parts[1]) == wrapper_pid, "HOST_SUPERVISION",
             "launchd wrapper completion identity changed", exit_code=4)
        code = int(parts[2])
        fail(process_identity(wrapper_pid).get("startedAt") == wrapper_identity.get("startedAt"),
             "HOST_SUPERVISION", "launchd wrapper PID was reused before containment", exit_code=4)
        killed = subprocess.run(["/bin/launchctl", "kill", "SIGKILL", target], stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, timeout=10, check=False)
        fail(killed.returncode == 0, "HOST_SUPERVISION", "launchd rejected process-group teardown",
             {"returncode": killed.returncode,
              "stderr": killed.stderr.decode("utf-8", errors="replace")[:2048]}, 4)
        stopped = False
        stop_deadline = time.monotonic() + 2
        while time.monotonic() < stop_deadline:
            try:
                current_identity = process_identity(wrapper_pid)
            except HostError:
                stopped = True
                break
            if current_identity.get("startedAt") != wrapper_identity.get("startedAt"):
                stopped = True
                break
            time.sleep(0.01)
        fail(stopped, "HOST_SUPERVISION", "launchd wrapper remained alive after teardown", exit_code=4)
        output = output_path.read_bytes() if output_path.exists() else b""
        error = error_path.read_bytes() if error_path.exists() else b""
        fail(len(output) <= MAX_JSON_BYTES and len(error) <= MAX_JSON_BYTES,
             "INTERFACE_PROTOCOL", "contained loop output exceeded its bound")
        return code, output, error
    finally:
        subprocess.run(["/bin/launchctl", "remove", label], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=10, check=False)


def supervised_loop(record: Mapping[str, Any], max_actions: int, dry_run: bool,
                    supervision_timeout: int = 86400) -> Tuple[int, bytes, bytes]:
    loop = script_dir() / "operator-loop.sh"
    fail(loop.is_file() and os.access(loop, os.X_OK), "TRUSTED_INTERFACE_UNAVAILABLE", "loop runtime is unavailable", exit_code=3)
    with tempfile.TemporaryDirectory(prefix="operator-host-") as temporary:
        root = Path(temporary)
        invocation, invocation_record = create_invocation(record)
        try:
            if sys.platform == "darwin":
                with InterfaceRelay(record, invocation, root, 4 * max_actions + 16) as relay:
                    commands: Dict[str, str] = {}
                    for interface in ("snapshot", "clock", "mutation", "runner"):
                        path = root / interface
                        interface_wrapper(path, interface, relay)
                        commands[interface] = str(path)
                    environment = {"PATH": SYSTEM_PATH, "LC_ALL": "C", "LANG": "C",
                                   "OPERATOR_DIR": str(operator_dir()),
                                   "OPERATOR_LOOP_SNAPSHOT_COMMAND": commands["snapshot"],
                                   "OPERATOR_LOOP_CLOCK_COMMAND": commands["clock"],
                                   "OPERATOR_LOOP_MUTATION_COMMAND": commands["mutation"],
                                   "OPERATOR_LOOP_RUNNER_COMMAND": commands["runner"]}
                    arguments = [str(loop), "tick", "--max-actions", str(max_actions), "--json"]
                    if dry_run:
                        arguments.insert(2, "--dry-run")
                    return supervised_darwin_job(arguments, environment, root, supervision_timeout)
            raise HostError("HOST_CONTAINMENT_UNAVAILABLE",
                            "this platform has no configured cgroup/job containment backend", exit_code=3)
        finally:
            remove_invocation(invocation_record)


def tick_session(tool: str, session: str, scope: str, max_actions: int, dry_run: bool) -> Mapping[str, Any]:
    fail(0 <= max_actions <= 10000, "USAGE", "--max-actions must be between 0 and 10000", exit_code=2)
    record = load_session(tool, session, scope)
    code, output, error = supervised_loop(record, max_actions, dry_run)
    fail(len(output) <= MAX_JSON_BYTES and len(error) <= MAX_JSON_BYTES, "INTERFACE_PROTOCOL", "loop output exceeded its bound")
    if code != 0:
        if code < 0 or 128 <= code <= 255:
            caught_signal = -code if code < 0 else code - 128
            raise HostError("HOST_SUPERVISION", "loop parent died; ordinary descendants were reaped and runner descendants remain sandbox-contained",
                            {"signal": caught_signal, "ordinaryDescendants": "launchd-process-group",
                             "daemonizedRunnerDescendants": "inherited-native-runner-sandbox"}, 4)
        diagnostic = None
        for raw in (error, output):
            if raw.strip():
                with contextlib.suppress(HostError):
                    diagnostic = loads(raw, "loop error")
                if diagnostic is None:
                    diagnostic = raw[:4096].decode("utf-8", errors="replace")
                break
        raise HostError("LOOP_FAILED", "host-supervised loop tick failed", diagnostic, 4)
    value = loads(output, "loop tick result")
    fail(isinstance(value, dict), "INTERFACE_PROTOCOL", "loop tick result is invalid")
    return value


def goal_context(record: Mapping[str, Any]) -> Mapping[str, Any]:
    snapshot = graph_snapshot()
    node = next((item for item in snapshot.get("nodes", []) if isinstance(item, dict)
                 and item.get("id") == record["nodeId"]), None)
    fail(isinstance(node, dict), "AUTHORITY_DENIED", "bound goal scope is absent from graph")
    objective = f"Complete Operator graph node {record['nodeId']}: {node.get('title', record['nodeId'])}"
    native = None
    note = "Claude receives this as scoped prompt context; only the top-level bound session may run a tick."
    if record["tool"] == "codex":
        native = {"kind": "codex-native-goal", "objective": objective, "activated": False,
                  "activation": "Invoke Codex /goal (or the native goal control) in the bound Codex session."}
        note = "This shell command emits context only; it cannot activate Codex /goal or create a native goal."
    return {"schemaVersion": GOAL_CONTEXT_VERSION, "tool": record["tool"], "sessionId": record["sessionId"],
            "scope": record["nodeId"], "graphId": record["graphId"], "objective": objective,
            "nativeGoal": native, "note": note}


def validate_effect_lease(snapshot: Mapping[str, Any], record: Mapping[str, Any],
                          lease_id: str, fence: int, label: str) -> Mapping[str, Any]:
    fail(snapshot.get("graphId") == record["graphId"], "FENCE_STALE", f"graph identity changed during {label}")
    lease = snapshot.get("leases", {}).get(record["nodeId"])
    fail(isinstance(lease, dict) and lease.get("leaseId") == lease_id and lease.get("fence") == fence
         and snapshot.get("leaseFences", {}).get(record["nodeId"]) == fence,
         "FENCE_STALE", f"external effect lease or fence is stale during {label}")
    holder = lease.get("holder", {})
    fail(holder.get("actorType") == record["actorType"]
         and holder.get("actorId") == record["actorId"]
         and holder.get("bindingId") == record["actorBindingId"]
         and holder.get("bindingGeneration") == record["actorBindingGeneration"]
         and holder.get("bindingHash") == record["actorBindingHash"]
         and holder.get("scope") == record["holderScope"] and holder.get("laneNodeId") == record["laneNodeId"],
         "FENCE_STALE", f"external effect holder changed during {label}")
    lease_clock = exact(lease.get("clock"), {"hostId", "bootId", "monotonicSource",
                         "acquiredMonotonicNs", "expiresMonotonicNs"}, "lease clock")
    graph = graph_module()
    source, monotonic_ns = graph.host_monotonic_sample()
    fail(lease_clock.get("hostId") == graph.HOST_ID and lease_clock.get("bootId") == graph.BOOT_ID
         and lease_clock.get("monotonicSource") == source
         and integer(lease_clock.get("acquiredMonotonicNs"), 0)
         and integer(lease_clock.get("expiresMonotonicNs"), 1)
         and lease_clock["acquiredMonotonicNs"] <= monotonic_ns < lease_clock["expiresMonotonicNs"],
         "LEASE_EXPIRED", f"external effect lease is expired or from another monotonic epoch during {label}")
    return lease


def pin_effect_commit_scope(record: Mapping[str, Any], args: argparse.Namespace) -> Tuple[str, ...]:
    """Bind every existing effect leaf, plus exact absence of future leaves."""
    effect_parts = ("host", "handoffs", record["laneNodeId"], record["nodeId"],
                    "committed-effects")
    with held_store() as store:
        store.ensure_dir(effect_parts, private=True)
        names = store.listdir(effect_parts)
        fail(len(names) <= 10000, "IO_ERROR", "effect directory inventory exceeds its bound", exit_code=3)
        for name in names:
            safe_component(name)
            store.pin_file_state((*effect_parts, name))
        for name in (".lock", "ledger.json", f"{args.fence}-{args.name}"):
            store.pin_file_state((*effect_parts, name))
    return effect_parts


@contextlib.contextmanager
def locked_graph_snapshot() -> Any:
    """Hold RM-0007's transaction lock across final effect validation/recording."""
    graph = graph_module()
    fail(_ACTIVE_HOST_ROOT is not None, "IO_ERROR",
         "effect commit has no held Operator root", exit_code=3)
    assert _ACTIVE_HOST_ROOT is not None
    store = graph.Store(Path("."))
    store.attach_trusted_root(_ACTIVE_HOST_ROOT)
    try:
        with store.lock():
            definition, projection, events = store.load()
            yield graph.snapshot_data(definition, projection, events)
    except HostError:
        raise
    except Exception as exc:
        raise HostError(getattr(exc, "code", "TRUSTED_INTERFACE_FAILED"),
                        getattr(exc, "message", "cannot acquire the graph commit boundary"),
                        getattr(exc, "details", str(exc)), 4) from exc
    finally:
        store.close()


def effect_commit(args: argparse.Namespace) -> Mapping[str, Any]:
    record = load_session(args.tool, args.session, args.scope)
    fail(HASH_RE.fullmatch(args.idempotency_key or "") is not None and valid_id(args.lease_id, 256)
         and integer(args.fence, 1)
         and SAFE_NAME_RE.fullmatch(args.name or "") is not None, "USAGE", "effect identity is invalid", exit_code=2)
    expected = "sha256:" + hashlib.sha256((record["graphId"] + "\0" + record["nodeId"]).encode("utf-8")).hexdigest()
    fail(args.idempotency_key == expected, "FENCE_STALE", "effect idempotency key is invalid")
    effect_parts = pin_effect_commit_scope(record, args)
    preliminary = graph_snapshot()
    validate_effect_lease(preliminary, record, args.lease_id, args.fence, "preliminary validation")
    payload = sys.stdin.buffer.read(MAX_EFFECT_BYTES + 1)
    fail(len(payload) <= MAX_EFFECT_BYTES, "INTERFACE_PROTOCOL", "external effect exceeds its bound")
    with host_commit_boundary():
        with locked_graph_snapshot() as final_snapshot:
            validate_effect_lease(final_snapshot, record, args.lease_id, args.fence, "final commit")
            with held_store() as store:
                store.ensure_dir(effect_parts, private=True)
                descriptor = store.open_lock((*effect_parts, ".lock"))
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX)
                    store.assert_file((*effect_parts, ".lock"))
                    ledger_parts = (*effect_parts, "ledger.json")
                    ledger: Dict[str, Any] = {"schemaVersion": EFFECT_VERSION, "idempotencyKey": expected,
                                              "highestFence": 0, "effects": {}}
                    if store.exists(ledger_parts):
                        ledger = dict(store.read_json(ledger_parts, "effect ledger", MAX_EFFECT_BYTES, private=True))
                    fail(ledger.get("schemaVersion") == EFFECT_VERSION and ledger.get("idempotencyKey") == expected
                         and integer(ledger.get("highestFence"), 0) and isinstance(ledger.get("effects"), dict),
                         "IO_ERROR", "effect ledger is corrupt", exit_code=3)
                    fail(args.fence >= ledger["highestFence"], "FENCE_STALE",
                         "effect fence is behind committed host state")
                    payload_hash = hashlib.sha256(payload).hexdigest()
                    previous = ledger["effects"].get(args.name)
                    if previous is not None:
                        fail(isinstance(previous, dict), "IO_ERROR", "effect ledger entry is corrupt", exit_code=3)
                        fail(previous == {"leaseId": args.lease_id, "fence": args.fence,
                                          "sha256": payload_hash, "bytes": len(payload)},
                             "EFFECT_CONFLICT", "effect name was already committed with different bytes or authority")
                        return {"schemaVersion": EFFECT_VERSION, "idempotencyKey": expected,
                                "leaseId": args.lease_id, "fence": args.fence, "name": args.name,
                                "bytes": len(payload), "sha256": payload_hash, "retry": True}
                    store.atomic_write_bytes((*effect_parts, f"{args.fence}-{args.name}"), payload, private=True)
                    ledger["highestFence"] = args.fence
                    ledger["effects"][args.name] = {"leaseId": args.lease_id, "fence": args.fence,
                                                     "sha256": payload_hash,
                                                     "bytes": len(payload)}
                    store.atomic_write_json(ledger_parts, ledger, private=True)
                    store.assert_file((*effect_parts, ".lock"))
                finally:
                    with contextlib.suppress(OSError):
                        fcntl.flock(descriptor, fcntl.LOCK_UN)
                    os.close(descriptor)
    return {"schemaVersion": EFFECT_VERSION, "idempotencyKey": expected, "leaseId": args.lease_id,
            "fence": args.fence, "name": args.name, "bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(), "retry": False}


def add_scope_options(parser: argparse.ArgumentParser, scope_required: bool = True) -> None:
    parser.add_argument("--tool", required=True, choices=("codex", "claude"))
    parser.add_argument("--session", required=True)
    parser.add_argument("--scope", required=scope_required)
    parser.add_argument("--json", action="store_true")


def build_parser() -> argparse.ArgumentParser:
    parser = JSONArgumentParser(prog="operator-host")
    sub = parser.add_subparsers(dest="command", required=True, parser_class=JSONArgumentParser)
    for name in ("open", "current"):
        child = sub.add_parser(name)
        add_scope_options(child, scope_required=False)
    bind = sub.add_parser("bind")
    add_scope_options(bind)
    tick = sub.add_parser("tick")
    add_scope_options(tick)
    tick.add_argument("--max-actions", type=int, default=1)
    tick.add_argument("--dry-run", action="store_true")
    goal = sub.add_parser("goal-context")
    add_scope_options(goal)
    effect = sub.add_parser("effect-commit")
    add_scope_options(effect)
    effect.add_argument("--idempotency-key", required=True)
    effect.add_argument("--lease-id", required=True)
    effect.add_argument("--fence", type=int, required=True)
    effect.add_argument("--name", required=True)
    return parser


def print_human(command: str, data: Mapping[str, Any]) -> None:
    if command in {"open", "current", "bind"}:
        print(f"{data['tool']} session {data['sessionId']} -> {data['graphId']}/{data['scope']}")
        print(f"Lane: {data['laneId']}  Branch: {data['branch']}")
    elif command == "goal-context":
        print(data["objective"])
        print(data["note"])
    else:
        sys.stdout.buffer.write(canonical(response(command, data)))


def emit_error(exc: HostError) -> int:
    payload: Dict[str, Any] = {"ok": False, "error": {"code": exc.code, "message": exc.message}}
    if exc.details is not None:
        payload["error"]["details"] = exc.details
    sys.stderr.buffer.write(canonical(payload))
    return exc.exit_code


def main(argv: Optional[Sequence[str]] = None) -> int:
    global _ACTIVE_HOST_ROOT
    args_list = list(sys.argv[1:] if argv is None else argv)
    root: Optional[AnchoredStore] = None
    try:
        internal = args_list[:1] in (["__broker"], ["__design_broker"], ["__interface"],
                                     ["__interface_relay"], ["__interface_client"])
        permitted_internal = {"OPERATOR_HOST_TOOL", "OPERATOR_HOST_SESSION", "OPERATOR_HOST_SCOPE",
                              "OPERATOR_HOST_INVOCATION", "OPERATOR_HOST_BROKER_FD",
                              "OPERATOR_DESIGN_FLOW_BROKER", "OPERATOR_DESIGN_FLOW_BROKER_FD",
                              "OPERATOR_DESIGN_FLOW_POLICY_FD", "OPERATOR_DESIGN_FLOW_BINDING_ID",
                              "OPERATOR_DESIGN_FLOW_ROOT_FD", "OPERATOR_DESIGN_FLOW_ROOT_DEV",
                              "OPERATOR_DESIGN_FLOW_ROOT_INO", "OPERATOR_DESIGN_FLOW_ROOT_PATH",
                              "OPERATOR_DESIGN_FLOW_ROOT_LOCK_MODE",
                              "OPERATOR_HOST_ROOT_FD", "OPERATOR_HOST_ROOT_DEV",
                              "OPERATOR_HOST_ROOT_INO", "OPERATOR_HOST_ROOT_PATH",
                              "OPERATOR_HOST_ROOT_LOCK_MODE",
                              "OPERATOR_HOST_ROOT_AUTHORITY_FD", "OPERATOR_HOST_ROOT_AUTHORITY_DEV",
                              "OPERATOR_HOST_ROOT_AUTHORITY_INO", "OPERATOR_HOST_ROOT_GRAPH_FD",
                              "OPERATOR_HOST_ROOT_GRAPH_DEV", "OPERATOR_HOST_ROOT_GRAPH_INO",
                              "OPERATOR_HOST_ROOT_BINDINGS_FD", "OPERATOR_HOST_ROOT_BINDINGS_DEV",
                              "OPERATOR_HOST_ROOT_BINDINGS_INO", "OPERATOR_HOST_ROOT_HOST_FD",
                              "OPERATOR_HOST_ROOT_HOST_DEV", "OPERATOR_HOST_ROOT_HOST_INO",
                              "OPERATOR_HOST_ROOT_DIR_CAPS",
                              "OPERATOR_HOST_ROOT_LEAF_CAPS",
                              "OPERATOR_HOST_ROOT_BINDING_MANIFEST_FD",
                              "OPERATOR_HOST_INTERFACE_POLICY_FD",
                              "OPERATOR_HOST_INTERFACE_RELAY_DIR_FD",
                              "OPERATOR_HOST_INTERFACE_PARENT_FD",
                              "OPERATOR_DIR"}
        injected = {name for name in FORBIDDEN_TEST_ENV.intersection(os.environ)
                    if not internal or name not in permitted_internal}
        injected.update(name for name in os.environ if name.startswith("OPERATOR_LOOP_"))
        injected.update(name for name in os.environ if name.startswith("OPERATOR_HOST_")
                        and (not internal or name not in permitted_internal))
        fail(not injected, "AUTHORITY_DENIED", "installed host runtime rejects test dependency injection",
             {"variables": sorted(injected)}, 4)
        if len(args_list) == 8 and args_list[0] == "__interface_client":
            return interface_client_main(args_list[1], args_list[2], args_list[3],
                                         args_list[4], args_list[5], args_list[6],
                                         args_list[7])
        root = command_root()
        _ACTIVE_HOST_ROOT = root
        if args_list[:1] == ["__broker"]:
            return broker_main(args_list[1:] == ["--check"])
        if args_list == ["__design_broker"]:
            return design_broker_main()
        if args_list == ["__interface_relay"]:
            return interface_relay_main()
        if len(args_list) == 2 and args_list[0] == "__interface":
            return {"snapshot": internal_snapshot, "clock": internal_clock,
                    "mutation": internal_mutation, "runner": internal_runner}[args_list[1]]()
        args = build_parser().parse_args(args_list)
        if args.command == "bind":
            data = scope_payload(bind_session(args.tool, args.session, args.scope))
        elif args.command in {"open", "current"}:
            data = scope_payload(load_session(args.tool, args.session, args.scope))
        elif args.command == "tick":
            tick_value = tick_session(args.tool, args.session, args.scope, args.max_actions, args.dry_run)
            if args.json:
                sys.stdout.buffer.write(canonical(tick_value))
            else:
                print_human("tick", tick_value.get("data", tick_value))
            return 0
        elif args.command == "goal-context":
            data = goal_context(load_session(args.tool, args.session, args.scope))
        else:
            data = effect_commit(args)
        if args.json:
            sys.stdout.buffer.write(canonical(response(args.command, data)))
        else:
            print_human(args.command, data)
        return 0
    except HostError as exc:
        return emit_error(exc)
    except KeyError as exc:
        return emit_error(HostError("HOST_FAILED_CLOSED", "host runtime failed closed", str(exc)))
    except (OSError, subprocess.SubprocessError, ValueError, TypeError, RecursionError) as exc:
        return emit_error(HostError("IO_ERROR", "host runtime I/O failed", str(exc), 3))
    finally:
        _ACTIVE_HOST_ROOT = None
        if root is not None:
            root.close()


if __name__ == "__main__":
    raise SystemExit(main())
