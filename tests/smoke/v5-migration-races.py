#!/usr/bin/env python3
"""Deterministic adversarial swaps inside one migration apply invocation."""

from __future__ import annotations

import importlib.util
import fcntl
import os
from pathlib import Path
import stat
import subprocess
import sys


def load(path: Path):
    spec = importlib.util.spec_from_file_location("operator_v5_migration_race_target", path)
    if spec is None or spec.loader is None:
        raise AssertionError("migration helper is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    if len(sys.argv) != 7:
        raise SystemExit("usage: races.py <mode> <helper> <config> <mapping> <script-dir> <operator-dir>")
    mode = sys.argv[1]
    helper, config, mapping, script_dir, operator_dir = map(Path, sys.argv[2:])
    module = load(helper)
    calls = 0
    restore = None
    guard_modes = {
        "guard-acquire-root", "guard-acquire-graph", "guard-acquire-lock",
        "guard-exit-root", "guard-exit-graph", "guard-exit-lock",
    }
    lock_replace_modes = {
        "migration-lock-replace", "writer-lock-replace",
        "migration-lock-exit-replace", "writer-lock-exit-replace",
    }
    if mode in lock_replace_modes:
        original_broker_readiness = module.broker_readiness
        original_load_graph_runtime = module.load_graph_runtime
        exit_phase = "-exit-" in mode
        migration_lock = mode.startswith("migration-lock-")

        def file_snapshot(path: Path):
            info = os.lstat(path)
            return ((info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_size,
                     info.st_mtime_ns, info.st_ctime_ns), path.read_bytes())

        def perform_lock_replacement():
            nonlocal calls, restore
            calls += 1
            if calls != 1:
                return
            if migration_lock:
                target = operator_dir / "migrations" / ".v4-to-v5.lock"
            else:
                target = operator_dir / "host" / "replacement-race-writer.lock"
            backup = target.with_name(target.name + ".held-real")
            original_snapshot = file_snapshot(target)
            os.rename(target, backup)
            held_snapshot = file_snapshot(backup)
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                                 stat.S_IMODE(original_snapshot[0][2]))
            try:
                os.write(descriptor, b"replacement decoy must remain unchanged\n")
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            decoy_snapshot = file_snapshot(target)

            if migration_lock:
                contender = subprocess.run([
                    "/usr/bin/python3", str(helper), "--config", str(config), "apply",
                    "--mapping", str(mapping), "--authorize", module.AUTHORIZATION,
                ], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                   timeout=15, check=False)
                if contender.returncode != 4 or b"MIGRATION_REFUSED" not in contender.stderr:
                    raise AssertionError("replacement migration lock admitted a concurrent migrator")
            else:
                contender = subprocess.run([
                    "/usr/bin/python3", "-c", """
import fcntl, os, sys
root, parent = sys.argv[1:]
flags = os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0)
descriptors = [os.open(root, flags), os.open(parent, flags)]
try:
    for descriptor in descriptors:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            continue
        else:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            raise SystemExit(9)
finally:
    for descriptor in descriptors:
        os.close(descriptor)
""", str(operator_dir), str(target.parent),
                ], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                   timeout=15, check=False)
                if contender.returncode != 0:
                    raise AssertionError("replacement writer acquired a transaction parent")

            def restore_lock():
                if file_snapshot(target) != decoy_snapshot:
                    raise AssertionError(f"{mode} decoy was mutated")
                if file_snapshot(backup) != held_snapshot:
                    raise AssertionError(f"{mode} held original lock was mutated")
                target.unlink()
                os.rename(backup, target)

            restore = restore_lock

        def wrapped_broker_readiness(*args, **kwargs):
            perform_lock_replacement()
            return original_broker_readiness(*args, **kwargs)

        if exit_phase:
            def wrapped_load_graph_runtime(*args, **kwargs):
                graph_runtime = original_load_graph_runtime(*args, **kwargs)
                original_exit = graph_runtime.DirectoryLock.__exit__

                def swapped_exit(lock, *exit_args):
                    perform_lock_replacement()
                    return original_exit(lock, *exit_args)

                graph_runtime.DirectoryLock.__exit__ = swapped_exit
                return graph_runtime

            module.load_graph_runtime = wrapped_load_graph_runtime
        else:
            module.broker_readiness = wrapped_broker_readiness
    elif mode in guard_modes:
        original_load_graph_runtime = module.load_graph_runtime
        phase = "acquire" if "-acquire-" in mode else "exit"
        target_kind = mode.rsplit("-", 1)[1]

        def perform_guard_swap():
            nonlocal calls, restore
            calls += 1
            if calls != 1:
                return
            suffix = f"guard-{phase}"
            if target_kind == "root":
                backup = operator_dir.with_name(operator_dir.name + f"-{suffix}-real")
                poison = operator_dir.with_name(operator_dir.name + f"-{suffix}-poison")
                poison.mkdir()
                sentinel = poison / "sentinel.txt"
                sentinel.write_text("root decoy must remain untouched\n", encoding="utf-8")
                os.rename(operator_dir, backup)
                os.rename(poison, operator_dir)
                sentinel = operator_dir / "sentinel.txt"

                def restore_root():
                    if sentinel.read_text(encoding="utf-8") != "root decoy must remain untouched\n":
                        raise AssertionError("root decoy sentinel was mutated")
                    if (operator_dir / "graph" / ".lock").exists():
                        raise AssertionError("root decoy received graph lock state")
                    sentinel.unlink()
                    os.rename(operator_dir, poison)
                    os.rename(backup, operator_dir)
                    poison.rmdir()
                    if (operator_dir / "graph" / ".lock").exists():
                        raise AssertionError("original root retained a stale production lock")

                restore = restore_root
            elif target_kind == "graph":
                target = operator_dir / "graph"
                backup = operator_dir / f"graph-{suffix}-real"
                poison = operator_dir / f"graph-{suffix}-poison"
                poison.mkdir()
                sentinel = poison / "sentinel.txt"
                sentinel.write_text("graph decoy must remain untouched\n", encoding="utf-8")
                os.rename(target, backup)
                os.rename(poison, target)
                sentinel = target / "sentinel.txt"

                def restore_graph():
                    if sentinel.read_text(encoding="utf-8") != "graph decoy must remain untouched\n":
                        raise AssertionError("graph decoy sentinel was mutated")
                    if (target / ".lock").exists() or (target / "owner.json").exists():
                        raise AssertionError("graph decoy received lock state")
                    sentinel.unlink()
                    os.rename(target, poison)
                    os.rename(backup, target)
                    poison.rmdir()
                    if (target / ".lock").exists():
                        raise AssertionError("original graph retained a stale production lock")

                restore = restore_graph
            else:
                target = operator_dir / "graph" / ".lock"
                backup = target.with_name(f".lock-{suffix}-real")
                os.rename(target, backup)
                target.mkdir()
                sentinel = target / "sentinel.txt"
                sentinel.write_text("lock decoy must remain untouched\n", encoding="utf-8")

                def restore_lock():
                    if sentinel.read_text(encoding="utf-8") != "lock decoy must remain untouched\n":
                        raise AssertionError("lock decoy sentinel was mutated")
                    if set(os.listdir(target)) != {"sentinel.txt"}:
                        raise AssertionError("lock decoy received owner or temporary state")
                    if backup.exists():
                        raise AssertionError("identity-bound production lock was left stale")
                    sentinel.unlink()
                    target.rmdir()

                restore = restore_lock

        def wrapped_load_graph_runtime(*args, **kwargs):
            graph_runtime = original_load_graph_runtime(*args, **kwargs)
            if phase == "acquire":
                original_write = graph_runtime.DirectoryLock._write_owner_anchored

                def swapped_write(lock):
                    perform_guard_swap()
                    return original_write(lock)

                graph_runtime.DirectoryLock._write_owner_anchored = swapped_write
            else:
                original_exit = graph_runtime.DirectoryLock.__exit__

                def swapped_exit(lock, *args):
                    perform_guard_swap()
                    return original_exit(lock, *args)

                graph_runtime.DirectoryLock.__exit__ = swapped_exit
            return graph_runtime

        module.load_graph_runtime = wrapped_load_graph_runtime
        if phase == "exit":
            def refuse_after_acquisition(*_args, **_kwargs):
                module.fail("injected refusal before anchored graph-lock release")

            module.broker_readiness = refuse_after_acquisition
    elif mode in {"root", "parent", "leaf"}:
        original_inventory = module.build_inventory

        def wrapped_inventory(*args, **kwargs):
            nonlocal calls, restore
            value = original_inventory(*args, **kwargs)
            calls += 1
            if calls != 1:
                return value
            if mode == "root":
                backup = operator_dir.with_name(operator_dir.name + "-race-real")
                poison = operator_dir.with_name(operator_dir.name + "-race-poison")
                poison.mkdir()
                os.rename(operator_dir, backup)
                os.symlink(poison, operator_dir)

                def restore_root():
                    operator_dir.unlink()
                    os.rename(backup, operator_dir)
                    poison.rmdir()

                restore = restore_root
            elif mode == "parent":
                target = operator_dir / "tasks" / "T-0001"
                backup = operator_dir / "tasks" / "T-0001-race-real"
                poison = operator_dir / "tasks" / "T-0001-race-poison"
                poison.mkdir()
                os.rename(target, backup)
                os.symlink(poison, target)

                def restore_parent():
                    target.unlink()
                    os.rename(backup, target)
                    poison.rmdir()

                restore = restore_parent
            else:
                target = operator_dir / "tasks" / "T-0001" / "task.md"
                backup = target.with_name("task.race-real.md")
                poison = target.with_name("task.race-poison.md")
                poison.write_text("poison\n", encoding="utf-8")
                os.rename(target, backup)
                os.symlink(poison, target)

                def restore_leaf():
                    target.unlink()
                    os.rename(backup, target)
                    poison.unlink()

                restore = restore_leaf
            return value

        module.build_inventory = wrapped_inventory
    elif mode in {"graph-create", "graph-revision", "graph-state"}:
        original_graph_state = module.graph_state

        def assert_graph_contender_blocked():
            contender = subprocess.run([
                "/usr/bin/python3", "-c", """
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location('graph_contender', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
lock = module.DirectoryLock(pathlib.Path(sys.argv[2]), timeout=0.0)
try:
    lock.__enter__()
except module.GraphError as exc:
    raise SystemExit(0 if exc.code == 'LOCK_TIMEOUT' else 8)
else:
    lock.__exit__(None, None, None)
    raise SystemExit(9)
""", str(script_dir / "operator_graph.py"), str(operator_dir / "graph" / ".lock"),
            ], check=False)
            if contender.returncode != 0:
                raise AssertionError("production graph lock admitted a concurrent transaction")

        def wrapped_graph_state(operator, graph_runtime):
            nonlocal calls, restore
            calls += 1
            if calls == 3:
                assert_graph_contender_blocked()
            if mode == "graph-revision":
                return {"initialized": True, "graphId": "race-graph",
                        "revision": 1 if calls <= 2 else 2, "nodeStates": {}}
            if mode == "graph-state":
                return {"initialized": True, "graphId": "race-graph", "revision": 1,
                        "nodeStates": {"legacy-task": "active" if calls <= 2 else "completed"}}
            value = original_graph_state(operator, graph_runtime)
            if calls == 1:
                owner = operator_dir / "graph" / ".lock" / "owner.json"
                if not owner.is_file():
                    raise AssertionError("migration did not hold the production graph lock")
                assert_graph_contender_blocked()
            if calls == 2:
                injected = operator_dir / "graph" / "definition.json"
                injected.write_text("{}\n", encoding="utf-8")

                def restore_graph_create():
                    injected.unlink(missing_ok=True)

                restore = restore_graph_create
            return value

        module.graph_state = wrapped_graph_state
    else:
        raise AssertionError(mode)
    refused = False
    partial_manifest_seen = False
    manifest = operator_dir / "migrations" / "v4-to-v5-manifest.json"
    partial_modes = {"graph-create", "graph-revision", "graph-state",
                     "migration-lock-exit-replace", "writer-lock-exit-replace"}
    try:
        script_root = module.AnchoredRoot.open_absolute(script_dir, "migration runtime")
        try:
            module.apply(config, mapping, module.AUTHORIZATION, script_root)
        finally:
            script_root.close()
    except module.MigrationError:
        refused = True
    finally:
        if mode in partial_modes:
            partial_manifest_seen = manifest.exists()
            if partial_manifest_seen:
                module.validate_manifest(module.strict_json(manifest.read_bytes(), "race partial manifest"))
            manifest.unlink(missing_ok=True)
        if restore is not None:
            restore()
    if not refused or calls < 1:
        raise AssertionError(f"{mode} race was not refused at a commit boundary")
    if 'OPERATOR_KIT_VERSION="4"' not in config.read_text(encoding="utf-8"):
        raise AssertionError(f"{mode} interchange changed the version marker")
    if mode in partial_modes:
        if not partial_manifest_seen:
            raise AssertionError(f"{mode} did not exercise the post-manifest marker boundary")
    elif manifest.exists():
        raise AssertionError(f"{mode} interchange committed a manifest")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
