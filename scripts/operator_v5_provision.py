#!/usr/bin/env python3
"""Provision an Operator V5 authority, actor bindings, and initial graph.

Private RSA material exists only in this control-plane process and the OS
keychain. The repository, OPERATOR_DIR, command line, environment, stdout, and
stderr receive public metadata only.
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
import re
import socket
import stat
import subprocess
import sys
import tempfile
import threading
from typing import Any, Mapping, Optional, Protocol, Sequence

import operator_graph as graph
import operator_v5_migrate as migration


AUTHORIZATION = "PROVISION_OPERATOR_V5_AUTHORITY"
AUTHORITY_SERVICE = "agent-operator-kit.authority-key"
PROOF_SERVICE = "agent-operator-kit.proof-key"
AUTHORITY_SECRET_VERSION = "operator.authority-private-key/v1"
PROOF_SECRET_VERSION = "operator.proof-key/v1"
RESULT_VERSION = "operator.v5-provision-result/v1"
PLAN_VERSION = "operator.v5-provision-plan/v1"
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+\-]*$")
BINDING_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]*$")
FORBIDDEN_LAUNCH_TOKENS = {
    "dangerously-" + "bypass-approvals-and-sandbox",
    "dangerously-" + "skip-permissions",
    "bypass" + "Permissions",
}


class ProvisionError(Exception):
    pass


def fail(message: str) -> None:
    raise ProvisionError(message)


def canonical(value: Any) -> bytes:
    return graph.canonical_bytes(value)


def valid_id(value: Any, maximum: int = 128) -> bool:
    return isinstance(value, str) and 1 <= len(value) <= maximum and ID_RE.fullmatch(value) is not None


def binding_slug(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-.")
    if not slug:
        slug = "binding"
    return slug[:80]


def format_time(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_config(config_path: Path) -> tuple[dict[str, str], bytes]:
    raw, info, parent, _leaf = migration.read_absolute_file(
        Path(os.path.abspath(os.path.expanduser(str(config_path)))), "operator config", 1024 * 1024
    )
    try:
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o022:
            fail("operator config must be owned by the current user and not group/world writable")
        values = migration.parse_config(raw)
    finally:
        parent.close()
    if values.get("OPERATOR_KIT_VERSION") != "5":
        fail("Operator V5 provisioning requires OPERATOR_KIT_VERSION=5")
    for name in ("PROJECT_NAME", "OPERATOR_DIR", "OPERATOR_LANES"):
        if not values.get(name):
            fail(f"operator config is missing {name}")
    if not Path(values["OPERATOR_DIR"]).is_absolute():
        fail("OPERATOR_DIR must be an absolute path for production provisioning")
    return values, raw


def read_role_map(operator: migration.AnchoredRoot) -> dict[str, Any]:
    raw, _info = operator.read_file(("catalog", "role-map.json"), "Operator V5 role map", 4 * 1024 * 1024)
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"Operator V5 role map is invalid JSON: {exc}")
    if not isinstance(value, dict) or value.get("kind") != "operator-role-map" or value.get("schemaVersion") != 1:
        fail("Operator V5 role map has an unsupported contract")
    lanes = value.get("durableLanes")
    runners = value.get("hostRunners")
    if not isinstance(lanes, list) or not lanes or not isinstance(runners, list):
        fail("Operator V5 role map must contain durable lanes and host runners")
    runner_ids = {
        item.get("id") for item in runners
        if isinstance(item, dict) and valid_id(item.get("id"))
    }
    lane_ids: set[str] = set()
    for lane in lanes:
        if not isinstance(lane, dict) or not valid_id(lane.get("id")):
            fail("Operator V5 role map contains an invalid durable lane")
        lane_id = lane["id"]
        if lane_id in lane_ids:
            fail(f"Operator V5 role map contains duplicate lane: {lane_id}")
        lane_ids.add(lane_id)
        if lane.get("hostRunnerId") not in runner_ids:
            fail(f"Operator V5 lane {lane_id} references an unknown host runner")
    if "operator" not in lane_ids:
        fail("Operator V5 role map must contain the operator lane")
    return value


def parse_config_lanes(raw: str) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    for number, line in enumerate(raw.splitlines(), start=1):
        if not line.strip():
            continue
        fields = line.split("|", 4)
        if len(fields) < 4:
            fail(f"OPERATOR_LANES line {number} is malformed")
        lane, owner, worktree, branch = fields[:4]
        invocation = fields[4] if len(fields) == 5 else ""
        if not valid_id(lane) or not owner or not worktree or not branch or lane in result:
            fail(f"OPERATOR_LANES line {number} is invalid or duplicated")
        result[lane] = {
            "owner": owner, "worktree": worktree, "branch": branch, "invocation": invocation,
        }
    if not result:
        fail("OPERATOR_LANES is empty")
    return result


def has_exact_option(tokens: Sequence[str], option: str, value: str) -> bool:
    positions = [index for index, token in enumerate(tokens) if token == option]
    return len(positions) == 1 and tokens[positions[0] + 1:positions[0] + 2] == [value]


def host_policy_issues(config: Mapping[str, str], role_map: Mapping[str, Any]) -> list[str]:
    lanes = parse_config_lanes(config["OPERATOR_LANES"])
    expected = {item["id"] for item in role_map["durableLanes"]}
    issues: list[str] = []
    if set(lanes) != expected:
        issues.append("role-map durable lanes do not match OPERATOR_LANES")
    for lane_id in sorted(set(lanes) & expected):
        record = lanes[lane_id]
        try:
            import shlex
            tokens = shlex.split(record["invocation"])
        except ValueError:
            tokens = []
        owner = record["owner"].lower()
        if "claude" in owner:
            if not tokens or Path(tokens[0]).name != "claude" or "--permission-mode" not in tokens:
                issues.append(f"lane {lane_id} lacks a fail-closed Claude invocation")
            elif not has_exact_option(tokens, "--permission-mode", "dontAsk"):
                issues.append(f"lane {lane_id} does not use Claude permission mode dontAsk")
        elif "codex" in owner:
            if not tokens or Path(tokens[0]).name != "codex" or "--sandbox" not in tokens:
                issues.append(f"lane {lane_id} lacks a restricted Codex invocation")
            elif not has_exact_option(tokens, "--sandbox", "workspace-write"):
                issues.append(f"lane {lane_id} does not use the Codex workspace-write sandbox")
        else:
            issues.append(f"lane {lane_id} has no supported Codex/Claude owner")
        if FORBIDDEN_LAUNCH_TOKENS.intersection(tokens):
            issues.append(f"lane {lane_id} contains a permission-bypass launch token")
    return sorted(set(issues))


class Keychain(Protocol):
    def get(self, service: str, account: str) -> Optional[bytes]: ...
    def put_if_absent(self, service: str, account: str, secret: bytes) -> bool: ...


class MacOSKeychain:
    """Generic-password storage through Security.framework, never argv."""

    ITEM_NOT_FOUND = -25300
    DUPLICATE_ITEM = -25299

    def __init__(self) -> None:
        if sys.platform != "darwin":
            fail("production provisioning currently requires macOS Keychain")
        try:
            self.security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
            self.core = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        except OSError as exc:
            fail(f"macOS Keychain framework is unavailable: {exc}")
        pointer = ctypes.c_void_p
        length = ctypes.c_uint32
        self.security.SecKeychainFindGenericPassword.argtypes = [
            pointer, length, ctypes.c_char_p, length, ctypes.c_char_p,
            ctypes.POINTER(length), ctypes.POINTER(pointer), ctypes.POINTER(pointer),
        ]
        self.security.SecKeychainFindGenericPassword.restype = ctypes.c_int32
        self.security.SecKeychainItemFreeContent.argtypes = [pointer, pointer]
        self.security.SecKeychainItemFreeContent.restype = ctypes.c_int32
        self.security.SecKeychainAddGenericPassword.argtypes = [
            pointer, length, ctypes.c_char_p, length, ctypes.c_char_p,
            length, pointer, ctypes.POINTER(pointer),
        ]
        self.security.SecKeychainAddGenericPassword.restype = ctypes.c_int32
        self.core.CFRelease.argtypes = [pointer]
        self.core.CFRelease.restype = None

    def get(self, service: str, account: str) -> Optional[bytes]:
        pointer = ctypes.c_void_p
        length = ctypes.c_uint32
        item = pointer()
        secret_pointer = pointer()
        secret_length = length()
        service_bytes = service.encode("utf-8")
        account_bytes = account.encode("utf-8")
        try:
            status = self.security.SecKeychainFindGenericPassword(
                None, len(service_bytes), service_bytes, len(account_bytes), account_bytes,
                ctypes.byref(secret_length), ctypes.byref(secret_pointer), ctypes.byref(item),
            )
            if status == self.ITEM_NOT_FOUND:
                return None
            if status != 0 or not secret_pointer.value or not 0 < secret_length.value <= 32768:
                fail(f"macOS Keychain lookup failed for public key id {account} (status {status})")
            return ctypes.string_at(secret_pointer, secret_length.value)
        finally:
            if secret_pointer.value:
                self.security.SecKeychainItemFreeContent(None, secret_pointer)
            if item.value:
                self.core.CFRelease(item)

    def put_if_absent(self, service: str, account: str, secret: bytes) -> bool:
        existing = self.get(service, account)
        if existing is not None:
            if existing != secret:
                fail(f"macOS Keychain already contains different material for public key id {account}")
            return False
        if not 0 < len(secret) <= 32768:
            fail("keychain secret exceeds the supported bound")
        service_bytes = service.encode("utf-8")
        account_bytes = account.encode("utf-8")
        buffer = ctypes.create_string_buffer(secret, len(secret))
        item = ctypes.c_void_p()
        try:
            status = self.security.SecKeychainAddGenericPassword(
                None, len(service_bytes), service_bytes, len(account_bytes), account_bytes,
                len(secret), ctypes.cast(buffer, ctypes.c_void_p), ctypes.byref(item),
            )
            if status == self.DUPLICATE_ITEM:
                existing = self.get(service, account)
                if existing != secret:
                    fail(f"macOS Keychain raced with different material for public key id {account}")
                return False
            if status != 0:
                fail(f"macOS Keychain write failed for public key id {account} (status {status})")
            if self.get(service, account) != secret:
                fail(f"macOS Keychain verification failed for public key id {account}")
            return True
        finally:
            if item.value:
                self.core.CFRelease(item)


def openssl_path() -> str:
    for candidate in ("/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    fail("a trusted OpenSSL executable is required for RSA key generation")


def parse_key_component(lines: Sequence[str], label: str) -> str:
    start = None
    for index, line in enumerate(lines):
        if line.strip() == f"{label}:":
            start = index + 1
            break
    if start is None:
        fail(f"OpenSSL did not return RSA {label}")
    parts: list[str] = []
    for line in lines[start:]:
        stripped = line.strip()
        if not line.startswith((" ", "\t")) or not re.fullmatch(r"[0-9a-fA-F:]+", stripped):
            break
        parts.append(stripped.replace(":", ""))
    value = "".join(parts).lower().lstrip("0") or "0"
    if not re.fullmatch(r"[0-9a-f]+", value):
        fail(f"OpenSSL returned an invalid RSA {label}")
    return value


def generate_rsa(bits: int) -> dict[str, Any]:
    executable = openssl_path()
    generated = subprocess.run(
        [executable, "genpkey", "-algorithm", "RSA", "-pkeyopt", f"rsa_keygen_bits:{bits}"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        timeout=180, check=False,
    )
    if generated.returncode != 0 or not generated.stdout:
        fail("OpenSSL RSA key generation failed")
    described = subprocess.run(
        [executable, "pkey", "-text", "-noout"], input=generated.stdout,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30, check=False,
    )
    if described.returncode != 0:
        fail("OpenSSL RSA key inspection failed")
    try:
        lines = described.stdout.decode("ascii").splitlines()
    except UnicodeDecodeError:
        fail("OpenSSL RSA key inspection returned non-ASCII output")
    modulus = parse_key_component(lines, "modulus")
    private_exponent = parse_key_component(lines, "privateExponent")
    exponent = None
    for line in lines:
        match = re.match(r"\s*publicExponent:\s*(\d+)", line)
        if match:
            exponent = int(match.group(1))
            break
    if exponent != 65537:
        fail("OpenSSL generated an unsupported RSA public exponent")
    n = int(modulus, 16)
    d = int(private_exponent, 16)
    if n.bit_length() < bits - 1 or not 1 < d < n:
        fail("OpenSSL generated invalid RSA parameters")
    return {"n": modulus, "d": private_exponent, "e": exponent}


def sign(payload: Mapping[str, Any], private_key: Mapping[str, Any]) -> str:
    modulus = int(str(private_key["n"]), 16)
    private_exponent = int(str(private_key["d"]), 16)
    digest = bytes.fromhex("3031300d060960864801650304020105000420") + hashlib.sha256(canonical(payload)).digest()
    width = (modulus.bit_length() + 7) // 8
    if width < len(digest) + 11:
        fail("RSA key is too small for RS256")
    encoded = b"\x00\x01" + b"\xff" * (width - len(digest) - 3) + b"\x00" + digest
    raw = pow(int.from_bytes(encoded, "big"), private_exponent, modulus).to_bytes(width, "big")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def decode_secret(raw: bytes, expected_version: str, key_id: str) -> dict[str, Any]:
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"keychain material for public key id {key_id} is malformed: {exc}")
    if not isinstance(value, dict) or set(value) != {"schemaVersion", "keyId", "n", "d"}:
        fail(f"keychain material for public key id {key_id} has invalid fields")
    if value.get("schemaVersion") != expected_version or value.get("keyId") != key_id:
        fail(f"keychain material for public key id {key_id} has the wrong identity")
    try:
        n = int(value["n"], 16)
        d = int(value["d"], 16)
    except (TypeError, ValueError):
        fail(f"keychain material for public key id {key_id} has invalid RSA parameters")
    if not 1024 <= n.bit_length() <= 8192 or not 1 < d < n:
        fail(f"keychain material for public key id {key_id} has unsafe RSA parameters")
    return value


def obtain_key(keychain: Keychain, service: str, key_id: str, version: str, bits: int) -> tuple[dict[str, Any], bool]:
    existing = keychain.get(service, key_id)
    if existing is not None:
        value = decode_secret(existing, version, key_id)
        created = False
    else:
        generated = generate_rsa(bits)
        envelope = {
            "schemaVersion": version, "keyId": key_id,
            "n": generated["n"], "d": generated["d"],
        }
        encoded = canonical(envelope)
        created = keychain.put_if_absent(service, key_id, encoded)
        value = decode_secret(keychain.get(service, key_id) or b"", version, key_id)
    if int(value["n"], 16).bit_length() < bits - 1:
        fail(f"keychain material for public key id {key_id} is below the required strength")
    probe = {"schemaVersion": "operator.key-pair-probe/v1", "keyId": key_id}
    graph.verify_rsa_signature(probe, sign(probe, value), value["n"], 65537,
                               "PROVISION_REFUSED", "Keychain key-pair probe")
    return value, created


def workspace_tag(config: Mapping[str, str], graph_id: str) -> str:
    payload = {
        "projectId": config["PROJECT_NAME"], "graphId": graph_id,
        "operatorDir": str(Path(config["OPERATOR_DIR"]).resolve()),
        "canonicalHostId": graph.HOST_ID,
    }
    return hashlib.sha256(canonical(payload)).hexdigest()[:16]


def public_anchor(config: Mapping[str, str], graph_id: str, key_id: str,
                  private_key: Mapping[str, Any]) -> dict[str, Any]:
    value = {
        "schemaVersion": graph.AUTHORITY_VERSION,
        "projectId": config["PROJECT_NAME"], "graphId": graph_id,
        "keyId": key_id, "canonicalHostId": graph.HOST_ID,
        "algorithm": "RS256", "publicKey": {"n": private_key["n"], "e": 65537},
    }
    return graph.validate_authority(value)


def binding_contract(binding_id: str, subject: Mapping[str, Any], capabilities: Sequence[str],
                     scopes: Sequence[Mapping[str, str]], config: Mapping[str, str], graph_id: str,
                     proof_key_id: str, proof_key: Mapping[str, Any], authority: Mapping[str, Any],
                     authority_key: Mapping[str, Any], issued: dt.datetime, expires: dt.datetime) -> dict[str, Any]:
    payload = {
        "schemaVersion": graph.BINDING_VERSION, "bindingId": binding_id, "generation": 1,
        "projectId": config["PROJECT_NAME"], "graphId": graph_id,
        "issuedAt": format_time(issued), "expiresAt": format_time(expires),
        "subject": dict(subject), "capabilities": sorted(set(capabilities)),
        "leaseScopes": [dict(item) for item in scopes],
        "proofKey": {"keyId": proof_key_id, "algorithm": "RS256",
                     "publicKey": {"n": proof_key["n"], "e": 65537}},
    }
    payload["signature"] = {
        "keyId": authority["keyId"], "algorithm": "RS256",
        "value": sign(payload, authority_key),
    }
    graph.validate_binding(payload, binding_id, authority)
    return payload


def binding_specs(role_map: Mapping[str, Any]) -> list[dict[str, Any]]:
    specs = [
        {"bindingId": "control", "subject": {"type": "operator", "id": "control"},
         "capabilities": ["graph-init", "graph-replace", "lease-resolve", "replay-repair", "sweep", "transition"],
         "leaseScopes": []},
        {"bindingId": "human", "subject": {"type": "human", "id": "authorized-human"},
         "capabilities": ["gate-decision", "lease-resolve"], "leaseScopes": []},
    ]
    seen = {"control", "human"}
    for lane in sorted(role_map["durableLanes"], key=lambda item: item["id"]):
        lane_id = lane["id"]
        suffix = hashlib.sha256(lane_id.encode("utf-8")).hexdigest()[:8]
        binding_id = f"host-{binding_slug(lane_id)}-{suffix}"
        if binding_id in seen or not BINDING_RE.fullmatch(binding_id):
            fail(f"cannot derive a unique binding ID for lane {lane_id}")
        seen.add(binding_id)
        specs.append({
            "bindingId": binding_id,
            "subject": {"type": "host", "id": f"host:{lane_id}", "hostRunnerId": lane["hostRunnerId"]},
            "capabilities": ["lease", "transition"],
            "leaseScopes": [{"scope": f"lane:{lane_id}", "laneNodeId": lane_id}],
        })
    return specs


def initial_definition(graph_id: str, role_map: Mapping[str, Any]) -> dict[str, Any]:
    lane_nodes = [{
        "id": lane["id"], "kind": "lane", "title": f"{lane['id']} lane",
        "metadata": {"hostRunnerId": lane["hostRunnerId"],
                     "roleTemplateIds": sorted(lane.get("roleTemplateIds", []))},
    } for lane in role_map["durableLanes"]]
    reserved = {node["id"] for node in lane_nodes}
    goal_id = "operator-control"
    task_id = "operator-bootstrap"
    if goal_id in reserved or task_id in reserved:
        fail("durable lane IDs collide with reserved bootstrap graph nodes")
    value = {
        "schemaVersion": graph.GRAPH_VERSION, "graphId": graph_id,
        "nodes": [
            {"id": goal_id, "kind": "goal", "title": "Operator trusted execution", "priority": 1000,
             "metadata": {"provisioned": True}},
            *lane_nodes,
            {"id": task_id, "kind": "task", "title": "Operator trusted host bootstrap", "priority": 1000,
             "metadata": {"execution": {"idempotent": True, "reclaimable": True}}},
        ],
        "edges": [
            {"kind": "contains", "from": goal_id, "to": task_id},
            {"kind": "assigned-to", "from": task_id, "to": "operator"},
        ],
    }
    return graph.validate_definition(value, materialized=False)


def ensure_public_file(operator: migration.AnchoredRoot, parts: Sequence[str], value: Mapping[str, Any], label: str) -> bool:
    expected = canonical(value)
    existing = operator.stat_optional(parts)
    if existing is not None:
        raw, _info = operator.read_file(parts, label, 8 * 1024 * 1024)
        if raw != expected:
            fail(f"{label} already exists with different content")
        return False
    operator.atomic_replace(parts, expected, 0o600, label)
    return True


def read_wire_record(channel: socket.socket, maximum: int) -> Mapping[str, Any]:
    data = bytearray()
    while not data.endswith(b"\n"):
        chunk = channel.recv(min(65536, maximum + 1 - len(data)))
        if not chunk:
            fail("bootstrap proof channel closed before a complete record")
        data.extend(chunk)
        if len(data) > maximum:
            fail("bootstrap proof challenge exceeds its bound")
    if b"\n" in data[:-1]:
        fail("bootstrap proof channel received multiple records in one phase")
    try:
        value = json.loads(bytes(data).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"bootstrap proof challenge is malformed: {exc}")
    if canonical(value) != bytes(data) or not isinstance(value, dict):
        fail("bootstrap proof challenge is not canonical")
    return value


def bootstrap_broker(channel: socket.socket, binding: Mapping[str, Any], proof_key: Mapping[str, Any],
                     definition: Mapping[str, Any], request_id: str) -> None:
    channel.settimeout(15)
    materialized = dict(definition)
    materialized["definitionRevision"] = 1
    materialized = graph.validate_definition(materialized, materialized=True)
    expected_intent = {"definitionHash": graph.definition_hash(materialized)}
    expected_authorization: Optional[Mapping[str, Any]] = None
    try:
        first = read_wire_record(channel, graph.MAX_PROOF_AUTH_CHALLENGE_BYTES)
        if set(first) != {"schemaVersion", "operation", "phase", "proofKeyId", "payload"}:
            fail("bootstrap authorize challenge fields are invalid")
        authorization = first["payload"]
        graph.validate_authorization_payload(authorization, "AUTHORITY_DENIED")
        expected_authorization = graph.authorization_payload("init", binding, request_id, expected_intent, None)
        if (first.get("schemaVersion") != graph.PROOF_CHALLENGE_VERSION or first.get("operation") != "sign"
                or first.get("phase") != "authorize" or first.get("proofKeyId") != binding["proofKey"]["keyId"]
                or authorization != expected_authorization):
            fail("bootstrap authorize challenge crosses the approved initialization scope")
        channel.sendall(canonical({
            "schemaVersion": graph.PROOF_RESPONSE_VERSION, "phase": "authorize",
            "proofKeyId": binding["proofKey"]["keyId"], "signature": sign(authorization, proof_key),
        }))

        second = read_wire_record(channel, graph.MAX_PROOF_EVENT_CHALLENGE_BYTES)
        if set(second) != {"schemaVersion", "operation", "phase", "proofKeyId", "payload"}:
            fail("bootstrap event challenge fields are invalid")
        event_payload = second.get("payload")
        if (second.get("schemaVersion") != graph.PROOF_CHALLENGE_VERSION or second.get("operation") != "sign"
                or second.get("phase") != "event" or second.get("proofKeyId") != binding["proofKey"]["keyId"]
                or not isinstance(event_payload, dict)
                or set(event_payload) != {"schemaVersion", "event"}
                or event_payload.get("schemaVersion") != graph.PROOF_EVENT_VERSION):
            fail("bootstrap event challenge crosses the approved initialization scope")
        event = event_payload["event"]
        expected_fields = {"schemaVersion", "sequence", "eventId", "requestId", "requestFingerprint",
                           "occurredAt", "clock", "actor", "type", "intent", "expectedRevision", "data", "result"}
        if (not isinstance(event, dict) or set(event) != expected_fields
                or event.get("schemaVersion") != graph.EVENT_VERSION or event.get("sequence") != 1
                or event.get("requestId") != request_id or event.get("type") != "graph.initialized"
                or event.get("intent") != expected_intent or event.get("expectedRevision") is not None
                or event.get("actor") != graph.actor_record(binding)
                or event.get("requestFingerprint") != graph.sha256_value(expected_authorization)
                or event.get("data") != {"definition": materialized}):
            fail("bootstrap event challenge is not the exact approved graph initialization")
        result = event.get("result")
        if (not isinstance(result, dict) or result.get("ok") is not True or result.get("command") != "init"
                or result.get("requestId") != request_id or result.get("revision") != 1):
            fail("bootstrap event result is invalid")
        if channel.recv(1) != b"":
            fail("bootstrap proof channel received data after the event request")
        channel.sendall(canonical({
            "schemaVersion": graph.PROOF_RESPONSE_VERSION, "phase": "event",
            "proofKeyId": binding["proofKey"]["keyId"], "signature": sign(event_payload, proof_key),
        }))
        channel.shutdown(socket.SHUT_WR)
    finally:
        channel.close()


def graph_state(operator: migration.AnchoredRoot) -> str:
    paths = [
        ("graph", "definition.json"), ("graph", "projection.json"), ("graph", "events.jsonl"),
    ]
    present = [operator.stat_optional(path) is not None for path in paths]
    if not any(present):
        return "absent"
    if not all(present):
        return "partial"
    return "initialized"


def initialize_graph(script_dir: Path, operator_dir: Path, definition: Mapping[str, Any],
                     binding: Mapping[str, Any], proof_key: Mapping[str, Any], request_id: str) -> Mapping[str, Any]:
    graph_script = script_dir / "operator-graph.sh"
    if not graph_script.is_file() or not os.access(graph_script, os.X_OK):
        fail("Operator graph runtime is unavailable")
    broker_end, graph_end = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    errors: list[BaseException] = []

    def broker_target() -> None:
        try:
            bootstrap_broker(broker_end, binding, proof_key, definition, request_id)
        except BaseException as exc:
            errors.append(exc)
            with contextlib.suppress(OSError):
                broker_end.close()

    worker = threading.Thread(target=broker_target, name="operator-v5-bootstrap-broker", daemon=True)
    worker.start()
    try:
        with tempfile.NamedTemporaryFile(prefix="operator-v5-definition-", suffix=".json", mode="wb", delete=False) as handle:
            definition_path = Path(handle.name)
            os.fchmod(handle.fileno(), 0o600)
            handle.write(canonical(definition))
            handle.flush()
            os.fsync(handle.fileno())
        environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "LC_ALL": "C", "LANG": "C", "OPERATOR_DIR": str(operator_dir),
        }
        process = subprocess.run(
            [str(graph_script), "init", "--definition", str(definition_path),
             "--request-id", request_id, "--actor-binding", binding["bindingId"],
             "--proof-fd", str(graph_end.fileno())],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment, pass_fds=(graph_end.fileno(),), timeout=60, check=False,
        )
    finally:
        with contextlib.suppress(OSError):
            graph_end.close()
        with contextlib.suppress(NameError, OSError):
            definition_path.unlink()
    worker.join(timeout=20)
    if worker.is_alive():
        fail("bootstrap proof broker did not terminate")
    if errors:
        fail(f"bootstrap proof broker refused initialization: {errors[0]}")
    if process.returncode != 0:
        diagnostic = process.stderr[:4096].decode("utf-8", errors="replace").strip()
        fail(f"signed graph initialization failed: {diagnostic or process.returncode}")
    try:
        result = json.loads(process.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"signed graph initialization returned invalid JSON: {exc}")
    if not isinstance(result, dict) or result.get("ok") is not True or result.get("command") != "init":
        fail("signed graph initialization returned an invalid result")
    return result


def validate_initialized_graph(script_dir: Path, operator_dir: Path, graph_id: str) -> Mapping[str, Any]:
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        "LC_ALL": "C", "LANG": "C", "OPERATOR_DIR": str(operator_dir),
    }
    outputs: dict[str, Any] = {}
    for name, arguments in (("status", ["status"]), ("replay", ["replay", "check"])):
        completed = subprocess.run(
            [str(script_dir / "operator-graph.sh"), *arguments], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, timeout=45, check=False,
        )
        if completed.returncode != 0:
            diagnostic = completed.stderr[:4096].decode("utf-8", errors="replace").strip()
            fail(f"graph {name} validation failed: {diagnostic or completed.returncode}")
        try:
            outputs[name] = json.loads(completed.stdout.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            fail(f"graph {name} validation returned invalid JSON: {exc}")
    status = outputs["status"]
    if status.get("data", {}).get("graphId") != graph_id:
        fail("initialized graph identity does not match the provisioned graph")
    return {"status": status, "replay": outputs["replay"]}


def validate_provisioned_origin(operator: migration.AnchoredRoot, definition: Mapping[str, Any],
                                binding: Mapping[str, Any], request_id: str) -> None:
    raw, _info = operator.read_file(
        ("graph", "events.jsonl"), "Operator V5 graph journal",
        graph.MAX_JOURNAL_BYTES + graph.MAX_EVENT_BYTES,
    )
    first_line = raw.splitlines(keepends=True)[:1]
    if not first_line or not first_line[0].endswith(b"\n") or len(first_line[0]) > graph.MAX_EVENT_BYTES:
        fail("initialized graph has no valid first journal event")
    try:
        event = json.loads(first_line[0].decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"initialized graph first event is malformed: {exc}")
    materialized = dict(definition)
    materialized["definitionRevision"] = 1
    materialized = graph.validate_definition(materialized, materialized=True)
    intent = {"definitionHash": graph.definition_hash(materialized)}
    authorization = graph.authorization_payload("init", binding, request_id, intent, None)
    if (not isinstance(event, dict)
            or event.get("schemaVersion") != graph.EVENT_VERSION
            or event.get("sequence") != 1
            or event.get("requestId") != request_id
            or event.get("requestFingerprint") != graph.sha256_value(authorization)
            or event.get("type") != "graph.initialized"
            or event.get("actor") != graph.actor_record(binding)
            or event.get("intent") != intent
            or event.get("expectedRevision") is not None
            or event.get("data") != {"definition": materialized}):
        fail("initialized graph did not originate from this provisioner's signed bootstrap contract")


def plan(config_path: Path, graph_override: Optional[str]) -> dict[str, Any]:
    config, _raw = read_config(config_path)
    graph_id = graph_override or f"{config['PROJECT_NAME']}-control"
    if not valid_id(graph_id):
        fail("graph ID is invalid")
    operator_path = Path(config["OPERATOR_DIR"])
    with migration.AnchoredRoot.open_absolute(operator_path, "OPERATOR_DIR") as operator:
        role_map = read_role_map(operator)
        state = graph_state(operator)
        authority_present = operator.stat_optional(("authority", "control-graph-public-key.json")) is not None
        bindings: list[str] = []
        binding_info = operator.stat_optional(("graph", "bindings"))
        if binding_info is not None:
            binding_dir = operator.open_dir(("graph", "bindings"))
            try:
                bindings = sorted(name for name in os.listdir(binding_dir) if name.endswith(".json"))
            finally:
                os.close(binding_dir)
    issues = host_policy_issues(config, role_map)
    return {
        "schemaVersion": PLAN_VERSION, "ok": True,
        "projectId": config["PROJECT_NAME"], "graphId": graph_id,
        "canonicalHostId": graph.HOST_ID, "operatorDir": str(operator_path.resolve()),
        "graphState": state, "authorityPresent": authority_present,
        "bindingCount": len(bindings), "plannedBindingCount": len(binding_specs(role_map)),
        "durableLanes": sorted(item["id"] for item in role_map["durableLanes"]),
        "hostPolicyReady": not issues, "hostPolicyIssues": issues,
        "keychainProvider": "macOS Security.framework" if sys.platform == "darwin" else "unavailable",
        "writes": ["OS keychain private authority/proof entries", "public authority anchor",
                   "signed actor bindings", "one signed initial graph event"],
    }


def apply(config_path: Path, graph_override: Optional[str], valid_days: int,
          authorization: str, keychain: Optional[Keychain] = None) -> dict[str, Any]:
    if authorization != AUTHORIZATION:
        fail(f"provisioning requires --authorize {AUTHORIZATION}")
    if not 1 <= valid_days <= 3650:
        fail("binding validity must be between 1 and 3650 days")
    config, _raw = read_config(config_path)
    graph_id = graph_override or f"{config['PROJECT_NAME']}-control"
    if not valid_id(config["PROJECT_NAME"]) or not valid_id(graph_id):
        fail("project or graph ID is invalid")
    operator_path = Path(config["OPERATOR_DIR"])
    script_dir = Path(__file__).resolve().parent
    provider = keychain or MacOSKeychain()
    created_keychain: list[str] = []
    created_files: list[str] = []

    with migration.AnchoredRoot.open_absolute(operator_path, "OPERATOR_DIR") as operator:
        try:
            fcntl.flock(operator.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail("OPERATOR_DIR is owned by another active control-plane writer")
        try:
            role_map = read_role_map(operator)
            issues = host_policy_issues(config, role_map)
            if issues:
                fail("trusted host policy is not ready: " + "; ".join(issues))
            state = graph_state(operator)
            if state == "partial":
                fail("partial graph state exists; recover it before provisioning")
            for parts in (("authority",), ("graph",), ("graph", "bindings")):
                descriptor = operator.open_dir(parts, create=True, mode=0o700)
                os.close(descriptor)

            tag = workspace_tag(config, graph_id)
            authority_key_id = f"authority-{tag}-1"
            authority_key, authority_created = obtain_key(
                provider, AUTHORITY_SERVICE, authority_key_id, AUTHORITY_SECRET_VERSION, 3072
            )
            if authority_created:
                created_keychain.append(authority_key_id)
            authority = public_anchor(config, graph_id, authority_key_id, authority_key)
            if ensure_public_file(operator, ("authority", "control-graph-public-key.json"), authority,
                                  "authority trust anchor"):
                created_files.append("authority/control-graph-public-key.json")

            now = dt.datetime.now(dt.timezone.utc)
            issued = now - dt.timedelta(minutes=1)
            expires = now + dt.timedelta(days=valid_days)
            bindings: dict[str, dict[str, Any]] = {}
            proof_keys: dict[str, dict[str, Any]] = {}
            for spec in binding_specs(role_map):
                binding_id = spec["bindingId"]
                proof_key_id = f"proof-{tag}-{binding_slug(binding_id)}-1"
                if len(proof_key_id) > 128:
                    proof_key_id = f"proof-{tag}-{hashlib.sha256(binding_id.encode()).hexdigest()[:16]}-1"
                proof_key, proof_created = obtain_key(
                    provider, PROOF_SERVICE, proof_key_id, PROOF_SECRET_VERSION, 2048
                )
                if proof_created:
                    created_keychain.append(proof_key_id)
                path = ("graph", "bindings", f"{binding_id}.json")
                existing = operator.stat_optional(path)
                if existing is not None:
                    raw, _info = operator.read_file(path, f"actor binding {binding_id}", graph.MAX_BINDING_BYTES)
                    try:
                        candidate = json.loads(raw.decode("utf-8"))
                    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                        fail(f"actor binding {binding_id} is malformed: {exc}")
                    binding = graph.validate_binding(candidate, binding_id, authority)
                    if not (graph.parse_time(binding["issuedAt"], "AUTHORITY_DENIED") <= now
                            < graph.parse_time(binding["expiresAt"], "AUTHORITY_DENIED")):
                        fail(f"actor binding {binding_id} is expired or not yet valid; rotate it before provisioning")
                    expected_identity = {
                        "subject": spec["subject"], "capabilities": sorted(spec["capabilities"]),
                        "leaseScopes": spec["leaseScopes"], "proofKeyId": proof_key_id,
                    }
                    actual_identity = {
                        "subject": binding["subject"], "capabilities": binding["capabilities"],
                        "leaseScopes": binding["leaseScopes"], "proofKeyId": binding["proofKey"]["keyId"],
                    }
                    if actual_identity != expected_identity or binding["proofKey"]["publicKey"]["n"] != proof_key["n"]:
                        fail(f"actor binding {binding_id} conflicts with the provisioned policy")
                else:
                    binding = binding_contract(
                        binding_id, spec["subject"], spec["capabilities"], spec["leaseScopes"],
                        config, graph_id, proof_key_id, proof_key, authority, authority_key, issued, expires,
                    )
                    if ensure_public_file(operator, path, binding, f"actor binding {binding_id}"):
                        created_files.append("/".join(path))
                    binding = graph.validate_binding(binding, binding_id, authority)
                bindings[binding_id] = binding
                proof_keys[binding_id] = proof_key

            definition = initial_definition(graph_id, role_map)
            request_id = f"provision-{tag}-init-v1"
            if state == "absent":
                initialize_graph(script_dir, operator_path, definition, bindings["control"],
                                 proof_keys["control"], request_id)
            validated = validate_initialized_graph(script_dir, operator_path, graph_id)
            validate_provisioned_origin(operator, definition, bindings["control"], request_id)
            data = validated["status"]["data"]
            return {
                "schemaVersion": RESULT_VERSION, "ok": True,
                "projectId": config["PROJECT_NAME"], "graphId": graph_id,
                "canonicalHostId": graph.HOST_ID, "authorityKeyId": authority_key_id,
                "revision": data["revision"], "eventCount": data["eventCount"],
                "bindingIds": sorted(bindings), "bootstrapScope": "operator-bootstrap",
                "createdKeychainEntries": created_keychain, "createdPublicFiles": created_files,
                "alreadyInitialized": state == "initialized",
                "hostPolicyReady": True, "replayValid": True,
            }
        finally:
            with contextlib.suppress(OSError):
                fcntl.flock(operator.fd, fcntl.LOCK_UN)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="operator-v5-provision")
    root.add_argument("--config", required=True)
    sub = root.add_subparsers(dest="command", required=True)
    plan_parser = sub.add_parser("plan")
    plan_parser.add_argument("--graph-id")
    apply_parser = sub.add_parser("apply")
    apply_parser.add_argument("--graph-id")
    apply_parser.add_argument("--valid-days", type=int, default=365)
    apply_parser.add_argument("--authorize", required=True)
    return root


def main() -> int:
    arguments = parser().parse_args()
    try:
        if arguments.command == "plan":
            value = plan(Path(arguments.config), arguments.graph_id)
        else:
            value = apply(Path(arguments.config), arguments.graph_id, arguments.valid_days,
                          arguments.authorize)
        sys.stdout.buffer.write(canonical(value))
        return 0
    except (ProvisionError, migration.MigrationError, graph.GraphError, OSError, ValueError,
            TypeError, subprocess.SubprocessError) as exc:
        message = getattr(exc, "message", str(exc))
        sys.stderr.buffer.write(canonical({
            "ok": False, "error": {"code": "PROVISION_REFUSED", "message": message},
        }))
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
