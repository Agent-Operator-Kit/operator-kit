#!/usr/bin/env python3
"""Lossless, explicit, fail-closed Operator Kit V4-to-V5 migration."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import types
from typing import Any, Callable, Iterable, Iterator, Mapping, Optional, Sequence


PLAN_VERSION = "operator.v5-migration-plan/v1"
MAPPING_VERSION = "operator.v5-migration-mapping/v1"
MANIFEST_VERSION = "operator.v5-migration-manifest/v1"
AUTHORIZATION = "MIGRATE_V4_TO_V5"
REQUIRED_CONFIG = {
    "PROJECT_NAME", "PROJECT_ROOT", "CODE_DIR", "OPERATOR_DIR",
    "TMUX_SESSION", "DEFAULT_BRANCH", "OPERATOR_KIT_VERSION", "OPERATOR_LANES",
}
LEGACY_ROOTS = ("features", "tasks", "roadmap", "memory", "catalog")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
RFC3339 = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$")
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
FILE_MODE = re.compile(r"^[0-7]{4}$")


class MigrationError(Exception):
    pass


def fail(message: str) -> None:
    raise MigrationError(message)


def canonical(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def digest_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def digest_value(value: Any) -> str:
    return digest_bytes(canonical(value))


def strict_json(raw: bytes, label: str) -> Any:
    """Decode one exact canonical JSON value without ambiguous token forms."""

    def pairs_hook(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                fail(f"{label} contains a duplicate object key: {key}")
            value[key] = item
        return value

    def reject_float(token: str) -> Any:
        fail(f"{label} contains a forbidden floating-point token: {token}")

    def parse_integer(token: str) -> int:
        if not re.fullmatch(r"0|-[1-9][0-9]*|[1-9][0-9]*", token):
            fail(f"{label} contains a noncanonical integer token: {token}")
        return int(token)

    def reject_constant(token: str) -> Any:
        fail(f"{label} contains a forbidden numeric constant: {token}")

    try:
        text = raw.decode("utf-8")
        value = json.loads(text, object_pairs_hook=pairs_hook, parse_float=reject_float,
                           parse_int=parse_integer, parse_constant=reject_constant)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        fail(f"{label} is malformed: {exc}")

    def reject_controls(item: Any, location: str) -> None:
        if isinstance(item, str):
            if CONTROL.search(item):
                fail(f"{label} contains a control character at {location}")
            return
        if type(item) is list:
            for index, child in enumerate(item):
                reject_controls(child, f"{location}[{index}]")
            return
        if type(item) is dict:
            for key, child in item.items():
                if CONTROL.search(key):
                    fail(f"{label} contains a control character in an object key")
                reject_controls(child, f"{location}.{key}")

    reject_controls(value, "$")
    try:
        encoded = canonical(value)
    except (UnicodeEncodeError, TypeError, ValueError) as exc:
        fail(f"{label} cannot be represented as canonical JSON: {exc}")
    if raw != encoded:
        fail(f"{label} bytes are not exact canonical JSON")
    return value


def require_object(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if type(value) is not dict or set(value) != expected:
        fail(f"{label} fields are incomplete, unknown, or ambiguous")
    return value


def require_string(value: Any, label: str, *, nonempty: bool = True) -> str:
    if not isinstance(value, str) or (nonempty and not value):
        fail(f"{label} must be {'a nonempty' if nonempty else 'a'} string")
    return value


def require_digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA256.fullmatch(value):
        fail(f"{label} must be a lowercase sha256 digest")
    return value


def require_scopes(value: Any) -> list[str]:
    if type(value) is not list or any(not isinstance(item, str) or not item for item in value):
        fail("selectedUnfinishedScopes must be a list of stable graph node IDs")
    if len(value) != len(set(value)):
        fail("selectedUnfinishedScopes contains duplicates")
    return value


DIRECTORY_FLAGS = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
FILE_FLAGS = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)


def safe_parts(parts: Sequence[str]) -> tuple[str, ...]:
    checked = tuple(parts)
    if any(not part or part in {".", ".."} or "/" in part or CONTROL.search(part) for part in checked):
        fail("migration path contains an unsafe component")
    return checked


class AnchoredRoot:
    """Held, no-follow root descriptor for every migration read and write."""

    def __init__(self, path: Path, descriptor: int, identity: tuple[int, int], label: str):
        self.path = path
        self.fd = descriptor
        self.identity = identity
        self.label = label

    @classmethod
    def open_absolute(cls, raw_path: Path, label: str) -> "AnchoredRoot":
        path = Path(os.path.abspath(os.path.expanduser(str(raw_path))))
        if not path.is_absolute():
            fail(f"{label} must be absolute")
        current = os.open("/", DIRECTORY_FLAGS)
        try:
            for component in path.parts[1:]:
                safe_parts((component,))
                before = os.stat(component, dir_fd=current, follow_symlinks=False)
                if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
                    fail(f"{label} traverses a symlink or non-directory: {path}")
                child = os.open(component, DIRECTORY_FLAGS, dir_fd=current)
                after = os.fstat(child)
                if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino):
                    os.close(child)
                    fail(f"{label} changed during descriptor traversal: {path}")
                os.close(current)
                current = child
            info = os.fstat(current)
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
                fail(f"{label} is not a real user-owned directory: {path}")
            return cls(path, current, (info.st_dev, info.st_ino), label)
        except BaseException:
            with contextlib.suppress(OSError):
                os.close(current)
            raise

    @classmethod
    def open_parent(cls, raw_path: Path, label: str) -> tuple["AnchoredRoot", str]:
        path = Path(os.path.abspath(os.path.expanduser(str(raw_path))))
        if path.name in {"", ".", ".."}:
            fail(f"{label} has an invalid leaf")
        return cls.open_absolute(path.parent, f"{label} parent"), safe_parts((path.name,))[0]

    def close(self) -> None:
        os.close(self.fd)

    def __enter__(self) -> "AnchoredRoot":
        return self

    def __exit__(self, _kind: Any, _value: Any, _traceback: Any) -> None:
        self.close()

    def verify_path(self) -> None:
        reopened = AnchoredRoot.open_absolute(self.path, self.label)
        try:
            if reopened.identity != self.identity:
                fail(f"{self.label} was interchanged during migration: {self.path}")
        finally:
            reopened.close()

    def open_dir(self, parts: Sequence[str], *, create: bool = False, mode: int = 0o700) -> int:
        descriptor = os.dup(self.fd)
        try:
            for component in safe_parts(parts):
                if create:
                    try:
                        os.mkdir(component, mode, dir_fd=descriptor)
                        os.fsync(descriptor)
                    except FileExistsError:
                        pass
                before = os.stat(component, dir_fd=descriptor, follow_symlinks=False)
                if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
                    fail(f"unsafe anchored directory beneath {self.label}: {'/'.join(parts)}")
                child = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
                after = os.fstat(child)
                if ((after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
                        or after.st_uid != os.geteuid()):
                    os.close(child)
                    fail(f"anchored directory changed or has unsafe ownership: {'/'.join(parts)}")
                os.close(descriptor)
                descriptor = child
            return descriptor
        except BaseException:
            with contextlib.suppress(OSError):
                os.close(descriptor)
            raise

    def stat_optional(self, parts: Sequence[str]) -> Optional[os.stat_result]:
        checked = safe_parts(parts)
        if not checked:
            return os.fstat(self.fd)
        try:
            parent = self.open_dir(checked[:-1])
        except FileNotFoundError:
            return None
        try:
            try:
                return os.stat(checked[-1], dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                return None
        finally:
            os.close(parent)

    def read_file(self, parts: Sequence[str], label: str,
                  maximum: int = 256 * 1024 * 1024) -> tuple[bytes, os.stat_result]:
        checked = safe_parts(parts)
        if not checked:
            fail(f"{label} has no file name")
        parent = self.open_dir(checked[:-1])
        descriptor: Optional[int] = None
        try:
            before = os.stat(checked[-1], dir_fd=parent, follow_symlinks=False)
            if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
                    or before.st_uid != os.geteuid() or before.st_nlink != 1):
                fail(f"{label} is not a safe owned regular file: {self.path.joinpath(*checked)}")
            if before.st_size > maximum:
                fail(f"{label} exceeds the migration bound: {self.path.joinpath(*checked)}")
            descriptor = os.open(checked[-1], FILE_FLAGS, dir_fd=parent)
            actual = os.fstat(descriptor)
            if ((actual.st_dev, actual.st_ino) != (before.st_dev, before.st_ino)
                    or not stat.S_ISREG(actual.st_mode) or actual.st_uid != os.geteuid()
                    or actual.st_nlink != 1):
                fail(f"{label} changed during descriptor open: {self.path.joinpath(*checked)}")
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(descriptor, min(65536, maximum + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > maximum:
                    fail(f"{label} exceeds the migration bound: {self.path.joinpath(*checked)}")
            data = b"".join(chunks)
            final = os.fstat(descriptor)
            if ((final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns)
                    != (actual.st_dev, actual.st_ino, actual.st_size, actual.st_mtime_ns)
                    or len(data) != final.st_size):
                fail(f"{label} changed during inventory: {self.path.joinpath(*checked)}")
            return data, final
        finally:
            if descriptor is not None:
                os.close(descriptor)
            os.close(parent)

    def atomic_replace(self, parts: Sequence[str], data: bytes, mode: int, label: str,
                       expected: Optional[tuple[int, int]] = None) -> None:
        checked = safe_parts(parts)
        parent = self.open_dir(checked[:-1])
        leaf = checked[-1]
        temporary = f".{leaf}.{os.getpid()}.{os.urandom(12).hex()}"
        descriptor: Optional[int] = None
        try:
            before = self.stat_optional(checked)
            if before is not None:
                if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
                        or before.st_uid != os.geteuid() or before.st_nlink != 1):
                    fail(f"{label} destination is unsafe")
                if expected is not None and (before.st_dev, before.st_ino) != expected:
                    fail(f"{label} leaf was interchanged before commit")
            elif expected is not None:
                fail(f"{label} disappeared before commit")
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                 | getattr(os, "O_NOFOLLOW", 0), mode, dir_fd=parent)
            os.fchmod(descriptor, mode)
            view = memoryview(data)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    fail(f"short write while committing {label}")
                view = view[written:]
            os.fsync(descriptor)
            os.close(descriptor)
            descriptor = None
            self.verify_path()
            current = os.stat(leaf, dir_fd=parent, follow_symlinks=False) if before is not None else None
            if before is not None and ((current.st_dev, current.st_ino) != (before.st_dev, before.st_ino)
                                       or not stat.S_ISREG(current.st_mode) or stat.S_ISLNK(current.st_mode)):
                fail(f"{label} leaf was interchanged during commit")
            if before is None:
                try:
                    os.stat(leaf, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    fail(f"{label} leaf appeared during commit")
            verification = self.open_dir(checked[:-1])
            try:
                verification_info = os.fstat(verification)
                parent_info = os.fstat(parent)
                if ((verification_info.st_dev, verification_info.st_ino)
                        != (parent_info.st_dev, parent_info.st_ino)):
                    fail(f"{label} parent was interchanged during commit")
            finally:
                os.close(verification)
            os.rename(temporary, leaf, src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
        finally:
            if descriptor is not None:
                with contextlib.suppress(OSError):
                    os.close(descriptor)
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary, dir_fd=parent)
            os.close(parent)


class HeldLockParent:
    """Exclusive, descriptor-bound parent directory for a lock pathname."""

    def __init__(self, root: AnchoredRoot, parts: tuple[str, ...], label: str):
        self.root = root
        self.parts = parts
        self.label = label
        self.fd = root.open_dir(parts)
        info = os.fstat(self.fd)
        self.identity = (info.st_dev, info.st_ino)
        self.locked = False
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.locked = True
            self.assert_owned()
        except BlockingIOError:
            os.close(self.fd)
            fail(f"{label} parent is owned by an active writer")
        except BaseException:
            os.close(self.fd)
            raise

    def assert_owned(self) -> None:
        actual = os.fstat(self.fd)
        if ((actual.st_dev, actual.st_ino) != self.identity or not stat.S_ISDIR(actual.st_mode)
                or actual.st_uid != os.geteuid()):
            fail(f"{self.label} held parent descriptor changed")
        reopened: Optional[int] = None
        try:
            reopened = self.root.open_dir(self.parts)
            published = os.fstat(reopened)
            if (published.st_dev, published.st_ino) != self.identity:
                fail(f"{self.label} parent pathname was interchanged")
        except FileNotFoundError:
            fail(f"{self.label} parent pathname disappeared")
        finally:
            if reopened is not None:
                os.close(reopened)

    def close(self) -> None:
        error: Optional[BaseException] = None
        try:
            self.assert_owned()
        except BaseException as exc:
            error = exc
        if self.locked:
            with contextlib.suppress(OSError):
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            self.locked = False
        with contextlib.suppress(OSError):
            os.close(self.fd)
        if error is not None:
            raise error


class HeldFileLock:
    """A flock whose published leaf and held parent remain identity-bound."""

    def __init__(self, parent: HeldLockParent, parts: tuple[str, ...], descriptor: int,
                 identity: tuple[int, int], label: str):
        self.parent = parent
        self.parts = parts
        self.leaf = parts[-1]
        self.fd = descriptor
        self.identity = identity
        self.label = label
        self.locked = True

    def assert_owned(self) -> None:
        self.parent.assert_owned()
        held = os.fstat(self.fd)
        if ((held.st_dev, held.st_ino) != self.identity or not stat.S_ISREG(held.st_mode)
                or held.st_uid != os.geteuid() or held.st_nlink != 1):
            fail(f"{self.label} held inode is no longer a safe published lock")
        try:
            published = os.stat(self.leaf, dir_fd=self.parent.fd, follow_symlinks=False)
        except FileNotFoundError:
            fail(f"{self.label} pathname disappeared while its flock was held")
        if (not stat.S_ISREG(published.st_mode) or stat.S_ISLNK(published.st_mode)
                or published.st_uid != os.geteuid() or published.st_nlink != 1
                or (published.st_dev, published.st_ino) != self.identity):
            fail(f"{self.label} pathname was replaced while its flock was held")

    def close(self) -> None:
        error: Optional[BaseException] = None
        try:
            self.assert_owned()
        except BaseException as exc:
            error = exc
        if self.locked:
            with contextlib.suppress(OSError):
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            self.locked = False
        with contextlib.suppress(OSError):
            os.close(self.fd)
        if error is not None:
            raise error


class LockRegistry:
    """Transaction-wide parent and leaf exclusions, released in reverse order."""

    def __init__(self, root: AnchoredRoot):
        self.root = root
        self.parents: dict[tuple[str, ...], HeldLockParent] = {}
        self.parent_order: list[HeldLockParent] = []
        self.locks: list[HeldFileLock] = []

    def hold_parent(self, parts: Sequence[str], label: str) -> HeldLockParent:
        checked = safe_parts(parts)
        existing = self.parents.get(checked)
        if existing is not None:
            existing.assert_owned()
            return existing
        parent = HeldLockParent(self.root, checked, label)
        self.parents[checked] = parent
        self.parent_order.append(parent)
        return parent

    def acquire(self, parts: Sequence[str], label: str, *, create: bool = False) -> HeldFileLock:
        checked = safe_parts(parts)
        if not checked:
            fail(f"{label} has no lock leaf")
        parent = self.hold_parent(checked[:-1], label)
        leaf = checked[-1]
        descriptor: Optional[int] = None
        created = False
        try:
            if create:
                try:
                    descriptor = os.open(leaf, os.O_RDWR | os.O_CREAT | os.O_EXCL
                                         | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=parent.fd)
                    created = True
                except FileExistsError:
                    pass
            if descriptor is None:
                before = os.stat(leaf, dir_fd=parent.fd, follow_symlinks=False)
                if (not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)
                        or before.st_uid != os.geteuid() or before.st_nlink != 1):
                    fail(f"{label} is unsafe: {'/'.join(checked)}")
                descriptor = os.open(leaf, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
                                     dir_fd=parent.fd)
                actual = os.fstat(descriptor)
                if ((actual.st_dev, actual.st_ino) != (before.st_dev, before.st_ino)
                        or not stat.S_ISREG(actual.st_mode) or actual.st_uid != os.geteuid()
                        or actual.st_nlink != 1):
                    fail(f"{label} changed during descriptor open: {'/'.join(checked)}")
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
                fail(f"{label} is unsafe: {'/'.join(checked)}")
            if created:
                os.fchmod(descriptor, 0o600)
                os.fsync(descriptor)
                os.fsync(parent.fd)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                fail(f"active writer holds a live flock: {'/'.join(checked)}")
            binding = HeldFileLock(parent, checked, descriptor, (info.st_dev, info.st_ino), label)
            binding.assert_owned()
            self.locks.append(binding)
            descriptor = None
            return binding
        finally:
            if descriptor is not None:
                with contextlib.suppress(OSError):
                    os.close(descriptor)

    def assert_owned(self) -> None:
        for parent in self.parent_order:
            parent.assert_owned()
        for binding in self.locks:
            binding.assert_owned()

    def close(self) -> None:
        errors: list[BaseException] = []
        for binding in reversed(self.locks):
            try:
                binding.close()
            except BaseException as exc:
                errors.append(exc)
        self.locks.clear()
        for parent in reversed(self.parent_order):
            try:
                parent.close()
            except BaseException as exc:
                errors.append(exc)
        self.parent_order.clear()
        self.parents.clear()
        if errors:
            raise errors[0]


def read_absolute_file(path: Path, label: str, maximum: int) -> tuple[bytes, os.stat_result, AnchoredRoot, str]:
    root, leaf = AnchoredRoot.open_parent(path, label)
    try:
        data, info = root.read_file((leaf,), label, maximum)
        return data, info, root, leaf
    except BaseException:
        root.close()
        raise


def parse_config(raw: bytes) -> dict[str, str]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(f"operator config is not UTF-8: {exc}")
    if "\r" in text or "\x00" in text:
        fail("operator config contains unsupported control bytes")
    values: dict[str, str] = {}
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        index += 1
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(['\"])(.*)", line)
        if not match:
            fail(f"operator config contains an ambiguous statement on line {index}")
        key, quote, remainder = match.groups()
        if key in values:
            fail(f"operator config assigns {key} more than once")
        if quote == '"':
            if not remainder.endswith('"') or remainder[:-1].find('"') >= 0:
                fail(f"operator config has an unsupported quoted value for {key}")
            value = remainder[:-1]
        else:
            parts = []
            current = remainder
            while True:
                if current.endswith("'"):
                    parts.append(current[:-1])
                    break
                parts.append(current)
                if index >= len(lines):
                    fail(f"operator config has an unterminated value for {key}")
                current = lines[index]
                index += 1
            value = "\n".join(parts)
        checked_value = value.replace("\n", "") if key == "OPERATOR_LANES" else value
        if CONTROL.search(checked_value):
            fail(f"operator config value {key} contains control characters")
        if any(token in value for token in ("$(`", "$(", "${", "`")):
            fail(f"operator config value {key} contains executable shell syntax")
        values[key] = value
    missing = sorted(REQUIRED_CONFIG - set(values))
    if missing:
        fail("operator config is incomplete: " + ", ".join(missing))
    return values


def contained(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def walk_tree(root: AnchoredRoot, category: str, *, include_root: bool = False) -> list[dict[str, Any]]:
    category_info = root.stat_optional((category,))
    if category_info is None:
        return []
    if (not stat.S_ISDIR(category_info.st_mode) or stat.S_ISLNK(category_info.st_mode)
            or category_info.st_uid != os.geteuid()):
        fail(f"legacy {category} root is malformed beneath {root.path}")
    entries: list[dict[str, Any]] = []
    if include_root:
        entries.append({"root": "operator", "path": category, "type": "directory",
                        "mode": format(stat.S_IMODE(category_info.st_mode), "04o")})

    def visit(parts: tuple[str, ...]) -> None:
        descriptor = root.open_dir(parts)
        try:
            names = sorted(os.listdir(descriptor))
        finally:
            os.close(descriptor)
        for name in names:
            safe_parts((name,))
            child = (*parts, name)
            info = root.stat_optional(child)
            if info is None:
                fail(f"legacy artifact disappeared during inventory: {'/'.join(child)}")
            record: dict[str, Any] = {"root": "operator", "path": "/".join(child),
                                      "mode": format(stat.S_IMODE(info.st_mode), "04o")}
            if stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode):
                opened = root.open_dir(child)
                opened_info = os.fstat(opened)
                os.close(opened)
                if (opened_info.st_dev, opened_info.st_ino) != (info.st_dev, info.st_ino):
                    fail(f"legacy directory changed during inventory: {'/'.join(child)}")
                record["type"] = "directory"
                entries.append(record)
                visit(child)
            elif stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode) and info.st_nlink == 1:
                data, opened_info = root.read_file(child, "legacy artifact")
                if (opened_info.st_dev, opened_info.st_ino) != (info.st_dev, info.st_ino):
                    fail(f"legacy file changed during inventory: {'/'.join(child)}")
                record.update({"type": "file", "bytes": len(data), "sha256": digest_bytes(data)})
                entries.append(record)
            else:
                fail(f"legacy {category} contains an unsafe artifact: {'/'.join(child)}")

    visit((category,))
    return entries


def inventory_tree(root: AnchoredRoot, category: str, *, exclude_handoffs: bool = False) -> list[dict[str, Any]]:
    entries = walk_tree(root, category)
    if exclude_handoffs:
        entries = [item for item in entries if "handoffs" not in Path(item["path"]).parts]
    return entries


def handoff_inventory(operator: AnchoredRoot) -> list[dict[str, Any]]:
    combined = walk_tree(operator, "handoffs", include_root=True)
    for category in ("features", "tasks"):
        combined.extend(item for item in walk_tree(operator, category)
                        if "handoffs" in Path(item["path"]).parts)
    unique = {item["path"]: item for item in combined}
    return [unique[path] for path in sorted(unique)]


def build_inventory(config_info: os.stat_result, operator: AnchoredRoot, config_raw: bytes) -> dict[str, Any]:
    categories: dict[str, list[dict[str, Any]]] = {
        "config": [{"root": "project", "path": "operator.config.env", "type": "file",
                    "mode": format(stat.S_IMODE(config_info.st_mode), "04o"),
                    "bytes": len(config_raw), "sha256": digest_bytes(config_raw)}],
        "features": inventory_tree(operator, "features", exclude_handoffs=True),
        "tasks": inventory_tree(operator, "tasks", exclude_handoffs=True),
        "handoffs": handoff_inventory(operator),
        "roadmap": inventory_tree(operator, "roadmap"),
        "memory": inventory_tree(operator, "memory"),
        "catalog": inventory_tree(operator, "catalog"),
    }
    return {"categories": categories, "digest": digest_value(categories)}


def replace_version(raw: bytes) -> bytes:
    text = raw.decode("utf-8")
    pattern = re.compile(r"^OPERATOR_KIT_VERSION=(?P<quote>['\"])4(?P=quote)$", re.MULTILINE)
    if len(pattern.findall(text)) != 1:
        fail("operator config must contain exactly one shell-safe quoted OPERATOR_KIT_VERSION=4 marker")
    return pattern.sub(lambda match: f"OPERATOR_KIT_VERSION={match.group('quote')}5{match.group('quote')}",
                       text).encode("utf-8")


def load_graph_runtime(script_root: AnchoredRoot) -> types.ModuleType:
    module_raw, _module_info = script_root.read_file(("operator_graph.py",),
                                                     "V5 graph validator", 16 * 1024 * 1024)
    module = types.ModuleType("operator_v5_migration_graph")
    module.__file__ = str(script_root.path / "operator_graph.py")
    sys.modules[module.__name__] = module
    exec(compile(module_raw, module.__file__, "exec"), module.__dict__)
    return module


def graph_state(operator: AnchoredRoot, module: types.ModuleType) -> dict[str, Any]:
    paths = {
        "authority": ("authority", "control-graph-public-key.json"),
        "definition": ("graph", "definition.json"),
        "projection": ("graph", "projection.json"),
        "events": ("graph", "events.jsonl"),
    }
    states = {name: operator.stat_optional(parts) for name, parts in paths.items()}
    material = [name for name, info in states.items() if info is not None
                and (name != "events" or info.st_size > 0)]
    if not material:
        return {"initialized": False, "graphId": None, "revision": None}
    if not all(info is not None and stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode)
               and info.st_uid == os.geteuid() and info.st_nlink == 1 for info in states.values()):
        fail("existing V5 graph state is partial or unsafe")
    try:
        payloads = {name: operator.read_file(parts, f"V5 graph {name}",
                    module.MAX_JOURNAL_BYTES + module.MAX_EVENT_BYTES if name == "events"
                    else module.MAX_GRAPH_BYTES)[0] for name, parts in paths.items()}
        with tempfile.TemporaryDirectory(prefix="operator-v5-migration-graph.") as temporary:
            temporary_root = Path(temporary)
            temporary_paths = {}
            temporary_fd = os.open(temporary_root, DIRECTORY_FLAGS)
            try:
                for name, data in payloads.items():
                    descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                         | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=temporary_fd)
                    try:
                        view = memoryview(data)
                        while view:
                            written = os.write(descriptor, view)
                            if written <= 0:
                                fail("short write while staging graph validation input")
                            view = view[written:]
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                    temporary_paths[name] = temporary_root / name
                os.fsync(temporary_fd)
            finally:
                os.close(temporary_fd)
            anchor = module.validate_authority(module.read_json_file(
                temporary_paths["authority"], "AUTHORITY_DENIED", "AUTHORITY_DENIED", module.MAX_BINDING_BYTES))
            journal = module.read_events(temporary_paths["events"], recover_tail=False)
            replayed_definition, replayed_projection = module.replay(journal, anchor)
            disk_definition = module.validate_definition(module.read_json_file(
                temporary_paths["definition"], "NOT_INITIALIZED", "INVALID_STATE", module.MAX_GRAPH_BYTES), materialized=True)
            disk_projection = module.read_json_file(
                temporary_paths["projection"], "NOT_INITIALIZED", "INVALID_STATE", module.MAX_GRAPH_BYTES)
            module.validate_projection(disk_projection, disk_definition)
    except Exception as exc:
        fail(f"existing V5 graph state is incompatible: {exc}")
    if not module.semantic_equal(disk_definition, replayed_definition) or not module.semantic_equal(disk_projection, replayed_projection):
        fail("existing V5 graph state has replay drift")
    return {"initialized": True, "graphId": disk_definition["graphId"],
            "revision": disk_projection["revision"],
            "nodeStates": dict(disk_projection["nodeStates"])}


def broker_readiness(script_root: AnchoredRoot) -> dict[str, Any]:
    broker_info = script_root.stat_optional(("operator-proof-broker.sh",))
    broker = script_root.path / "operator-proof-broker.sh"
    if (broker_info is None or not stat.S_ISREG(broker_info.st_mode) or stat.S_ISLNK(broker_info.st_mode)
            or broker_info.st_uid != os.geteuid() or broker_info.st_nlink != 1
            or stat.S_IMODE(broker_info.st_mode) & 0o111 == 0):
        fail("V5 proof broker runtime is unavailable")
    if sys.platform == "darwin":
        client = Path("/usr/bin/security")
        client_info = os.lstat(client)
        if (not stat.S_ISREG(client_info.st_mode) or stat.S_ISLNK(client_info.st_mode)
                or not os.access(client, os.X_OK)):
            fail("macOS keychain client is unavailable")
    elif sys.platform.startswith("linux"):
        resolved = shutil.which("secret-tool", path="/usr/local/bin:/usr/bin:/bin")
        if not resolved:
            fail("Linux Secret Service client is unavailable")
        client = Path(resolved)
        client_info = os.lstat(client)
        if not stat.S_ISREG(client_info.st_mode) or stat.S_ISLNK(client_info.st_mode):
            fail("Linux Secret Service client is unsafe")
    else:
        fail("the V5 proof broker has no supported OS keychain on this platform")
    return {"broker": str(broker), "keychainClient": str(client),
            "credentialVerified": False, "note": "credential is verified only inside a bound trusted host session"}


def tmux_writer_check(config: Mapping[str, str]) -> None:
    tmux = shutil.which("tmux", path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    if tmux:
        result = subprocess.run([tmux, "has-session", "-t", config["TMUX_SESSION"]],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, check=False)
        if result.returncode == 0:
            fail(f"tmux session {config['TMUX_SESSION']} is active; stop all V4 writers before migration")


def discover_lock_parts(root: AnchoredRoot,
                        ignored: frozenset[tuple[str, ...]] = frozenset()) -> list[tuple[str, ...]]:
    found: list[tuple[str, ...]] = []

    def visit(parts: tuple[str, ...]) -> None:
        info = root.stat_optional(parts)
        if info is None:
            return
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            fail(f"writer root is unsafe: {'/'.join(parts)}")
        descriptor = root.open_dir(parts)
        try:
            names = sorted(os.listdir(descriptor))
        finally:
            os.close(descriptor)
        for name in names:
            child = (*parts, name)
            child_info = root.stat_optional(child)
            if child_info is None:
                fail(f"writer state changed during inspection: {'/'.join(child)}")
            if child in ignored:
                continue
            is_lock = name in {".lock", "writer.lock", "mutation-effect.lock"} or name.endswith(".lock")
            if is_lock:
                if not stat.S_ISREG(child_info.st_mode) or stat.S_ISLNK(child_info.st_mode):
                    fail(f"active or ambiguous writer lock exists: {'/'.join(child)}")
                found.append(child)
            elif stat.S_ISDIR(child_info.st_mode) and not stat.S_ISLNK(child_info.st_mode):
                visit(child)

    for category in (*LEGACY_ROOTS, "graph", "loop", "host"):
        if root.stat_optional((category,)) is not None:
            visit((category,))
    return found


class MigrationGuardState:
    def __init__(self, writer_locks: frozenset[tuple[str, ...]], graph_runtime: types.ModuleType,
                 graph_lock: Any, graph_dir_identity: tuple[int, int], registry: LockRegistry):
        self.writer_locks = writer_locks
        self.graph_runtime = graph_runtime
        self.graph_lock = graph_lock
        self.graph_dir_identity = graph_dir_identity
        self.registry = registry
        self.marker_rollback: Optional[Callable[[], None]] = None

    def assert_graph_owned(self, operator: AnchoredRoot) -> None:
        try:
            self.graph_lock.assert_owned()
        except Exception as exc:
            fail(f"production graph transaction lock ownership was lost: {exc}")
        descriptor: Optional[int] = None
        try:
            descriptor = operator.open_dir(("graph",))
            current = os.fstat(descriptor)
            if (current.st_dev, current.st_ino) != self.graph_dir_identity:
                fail("production graph directory changed while migration held its transaction lock")
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def assert_file_locks_owned(self, operator: AnchoredRoot) -> None:
        held_root = os.fstat(operator.fd)
        if (held_root.st_dev, held_root.st_ino) != operator.identity:
            fail("held OPERATOR_DIR descriptor identity changed during migration")
        operator.verify_path()
        self.registry.assert_owned()

    def assert_transaction_owned(self, config: Mapping[str, str], operator: AnchoredRoot) -> None:
        self.assert_file_locks_owned(operator)
        self.assert_graph_owned(operator)
        current = frozenset(discover_lock_parts(operator, frozenset({("graph", ".lock")})))
        if current != self.writer_locks:
            fail("writer lock topology changed during migration")
        tmux_writer_check(config)

    def set_marker_rollback(self, callback: Callable[[], None]) -> None:
        self.marker_rollback = callback

    def rollback_marker_if_needed(self) -> None:
        if self.marker_rollback is None:
            return
        callback = self.marker_rollback
        self.marker_rollback = None
        callback()


@contextlib.contextmanager
def migration_guard(config: Mapping[str, str], operator: AnchoredRoot,
                    script_root: AnchoredRoot) -> Iterator[MigrationGuardState]:
    registry = LockRegistry(operator)
    graph_dir_descriptor: Optional[int] = None
    graph_lock: Any = None
    graph_lock_acquired = False
    root_locked = False
    guard: Optional[MigrationGuardState] = None
    try:
        migrations_fd = operator.open_dir(("migrations",), create=True, mode=0o700)
        try:
            os.fchmod(migrations_fd, 0o700)
            os.fsync(migrations_fd)
        finally:
            os.close(migrations_fd)
        registry.acquire(("migrations", ".v4-to-v5.lock"), "migration-wide lock", create=True)
        try:
            fcntl.flock(operator.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            root_locked = True
        except BlockingIOError:
            fail("active legacy, loop, or host writer holds the OPERATOR_DIR transaction lock")
        loop_info = operator.stat_optional(("loop",))
        if loop_info is not None:
            registry.hold_parent(("loop",), "loop transaction lock")
        graph_runtime = load_graph_runtime(script_root)
        try:
            graph_dir_descriptor = operator.open_dir(("graph",))
        except FileNotFoundError:
            fail("V5 graph runtime directory is missing; update the project before migration")
        graph_dir_info = os.fstat(graph_dir_descriptor)
        graph_lock = graph_runtime.DirectoryLock(operator.path / "graph" / ".lock", timeout=0.0,
                                                 parent_fd=graph_dir_descriptor)
        try:
            graph_lock.__enter__()
            graph_lock_acquired = True
        except graph_runtime.GraphError as exc:
            fail(f"production graph transaction lock is unavailable: {exc}")
        ignored_locks = frozenset({("graph", ".lock")})
        writer_locks = frozenset(discover_lock_parts(operator, ignored_locks))
        for parts in writer_locks:
            registry.acquire(parts, f"writer lock {'/'.join(parts)}")
        tmux_writer_check(config)
        guard = MigrationGuardState(writer_locks, graph_runtime, graph_lock,
                                    (graph_dir_info.st_dev, graph_dir_info.st_ino), registry)
        guard.assert_transaction_owned(config, operator)
        yield guard
    finally:
        release_error: Optional[BaseException] = None
        if guard is not None:
            try:
                guard.assert_transaction_owned(config, operator)
            except BaseException as exc:
                release_error = exc
        if graph_lock_acquired:
            try:
                graph_lock.__exit__(None, None, None)
            except BaseException as exc:
                if release_error is None:
                    release_error = exc
        if graph_dir_descriptor is not None:
            with contextlib.suppress(OSError):
                os.close(graph_dir_descriptor)
        if guard is not None:
            try:
                guard.assert_file_locks_owned(operator)
            except BaseException as exc:
                if release_error is None:
                    release_error = exc
        if release_error is not None and guard is not None:
            try:
                guard.rollback_marker_if_needed()
            except BaseException as exc:
                release_error = MigrationError(f"marker rollback after lock ownership loss failed: {exc}")
        try:
            registry.close()
        except BaseException as exc:
            if release_error is None:
                release_error = exc
                if guard is not None:
                    try:
                        guard.rollback_marker_if_needed()
                    except BaseException as rollback_exc:
                        release_error = MigrationError(
                            f"marker rollback after lock release failure failed: {rollback_exc}")
        if root_locked:
            with contextlib.suppress(OSError):
                fcntl.flock(operator.fd, fcntl.LOCK_UN)
        if release_error is not None:
            fail(f"migration transaction lock ownership or release was refused: {release_error}")


class MigrationContext:
    def __init__(self, config_path: Path):
        raw, info, repo, leaf = read_absolute_file(config_path, "operator config", 1024 * 1024)
        self.raw = raw
        self.config_info = info
        self.repo = repo
        self.config_leaf = leaf
        self.config = parse_config(raw)
        self.repo_path = repo.path
        self.operator = AnchoredRoot.open_absolute(Path(self.config["OPERATOR_DIR"]), "OPERATOR_DIR")
        project_root = AnchoredRoot.open_absolute(Path(self.config["PROJECT_ROOT"]), "PROJECT_ROOT")
        self.project_root_path = project_root.path
        project_root.close()
        if contained(self.operator.path, self.repo_path):
            self.close()
            fail("OPERATOR_DIR is repo-local; V5 migration requires private external state")
        if not contained(self.repo_path, self.project_root_path):
            self.close()
            fail("project repository is not contained by PROJECT_ROOT")

    def close(self) -> None:
        with contextlib.suppress(OSError):
            self.operator.close()
        with contextlib.suppress(OSError):
            self.repo.close()

    def __enter__(self) -> "MigrationContext":
        return self

    def __exit__(self, _kind: Any, _value: Any, _traceback: Any) -> None:
        self.close()

    def reread_config(self) -> bytes:
        data, info = self.repo.read_file((self.config_leaf,), "operator config", 1024 * 1024)
        if (info.st_dev, info.st_ino) != (self.config_info.st_dev, self.config_info.st_ino):
            fail("operator config leaf was interchanged during migration")
        return data


def context(config_path: Path) -> MigrationContext:
    value = MigrationContext(config_path)
    repo = value.repo_path
    operator_dir = value.operator.path
    if contained(operator_dir, repo):
        value.close()
        fail("OPERATOR_DIR is repo-local; V5 migration requires private external state")
    return value


def plan(config_path: Path) -> dict[str, Any]:
    with context(config_path) as current:
        config = current.config
        if config["OPERATOR_KIT_VERSION"] not in {"4", "5"}:
            fail(f"migration requires an Operator Kit V4 project, found {config['OPERATOR_KIT_VERSION']}")
        inventory = build_inventory(current.config_info, current.operator, current.raw)
        mapping = {
            "schemaVersion": MAPPING_VERSION,
            "sourceKitVersion": "4",
            "targetKitVersion": "5",
            "projectRoot": str(current.repo_path),
            "operatorDir": str(current.operator.path),
            "inventoryDigest": inventory["digest"],
            "selectedUnfinishedScopes": [],
            "reviewed": False,
            "reviewer": "",
            "reviewedAt": "",
        }
        return {"schemaVersion": PLAN_VERSION, "mode": "plan", "mutated": False,
                "sourceKitVersion": config["OPERATOR_KIT_VERSION"], "targetKitVersion": "5",
                "projectRoot": str(current.repo_path), "operatorDir": str(current.operator.path),
                "inventory": inventory, "mappingTemplate": mapping,
                "authorizationRequired": AUTHORIZATION,
                "notes": [
                    "V4 artifacts remain in place and are never reinterpreted as graph truth.",
                    "Selected scopes must already exist in a compatible graph provisioned through the trusted signed host/graph API.",
                    "Plan output performs no writes and provisions no graph state or keys.",
                ]}


def read_mapping(path: Path) -> tuple[dict[str, Any], bytes]:
    root: Optional[AnchoredRoot] = None
    try:
        raw, _info, root, _leaf = read_absolute_file(path, "migration mapping", 4 * 1024 * 1024)
        value = strict_json(raw, "migration mapping")
    finally:
        if root is not None:
            root.close()
    expected = {"schemaVersion", "sourceKitVersion", "targetKitVersion", "projectRoot", "operatorDir",
                "inventoryDigest", "selectedUnfinishedScopes", "reviewed", "reviewer", "reviewedAt"}
    value = require_object(value, expected, "migration mapping")
    if value["schemaVersion"] != MAPPING_VERSION or value["sourceKitVersion"] != "4" or value["targetKitVersion"] != "5":
        fail("migration mapping version is incompatible")
    project_root = require_string(value["projectRoot"], "migration mapping projectRoot")
    operator_dir = require_string(value["operatorDir"], "migration mapping operatorDir")
    if not Path(project_root).is_absolute() or not Path(operator_dir).is_absolute():
        fail("migration mapping projectRoot and operatorDir must be absolute paths")
    require_digest(value["inventoryDigest"], "migration mapping inventoryDigest")
    if value["reviewed"] is not True or not isinstance(value["reviewer"], str) or not value["reviewer"].strip():
        fail("migration mapping must record an explicit reviewer")
    if not isinstance(value["reviewedAt"], str) or not RFC3339.fullmatch(value["reviewedAt"]):
        fail("migration mapping reviewedAt must be an RFC3339 UTC timestamp")
    require_scopes(value["selectedUnfinishedScopes"])
    return value, raw


def validate_inventory_manifest(value: Any) -> dict[str, Any]:
    categories = {"config", "features", "tasks", "handoffs", "roadmap", "memory", "catalog"}
    inventory = require_object(value, categories, "migration manifest legacyInventory")
    for category in sorted(categories):
        entries = inventory[category]
        if type(entries) is not list:
            fail(f"migration manifest legacyInventory.{category} must be a list")
        seen: set[tuple[str, str]] = set()
        for index, raw_entry in enumerate(entries):
            label = f"migration manifest legacyInventory.{category}[{index}]"
            if type(raw_entry) is not dict:
                fail(f"{label} must be an object")
            entry_type = raw_entry.get("type")
            common = {"root", "path", "type", "mode"}
            expected = common | ({"bytes", "sha256"} if entry_type == "file" else set())
            entry = require_object(raw_entry, expected, label)
            root_name = require_string(entry["root"], f"{label}.root")
            artifact_path = require_string(entry["path"], f"{label}.path")
            if root_name not in {"project", "operator"}:
                fail(f"{label}.root is incompatible")
            if artifact_path.startswith("/") or any(part in {"", ".", ".."} for part in artifact_path.split("/")):
                fail(f"{label}.path is not a stable relative path")
            if entry_type not in {"file", "directory"}:
                fail(f"{label}.type is incompatible")
            if not isinstance(entry["mode"], str) or not FILE_MODE.fullmatch(entry["mode"]):
                fail(f"{label}.mode is not a canonical file mode")
            if entry_type == "file":
                if type(entry["bytes"]) is not int or entry["bytes"] < 0:
                    fail(f"{label}.bytes must be a nonnegative integer")
                require_digest(entry["sha256"], f"{label}.sha256")
            identity = (root_name, artifact_path)
            if identity in seen:
                fail(f"migration manifest legacyInventory.{category} contains a duplicate path")
            seen.add(identity)
    return inventory


def validate_manifest(value: Any) -> dict[str, Any]:
    expected = {
        "schemaVersion", "sourceKitVersion", "targetKitVersion", "projectRoot", "operatorDir",
        "appliedAt", "inventoryDigest", "legacyInventory", "sourceConfigSha256",
        "migratedConfigSha256", "review", "selectedUnfinishedScopes", "graph",
        "brokerReadiness", "preservation",
    }
    manifest = require_object(value, expected, "migration manifest")
    if (manifest["schemaVersion"] != MANIFEST_VERSION or manifest["sourceKitVersion"] != "4"
            or manifest["targetKitVersion"] != "5"):
        fail("migration manifest version is incompatible")
    for field in ("projectRoot", "operatorDir"):
        path = require_string(manifest[field], f"migration manifest {field}")
        if not Path(path).is_absolute():
            fail(f"migration manifest {field} must be an absolute path")
    if not isinstance(manifest["appliedAt"], str) or not RFC3339.fullmatch(manifest["appliedAt"]):
        fail("migration manifest appliedAt must be an RFC3339 UTC timestamp")
    for field in ("inventoryDigest", "sourceConfigSha256", "migratedConfigSha256"):
        require_digest(manifest[field], f"migration manifest {field}")
    validate_inventory_manifest(manifest["legacyInventory"])
    review = require_object(manifest["review"], {"reviewer", "reviewedAt", "mappingSha256"},
                            "migration manifest review")
    if not require_string(review["reviewer"], "migration manifest review.reviewer").strip():
        fail("migration manifest review.reviewer must not be blank")
    if not isinstance(review["reviewedAt"], str) or not RFC3339.fullmatch(review["reviewedAt"]):
        fail("migration manifest review.reviewedAt must be an RFC3339 UTC timestamp")
    require_digest(review["mappingSha256"], "migration manifest review.mappingSha256")
    require_scopes(manifest["selectedUnfinishedScopes"])
    graph = require_object(manifest["graph"], {"initialized", "graphId", "revision"},
                           "migration manifest graph")
    if type(graph["initialized"]) is not bool:
        fail("migration manifest graph.initialized must be boolean")
    if graph["initialized"]:
        require_string(graph["graphId"], "migration manifest graph.graphId")
        if type(graph["revision"]) is not int or graph["revision"] < 0:
            fail("migration manifest graph.revision must be a nonnegative integer")
    elif graph["graphId"] is not None or graph["revision"] is not None:
        fail("uninitialized migration manifest graph identity must be null")
    broker = require_object(manifest["brokerReadiness"],
                            {"broker", "keychainClient", "credentialVerified", "note"},
                            "migration manifest brokerReadiness")
    require_string(broker["broker"], "migration manifest brokerReadiness.broker")
    require_string(broker["keychainClient"], "migration manifest brokerReadiness.keychainClient")
    require_string(broker["note"], "migration manifest brokerReadiness.note")
    if broker["credentialVerified"] is not False:
        fail("migration manifest brokerReadiness.credentialVerified must be false")
    require_string(manifest["preservation"], "migration manifest preservation")
    return manifest


def read_manifest(operator: AnchoredRoot) -> tuple[dict[str, Any], os.stat_result]:
    raw, info = operator.read_file(("migrations", "v4-to-v5-manifest.json"),
                                   "V5 migration manifest", 64 * 1024 * 1024)
    return validate_manifest(strict_json(raw, "migration manifest")), info


def validate_selected_scopes(scopes: Sequence[str], graph: Mapping[str, Any]) -> None:
    if not scopes:
        return
    if not graph["initialized"]:
        fail("selected unfinished scopes require a graph provisioned through the trusted signed host/graph API")
    unknown = sorted(set(scopes) - set(graph["nodeStates"]))
    if unknown:
        fail("selected unfinished scopes are absent from the compatible graph: " + ", ".join(unknown))
    terminal = {"completed", "cancelled", "failed", "approved", "rejected"}
    finished = sorted(scope for scope in scopes if graph["nodeStates"][scope] in terminal)
    if finished:
        fail("selectedUnfinishedScopes contains terminal graph nodes: " + ", ".join(finished))


def graph_identity(graph: Mapping[str, Any]) -> dict[str, Any]:
    return {key: graph[key] for key in ("initialized", "graphId", "revision")}


def revalidate_graph(operator: AnchoredRoot, guard: MigrationGuardState,
                     expected: Mapping[str, Any], scopes: Sequence[str], boundary: str) -> dict[str, Any]:
    guard.assert_graph_owned(operator)
    current = graph_state(operator, guard.graph_runtime)
    if graph_identity(current) != dict(expected):
        fail(f"V5 graph identity or revision changed at the {boundary} boundary")
    validate_selected_scopes(scopes, current)
    return current


def require_exact_inventory(current: Mapping[str, Any], expected_digest: Any,
                            expected_categories: Optional[Any] = None) -> None:
    if current["digest"] != expected_digest:
        fail("legacy inventory changed after mapping review; create and review a new plan")
    if expected_categories is not None and current["categories"] != expected_categories:
        fail("legacy inventory no longer matches the durable migration manifest")


def apply(config_path: Path, mapping_path: Path, authorization: str, script_root: AnchoredRoot) -> dict[str, Any]:
    if authorization != AUTHORIZATION:
        fail(f"apply requires --authorize {AUTHORIZATION}")
    mapping, mapping_raw = read_mapping(mapping_path)
    mapping_sha256 = digest_bytes(mapping_raw)
    with context(config_path) as current:
        config = current.config
        operator = current.operator
        manifest_parts = ("migrations", "v4-to-v5-manifest.json")
        manifest_path = operator.path.joinpath(*manifest_parts)
        with migration_guard(config, operator, script_root) as guard:
            guard.assert_transaction_owned(config, operator)
            current.repo.verify_path()
            operator.verify_path()
            if current.reread_config() != current.raw:
                fail("operator config changed after migration context was opened")
            manifest_info = operator.stat_optional(manifest_parts)
            if config["OPERATOR_KIT_VERSION"] == "5" and manifest_info is not None:
                manifest, _info = read_manifest(operator)
                if (manifest.get("schemaVersion") != MANIFEST_VERSION
                        or manifest.get("projectRoot") != str(current.repo_path)
                        or manifest.get("operatorDir") != str(operator.path)):
                    fail("existing V5 migration manifest is incompatible")
                if manifest["review"]["mappingSha256"] != mapping_sha256:
                    fail("reviewed mapping does not match the completed migration manifest")
                return {"ok": True, "alreadyApplied": True, "version": "5", "manifest": str(manifest_path),
                        "inventoryDigest": manifest.get("inventoryDigest")}
            if config["OPERATOR_KIT_VERSION"] != "4":
                fail(f"apply requires OPERATOR_KIT_VERSION=4, found {config['OPERATOR_KIT_VERSION']}")
            if mapping["projectRoot"] != str(current.repo_path) or mapping["operatorDir"] != str(operator.path):
                fail("reviewed mapping belongs to a different project or OPERATOR_DIR")

            inventory = build_inventory(current.config_info, operator, current.raw)
            migrated = replace_version(current.raw)

            def rollback_marker() -> None:
                marker_raw, marker_info = current.repo.read_file(
                    (current.config_leaf,), "operator config marker rollback", 1024 * 1024)
                if marker_raw == current.raw:
                    return
                if marker_raw != migrated:
                    fail("operator config changed incompatibly before marker rollback")
                current.repo.atomic_replace(
                    (current.config_leaf,), current.raw,
                    stat.S_IMODE(current.config_info.st_mode) or 0o644,
                    "operator config marker rollback",
                    expected=(marker_info.st_dev, marker_info.st_ino))

            broker = broker_readiness(script_root)
            guard.assert_transaction_owned(config, operator)
            graph = graph_state(operator, guard.graph_runtime)
            scopes = mapping["selectedUnfinishedScopes"]
            validate_selected_scopes(scopes, graph)
            expected_graph = graph_identity(graph)

            if manifest_info is not None:
                partial, _partial_info = read_manifest(operator)
                if (partial.get("schemaVersion") != MANIFEST_VERSION
                        or partial.get("projectRoot") != str(current.repo_path)
                        or partial.get("operatorDir") != str(operator.path)
                        or partial.get("sourceConfigSha256") != digest_bytes(current.raw)
                        or partial.get("migratedConfigSha256") != digest_bytes(migrated)
                        or partial["review"]["mappingSha256"] != mapping_sha256
                        or partial.get("selectedUnfinishedScopes") != scopes
                        or partial.get("graph") != expected_graph):
                    fail("a partial migration manifest is incompatible with the reviewed mapping or current V4 config")
                require_exact_inventory(inventory, partial.get("inventoryDigest"), partial.get("legacyInventory"))
                if mapping["inventoryDigest"] != inventory["digest"]:
                    fail("partial migration mapping no longer matches the exact legacy inventory")
                # Recovery repeats every safety decision. In particular, the
                # selected scopes must still be known and nonterminal now.
                validate_selected_scopes(scopes, graph)
                guard.assert_transaction_owned(config, operator)
                refreshed = build_inventory(current.config_info, operator, current.raw)
                require_exact_inventory(refreshed, partial.get("inventoryDigest"), partial.get("legacyInventory"))
                if current.reread_config() != current.raw:
                    fail("operator config changed before partial migration recovery")
                current.repo.verify_path()
                operator.verify_path()
                revalidate_graph(operator, guard, partial["graph"], scopes, "partial marker commit")
                guard.assert_transaction_owned(config, operator)
                mode = stat.S_IMODE(current.config_info.st_mode) or 0o644
                guard.set_marker_rollback(rollback_marker)
                current.repo.atomic_replace((current.config_leaf,), migrated, mode, "operator config marker",
                                            expected=(current.config_info.st_dev, current.config_info.st_ino))
                guard.assert_transaction_owned(config, operator)
                return {"ok": True, "alreadyApplied": False, "recoveredPartialApply": True,
                        "version": "5", "manifest": str(manifest_path),
                        "inventoryDigest": partial.get("inventoryDigest")}

            require_exact_inventory(inventory, mapping["inventoryDigest"])
            applied_at = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
            manifest = {
                "schemaVersion": MANIFEST_VERSION,
                "sourceKitVersion": "4", "targetKitVersion": "5",
                "projectRoot": str(current.repo_path), "operatorDir": str(operator.path),
                "appliedAt": applied_at, "inventoryDigest": inventory["digest"],
                "legacyInventory": inventory["categories"],
                "sourceConfigSha256": digest_bytes(current.raw), "migratedConfigSha256": digest_bytes(migrated),
                "review": {"reviewer": mapping["reviewer"], "reviewedAt": mapping["reviewedAt"],
                           "mappingSha256": mapping_sha256},
                "selectedUnfinishedScopes": scopes,
                "graph": expected_graph,
                "brokerReadiness": broker,
                "preservation": "V4 artifacts remain in place at the recorded stable paths; they are not graph truth.",
            }
            guard.assert_transaction_owned(config, operator)
            refreshed = build_inventory(current.config_info, operator, current.raw)
            require_exact_inventory(refreshed, inventory["digest"], inventory["categories"])
            if current.reread_config() != current.raw:
                fail("operator config changed before migration commit")
            current.repo.verify_path()
            operator.verify_path()
            revalidate_graph(operator, guard, expected_graph, scopes, "manifest commit")
            guard.assert_transaction_owned(config, operator)
            # atomic_replace fsyncs the temporary file and containing directory.
            # Therefore the manifest rename is durable before the marker rename.
            operator.atomic_replace(manifest_parts, canonical(manifest), 0o600, "V5 migration manifest")
            guard.assert_transaction_owned(config, operator)
            after_manifest = build_inventory(current.config_info, operator, current.raw)
            require_exact_inventory(after_manifest, inventory["digest"], inventory["categories"])
            if current.reread_config() != current.raw:
                fail("operator config changed after durable manifest commit")
            current.repo.verify_path()
            operator.verify_path()
            revalidate_graph(operator, guard, expected_graph, scopes, "marker commit")
            guard.assert_transaction_owned(config, operator)
            guard.set_marker_rollback(rollback_marker)
            current.repo.atomic_replace((current.config_leaf,), migrated,
                                        stat.S_IMODE(current.config_info.st_mode) or 0o644,
                                        "operator config marker",
                                        expected=(current.config_info.st_dev, current.config_info.st_ino))
            guard.assert_transaction_owned(config, operator)
            return {"ok": True, "alreadyApplied": False, "version": "5", "manifest": str(manifest_path),
                    "inventoryDigest": inventory["digest"], "graphInitialized": graph["initialized"],
                    "selectedUnfinishedScopes": scopes}


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="operator-v5-migrate")
    root.add_argument("--config", required=True)
    sub = root.add_subparsers(dest="command", required=True)
    sub.add_parser("plan")
    apply_parser = sub.add_parser("apply")
    apply_parser.add_argument("--mapping", required=True)
    apply_parser.add_argument("--authorize", required=True)
    return root


def main() -> int:
    arguments = parser().parse_args()
    try:
        if arguments.command == "plan":
            value = plan(Path(arguments.config))
        else:
            script_root, script_leaf = AnchoredRoot.open_parent(Path(os.path.abspath(__file__)),
                                                                "migration runtime")
            try:
                script_root.read_file((script_leaf,), "migration runtime", 16 * 1024 * 1024)
                value = apply(Path(arguments.config), Path(arguments.mapping), arguments.authorize, script_root)
            finally:
                script_root.close()
        sys.stdout.buffer.write(canonical(value))
        return 0
    except (MigrationError, OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        sys.stderr.buffer.write(canonical({"ok": False, "error": {"code": "MIGRATION_REFUSED", "message": str(exc)}}))
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
