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

    def __init__(self, root: Path):
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

    def close(self) -> None:
        os.close(self.root_fd)

    def __enter__(self) -> "AnchoredStore":
        return self

    def __exit__(self, _kind: Any, _value: Any, _traceback: Any) -> None:
        self.close()

    def _open_dir(self, components: Sequence[str], create: bool = False,
                  private: bool = False) -> int:
        descriptor = os.dup(self.root_fd)
        try:
            for raw in components:
                component = safe_component(raw)
                if create:
                    try:
                        os.mkdir(component, 0o700 if private else 0o755, dir_fd=descriptor)
                    except FileExistsError:
                        pass
                flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
                next_descriptor = os.open(component, flags, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = next_descriptor
                info = os.fstat(descriptor)
                fail(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(), "IO_ERROR",
                     "anchored directory is unsafe", component, 3)
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
        parent = self._open_dir(components[:-1], create=False, private=private)
        try:
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(safe_component(components[-1]), flags, dir_fd=parent)
            try:
                info = os.fstat(descriptor)
                fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1,
                     "IO_ERROR", "anchored file is unsafe", components[-1], 3)
                if private:
                    fail(stat.S_IMODE(info.st_mode) & 0o077 == 0, "IO_ERROR",
                         "private anchored file permissions are unsafe", components[-1], 3)
                    os.fchmod(descriptor, 0o600)
                data = bytearray()
                while len(data) <= maximum:
                    chunk = os.read(descriptor, min(65536, maximum + 1 - len(data)))
                    if not chunk:
                        break
                    data.extend(chunk)
                fail(len(data) <= maximum, "IO_ERROR", "anchored file exceeds its bound", components[-1], 3)
                return bytes(data)
            finally:
                os.close(descriptor)
        finally:
            os.close(parent)

    def read_json(self, components: Sequence[str], label: str, maximum: int = 65536,
                  private: bool = True) -> Mapping[str, Any]:
        value = loads(self.read_bytes(components, maximum, private), label, maximum)
        fail(isinstance(value, dict), "IO_ERROR", f"{label} must be an object", exit_code=3)
        return value

    def atomic_write_bytes(self, components: Sequence[str], encoded: bytes,
                           private: bool = True) -> None:
        parent = self._open_dir(components[:-1], create=True, private=private)
        leaf = safe_component(components[-1])
        temporary = f".{leaf}.{os.getpid()}.{os.urandom(8).hex()}"
        try:
            try:
                existing = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
                fail(stat.S_ISREG(existing.st_mode) and not stat.S_ISLNK(existing.st_mode)
                     and existing.st_uid == os.geteuid() and existing.st_nlink == 1,
                     "IO_ERROR", "anchored destination is unsafe", leaf, 3)
            except FileNotFoundError:
                pass
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
            os.rename(temporary, leaf, src_dir_fd=parent, dst_dir_fd=parent)
            final_descriptor = os.open(leaf, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent)
            try:
                final = os.fstat(final_descriptor)
                fail(stat.S_ISREG(final.st_mode) and final.st_uid == os.geteuid() and final.st_nlink == 1,
                     "IO_ERROR", "anchored destination changed during commit", leaf, 3)
            finally:
                os.close(final_descriptor)
            os.fsync(parent)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary, dir_fd=parent)
            os.close(parent)

    def atomic_write_json(self, components: Sequence[str], value: Any,
                          private: bool = True) -> None:
        self.atomic_write_bytes(components, canonical(value), private)

    def open_lock(self, components: Sequence[str]) -> int:
        parent = self._open_dir(components[:-1], create=True, private=True)
        try:
            flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(safe_component(components[-1]), flags, 0o600, dir_fd=parent)
            info = os.fstat(descriptor)
            fail(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1,
                 "IO_ERROR", "anchored lock file is unsafe", components[-1], 3)
            os.fchmod(descriptor, 0o600)
            return descriptor
        finally:
            os.close(parent)


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
    with AnchoredStore(operator_dir()) as store:
        store.atomic_write_json(parts, value, private=True)
    return token, parts


def remove_invocation(parts: Sequence[str]) -> None:
    with AnchoredStore(operator_dir()) as store:
        parent = store._open_dir(parts[:-1], create=False, private=True)
        try:
            os.unlink(safe_component(parts[-1]), dir_fd=parent)
            os.fsync(parent)
        except FileNotFoundError:
            pass
        finally:
            os.close(parent)


def validate_invocation(token: str, record: Mapping[str, Any]) -> None:
    with AnchoredStore(operator_dir()) as store:
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


def validated_actor(binding_id: str) -> Mapping[str, Any]:
    fail(BINDING_RE.fullmatch(binding_id) is not None, "AUTHORITY_DENIED", "actor binding ID is invalid")
    graph = graph_module()
    try:
        with AnchoredStore(operator_dir()) as store:
            authority_value = store.read_json(("authority", "control-graph-public-key.json"),
                                              "authority trust anchor", 65536, private=True)
            binding_value = store.read_json(("graph", "bindings", f"{binding_id}.json"),
                                            "actor binding", 65536, private=True)
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
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C",
           "OPERATOR_DIR": str(operator_dir())}
    try:
        code, output, error = bounded_child([str(command), "snapshot"], b"", env, script_dir(), 30, MAX_JSON_BYTES)
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
    with AnchoredStore(operator_dir()) as store:
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
                binding = validated_actor(binding_id)
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
    with AnchoredStore(operator_dir()) as store:
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
    with AnchoredStore(operator_dir()) as store:
        exists = store.exists(parts)
    if exists:
        existing = load_session(tool, session)
        if dict(existing) == record:
            return record
        lease = snapshot.get("leases", {}).get(existing["nodeId"])
        fail(not isinstance(lease, dict) or lease.get("holder", {}).get("bindingId") != existing["actorBindingId"],
             "AUTHORITY_DENIED", "an active graph lease prevents session rebinding")
    with AnchoredStore(operator_dir()) as store:
        store.atomic_write_json(parts, record, private=True)
    return record


def load_session(tool: str, session: str, scope: Optional[str] = None,
                 invocation: Optional[str] = None) -> Mapping[str, Any]:
    with AnchoredStore(operator_dir()) as store:
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
    with AnchoredStore(operator_dir()) as store:
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


def private_key_secret(binding: Mapping[str, Any]) -> Tuple[int, int]:
    key_id = binding["proofKey"]["keyId"]
    if sys.platform == "darwin":
        command = ["/usr/bin/security", "find-generic-password", "-s", "agent-operator-kit.proof-key",
                   "-a", key_id, "-w"]
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


def sign_payload(payload: Mapping[str, Any], binding: Mapping[str, Any]) -> str:
    modulus, private_exponent = private_key_secret(binding)
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


@contextlib.contextmanager
def host_commit_boundary() -> Any:
    with AnchoredStore(operator_dir()) as store:
        descriptor = store.open_lock(("host", "mutation-effect.lock"))
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _execute_mutation(record: Mapping[str, Any], request: Mapping[str, Any]) -> int:
    broker = script_dir() / "operator-proof-broker.sh"
    graph = script_dir() / "operator-graph.sh"
    fail(broker.is_file() and os.access(broker, os.X_OK), "BROKER_UNAVAILABLE", "proof broker is unavailable", exit_code=3)
    environment = broker_environment()
    checked = subprocess.run([str(broker), "--check"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             env=environment, timeout=15, check=False)
    fail(checked.returncode == 0, "BROKER_UNAVAILABLE", "proof broker or keychain state is unavailable", exit_code=3)
    broker_end, graph_end = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        broker_env = dict(environment)
        broker_env["OPERATOR_HOST_BROKER_FD"] = str(broker_end.fileno())
        broker_process = subprocess.Popen([str(broker)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL, env=broker_env,
                                          pass_fds=(broker_end.fileno(),), start_new_session=True)
        graph_env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C",
                     "OPERATOR_DIR": str(operator_dir())}
        with tempfile.TemporaryFile() as output_file, tempfile.TemporaryFile() as error_file:
            graph_process = subprocess.Popen([str(graph), *graph_mutation_args(request, record, graph_end.fileno())],
                                             stdin=subprocess.DEVNULL, stdout=output_file, stderr=error_file,
                                             env=graph_env, pass_fds=(graph_end.fileno(),), start_new_session=True)
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
                sys.stdout.buffer.write(output)
                return 0
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
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C",
                   "OPERATOR_DIR": str(operator_dir())}
    code, output, error = bounded_child([str(command), "snapshot"], b"", environment,
                                        script_dir(), 30, MAX_JSON_BYTES)
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
    with AnchoredStore(operator_dir()) as store:
        run_dir = store.ensure_dir(run_parts, private=True)
        temporary = store.ensure_dir((*run_parts, "tmp"), private=True)
    environment = {"PATH": trusted_path(), "LC_ALL": "C", "LANG": "C",
                   "HOME": pwd.getpwuid(os.geteuid()).pw_dir, "TMPDIR": str(temporary)}
    result = runner_result(production_runner(record, request, worktree, run_dir, environment), request)
    validate_live_lease(record, request)
    with AnchoredStore(operator_dir()) as store:
        store.atomic_write_json((*run_parts, "accepted.json"), {"schemaVersion": EFFECT_VERSION,
                                                                 "idempotencyKey": request["idempotencyKey"],
                                                                 "fence": request["lease"]["fence"],
                                                                 "runId": request["runId"], "result": result},
                                private=True)
    sys.stdout.buffer.write(canonical(result))
    return 0


def interface_wrapper(path: Path, interface: str, record: Mapping[str, Any], invocation: str) -> None:
    exports = {"OPERATOR_HOST_TOOL": record["tool"],
               "OPERATOR_HOST_SESSION": record["sessionId"], "OPERATOR_HOST_SCOPE": record["nodeId"],
               "OPERATOR_HOST_INVOCATION": invocation}
    lines = ["#!/bin/sh", "set -eu", "exec /usr/bin/env -i \\"]
    for key, value in exports.items():
        lines.append(f"  {key}={shlex.quote(value)} \\")
    lines.append(f"  PATH={shlex.quote(SYSTEM_PATH)} LC_ALL=C LANG=C \\")
    lines.append(f"  {shlex.quote(str(script_dir() / 'operator-host.sh'))} __interface {shlex.quote(interface)}")
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


def supervised_darwin_job(arguments: Sequence[str], environment: Mapping[str, str], root: Path) -> Tuple[int, bytes, bytes]:
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
    deadline = time.monotonic() + 86400
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


def supervised_loop(record: Mapping[str, Any], max_actions: int, dry_run: bool) -> Tuple[int, bytes, bytes]:
    loop = script_dir() / "operator-loop.sh"
    fail(loop.is_file() and os.access(loop, os.X_OK), "TRUSTED_INTERFACE_UNAVAILABLE", "loop runtime is unavailable", exit_code=3)
    with tempfile.TemporaryDirectory(prefix="operator-host-") as temporary:
        root = Path(temporary)
        invocation, invocation_record = create_invocation(record)
        commands: Dict[str, str] = {}
        try:
            for interface in ("snapshot", "clock", "mutation", "runner"):
                path = root / interface
                interface_wrapper(path, interface, record, invocation)
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
            if sys.platform == "darwin":
                return supervised_darwin_job(arguments, environment, root)
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


@contextlib.contextmanager
def locked_graph_snapshot() -> Any:
    """Hold RM-0007's transaction lock across final effect validation/recording."""
    graph = graph_module()
    store = graph.Store(operator_dir())
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


def effect_commit(args: argparse.Namespace) -> Mapping[str, Any]:
    record = load_session(args.tool, args.session, args.scope)
    fail(HASH_RE.fullmatch(args.idempotency_key or "") is not None and valid_id(args.lease_id, 256)
         and integer(args.fence, 1)
         and SAFE_NAME_RE.fullmatch(args.name or "") is not None, "USAGE", "effect identity is invalid", exit_code=2)
    expected = "sha256:" + hashlib.sha256((record["graphId"] + "\0" + record["nodeId"]).encode("utf-8")).hexdigest()
    fail(args.idempotency_key == expected, "FENCE_STALE", "effect idempotency key is invalid")
    preliminary = graph_snapshot()
    validate_effect_lease(preliminary, record, args.lease_id, args.fence, "preliminary validation")
    payload = sys.stdin.buffer.read(MAX_EFFECT_BYTES + 1)
    fail(len(payload) <= MAX_EFFECT_BYTES, "INTERFACE_PROTOCOL", "external effect exceeds its bound")
    effect_parts = ("host", "handoffs", record["laneNodeId"], record["nodeId"], "committed-effects")
    with host_commit_boundary():
        with locked_graph_snapshot() as final_snapshot:
            validate_effect_lease(final_snapshot, record, args.lease_id, args.fence, "final commit")
            with AnchoredStore(operator_dir()) as store:
                store.ensure_dir(effect_parts, private=True)
                descriptor = store.open_lock((*effect_parts, ".lock"))
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX)
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
                finally:
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
    args_list = list(sys.argv[1:] if argv is None else argv)
    try:
        internal = args_list[:1] in (["__broker"], ["__interface"])
        permitted_internal = {"OPERATOR_HOST_TOOL", "OPERATOR_HOST_SESSION", "OPERATOR_HOST_SCOPE",
                              "OPERATOR_HOST_INVOCATION", "OPERATOR_HOST_BROKER_FD"}
        injected = set(FORBIDDEN_TEST_ENV.intersection(os.environ))
        injected.update(name for name in os.environ if name.startswith("OPERATOR_LOOP_"))
        injected.update(name for name in os.environ if name.startswith("OPERATOR_HOST_")
                        and (not internal or name not in permitted_internal))
        fail(not injected, "AUTHORITY_DENIED", "installed host runtime rejects test dependency injection",
             {"variables": sorted(injected)}, 4)
        if args_list[:1] == ["__broker"]:
            return broker_main(args_list[1:] == ["--check"])
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


if __name__ == "__main__":
    raise SystemExit(main())
