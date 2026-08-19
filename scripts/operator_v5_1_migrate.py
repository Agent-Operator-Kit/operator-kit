#!/usr/bin/env python3
"""Migrate Operator V4 or signed V5 state to the V5.1 local graph."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


AUTHORIZATION = "MIGRATE_TO_V5_1_LOCAL_GRAPH"
LOCAL_SCHEMA = "operator.local-dependency-graph/v1"
SECURE_DIRS = ("authority", "graph", "host", "loop")


class MigrationError(Exception):
    pass


def now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_version(config: Path) -> str:
    raw = config.read_text(encoding="utf-8")
    matches = re.findall(r'^OPERATOR_KIT_VERSION=["\']([^"\']+)["\']$', raw, re.MULTILINE)
    if len(matches) != 1:
        raise MigrationError("operator.config.env must contain exactly one quoted OPERATOR_KIT_VERSION")
    return matches[0]


def atomic_text(path: Path, value: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def write_json(path: Path, value: Any) -> None:
    atomic_text(path, json.dumps(value, indent=2, sort_keys=True) + "\n")


def feature_dirs(root: Path) -> list[Path]:
    result = []
    features = root / "features"
    if not features.is_dir():
        return result
    for path in sorted(features.iterdir()):
        if path.is_dir() and not path.name.startswith("_") and (path / "status.json").is_file():
            result.append(path)
    return result


def secure_material(root: Path) -> list[str]:
    material = []
    for name in SECURE_DIRS:
        path = root / name
        if path.exists() and any(path.iterdir()):
            material.append(name)
    return material


def plan(root: Path, config: Path) -> dict[str, Any]:
    version = read_version(config)
    features = feature_dirs(root)
    material = secure_material(root)
    return {
        "schemaVersion": "operator.v5-1-migration-plan/v1",
        "sourceVersion": version,
        "targetVersion": "5.1",
        "operatorDir": str(root),
        "featureGraphsToInitialize": [path.name for path in features if not (path / "graph.json").exists()],
        "signedRuntimeDirectoriesToArchive": material if version == "5" else [],
        "keychainAction": "none",
        "authorizationRequired": version != "5.1",
        "authorization": AUTHORIZATION,
        "notes": [
            "V5.1 graphs are local advisory dependency indexes scoped to feature sessions.",
            "Migration never reads, changes, or deletes macOS Keychain entries.",
            "Existing signed graph state is retained under OPERATOR_DIR/archive/signed-v5/.",
            "Dispatch, integration, push, and release remain explicit human/operator actions.",
        ],
    }


def replace_version(config: Path) -> None:
    raw = config.read_text(encoding="utf-8")
    updated, count = re.subn(
        r'^(OPERATOR_KIT_VERSION=)(["\'])([^"\']+)(["\'])$',
        lambda m: f'{m.group(1)}{m.group(2)}5.1{m.group(2)}',
        raw,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise MigrationError("could not update OPERATOR_KIT_VERSION")
    atomic_text(config, updated, 0o644)


def init_feature_graph(path: Path) -> bool:
    graph_path = path / "graph.json"
    if graph_path.exists():
        return False
    status = json.loads((path / "status.json").read_text(encoding="utf-8"))
    write_json(graph_path, {
        "schemaVersion": LOCAL_SCHEMA,
        "featureId": status["id"],
        "revision": 0,
        "updatedAt": now(),
        "nodes": [],
    })
    return True


def apply(root: Path, config: Path, authorization: str | None) -> dict[str, Any]:
    version = read_version(config)
    manifest_path = root / "migrations" / "to-v5.1-local-graph.json"
    if version == "5.1":
        if manifest_path.is_file():
            return {"ok": True, "alreadyApplied": True, "version": "5.1", "manifest": str(manifest_path)}
        raise MigrationError("project is already marked 5.1 but has no migration manifest")
    if version not in {"4", "5"}:
        raise MigrationError(f"migration supports Operator V4 or V5, found {version}")
    if authorization != AUTHORIZATION:
        raise MigrationError(f"apply requires --authorize {AUTHORIZATION}")

    archive_path = None
    archived = []
    if version == "5":
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        archive_path = root / "archive" / "signed-v5" / stamp
        archive_path.mkdir(parents=True, exist_ok=False, mode=0o700)
        for name in SECURE_DIRS:
            source = root / name
            if source.exists():
                destination = archive_path / name
                shutil.move(str(source), str(destination))
                archived.append(name)
        write_json(archive_path / "README.json", {
            "schemaVersion": "operator.signed-v5-archive/v1",
            "archivedAt": now(),
            "sourceVersion": "5",
            "sourceTag": "v5.0-signed-control-plane",
            "keychainEntriesModified": False,
            "restoreNote": "Use the source tag and this preserved state for a reviewed rollback; do not copy private keys into files.",
        })

    initialized = []
    for path in feature_dirs(root):
        if init_feature_graph(path):
            initialized.append(path.name)

    (root / "migrations").mkdir(parents=True, exist_ok=True, mode=0o700)
    manifest = {
        "schemaVersion": "operator.v5-1-migration-manifest/v1",
        "migratedAt": now(),
        "sourceVersion": version,
        "targetVersion": "5.1",
        "archive": str(archive_path) if archive_path else None,
        "archivedDirectories": archived,
        "initializedFeatureGraphs": initialized,
        "keychainEntriesModified": False,
    }
    write_json(manifest_path, manifest)
    replace_version(config)
    return {"ok": True, "alreadyApplied": False, "version": "5.1", "manifest": str(manifest_path), "archive": manifest["archive"], "initializedFeatureGraphs": initialized}


def main() -> int:
    parser = argparse.ArgumentParser(prog="operator-v5-1-migrate")
    parser.add_argument("--operator-dir", required=True)
    parser.add_argument("--config", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("plan")
    apply_parser = sub.add_parser("apply")
    apply_parser.add_argument("--authorize")
    args = parser.parse_args()
    root = Path(args.operator_dir).resolve()
    config = Path(args.config).resolve()
    result = plan(root, config) if args.command == "plan" else apply(root, config, args.authorize)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (MigrationError, OSError, json.JSONDecodeError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, sort_keys=True), file=sys.stderr)
        raise SystemExit(2)
