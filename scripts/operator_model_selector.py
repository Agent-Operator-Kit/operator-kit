#!/usr/bin/env python3
"""Deterministic, provider-neutral Operator model selection.

This runtime is advisory only. It reads explicit task, catalog, policy, and
outcome documents; it never dispatches work or mutates Operator state.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import shlex
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = "operator.model-selection/v1"
ALGORITHM_VERSION = "operator.model-selector/v1"
REPLAY_VERSION = "operator.model-selection-replay/v1"
SUGGESTION_VERSION = "operator.model-selection-suggestion/v1"
SUGGESTION_ALGORITHM_VERSION = "operator.model-policy-suggestion/v1"
MINIMUM_SUGGESTION_OUTCOMES = 3
TIE_BREAK_ORDER = [
    "expectedTotalTokens",
    "continuity",
    "latencyMs",
    "costMicrounits",
    "candidateId",
]
REQUIRED_ESTIMATE_FIELDS = [
    "qualityBps",
    "confidenceBps",
    "firstAttemptTokens",
    "retryProbabilityBps",
    "retryTokens",
    "escalationProbabilityBps",
    "escalationTokens",
    "latencyMs",
    "costMicrounits",
]
HARD_CONSTRAINT_FIELDS = [
    "availability",
    "capabilities",
    "tools",
    "modalities",
    "context",
    "dataClasses",
    "lane",
    "host",
    "riskFloor",
    "qualityFloor",
    "userOverride",
    "budgets",
]
MAX_DOCUMENT_BYTES = 4 * 1024 * 1024
MAX_JSONL_RECORDS = 10000
ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+\-]*$")
DIGEST_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")

EXIT_OK = 0
EXIT_INVALID = 2
EXIT_NO_RECOMMENDATION = 3


class SelectorError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


class SelectorArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise SelectorError("USAGE", message)


def fail(condition: bool, code: str, message: str) -> None:
    if not condition:
        raise SelectorError(code, message)


def reject_float(value: str) -> None:
    raise ValueError(f"floating-point JSON number is not supported: {value}")


def reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number is not supported: {value}")


def strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def parse_json_text(text: str, label: str) -> Any:
    try:
        return json.loads(
            text,
            object_pairs_hook=strict_object,
            parse_float=reject_float,
            parse_constant=reject_constant,
        )
    except (json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise SelectorError("INVALID_JSON", f"{label}: {exc}") from exc


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        size = path.stat().st_size
        fail(size <= MAX_DOCUMENT_BYTES, "DOCUMENT_TOO_LARGE", f"{label} exceeds {MAX_DOCUMENT_BYTES} bytes")
        value = parse_json_text(path.read_text(encoding="utf-8"), label)
    except SelectorError:
        raise
    except (OSError, UnicodeError) as exc:
        raise SelectorError("INPUT_IO", f"cannot read {label} at {path}: {exc}") from exc
    require_object(value, label)
    return value


def load_jsonl(path: Path, label: str) -> list[dict[str, Any]]:
    try:
        size = path.stat().st_size
        fail(size <= MAX_DOCUMENT_BYTES * 8, "DOCUMENT_TOO_LARGE", f"{label} exceeds the JSONL size limit")
        lines = path.read_text(encoding="utf-8").splitlines()
    except SelectorError:
        raise
    except (OSError, UnicodeError) as exc:
        raise SelectorError("INPUT_IO", f"cannot read {label} at {path}: {exc}") from exc
    records = []
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        fail(len(records) < MAX_JSONL_RECORDS, "TOO_MANY_RECORDS", f"{label} exceeds {MAX_JSONL_RECORDS} records")
        value = parse_json_text(line, f"{label} line {line_number}")
        require_object(value, f"{label} line {line_number}")
        records.append(value)
    return records


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest(value: Any) -> str:
    return "sha256:" + hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def require_object(value: Any, label: str) -> dict[str, Any]:
    fail(isinstance(value, dict), "INVALID_SHAPE", f"{label} must be an object")
    return value


def require_exact(value: Any, fields: Iterable[str], label: str) -> dict[str, Any]:
    obj = require_object(value, label)
    expected = set(fields)
    actual = set(obj)
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    fail(not missing and not extra, "INVALID_SHAPE", f"{label} fields mismatch; missing={missing}, extra={extra}")
    return obj


def valid_text(value: Any, maximum: int, allow_empty: bool = False) -> bool:
    if not isinstance(value, str) or len(value) > maximum:
        return False
    if not allow_empty and not value.strip():
        return False
    return not any(ord(char) < 32 or 127 <= ord(char) <= 159 or 0xD800 <= ord(char) <= 0xDFFF for char in value)


def require_text(value: Any, label: str, maximum: int = 512) -> str:
    fail(valid_text(value, maximum), "INVALID_VALUE", f"{label} must be non-empty text up to {maximum} characters")
    return value


def require_id(value: Any, label: str) -> str:
    fail(isinstance(value, str) and len(value) <= 128 and ID_PATTERN.fullmatch(value) is not None,
         "INVALID_ID", f"{label} is not a valid Operator identifier")
    return value


def require_nullable_id(value: Any, label: str) -> str | None:
    if value is None:
        return None
    return require_id(value, label)


def require_bool(value: Any, label: str) -> bool:
    fail(type(value) is bool, "INVALID_VALUE", f"{label} must be boolean")
    return value


def require_int(value: Any, label: str, minimum: int = 0, maximum: int | None = None) -> int:
    fail(type(value) is int and value >= minimum and (maximum is None or value <= maximum),
         "INVALID_VALUE", f"{label} must be an integer in range {minimum}..{maximum if maximum is not None else 'unbounded'}")
    return value


def require_nullable_int(value: Any, label: str, minimum: int = 0, maximum: int | None = None) -> int | None:
    if value is None:
        return None
    return require_int(value, label, minimum, maximum)


def require_bps(value: Any, label: str) -> int:
    return require_int(value, label, 0, 10000)


def require_nullable_bps(value: Any, label: str) -> int | None:
    return require_nullable_int(value, label, 0, 10000)


def require_enum(value: Any, choices: set[str], label: str) -> str:
    fail(isinstance(value, str) and value in choices, "INVALID_VALUE", f"{label} must be one of {sorted(choices)}")
    return value


def require_id_set(value: Any, label: str, maximum: int = 256) -> list[str]:
    fail(isinstance(value, list) and len(value) <= maximum, "INVALID_VALUE", f"{label} must be an array with at most {maximum} items")
    result = [require_id(item, f"{label}[{index}]") for index, item in enumerate(value)]
    fail(len(result) == len(set(result)), "DUPLICATE_ID", f"{label} contains duplicates")
    return result


def require_timestamp(value: Any, label: str) -> datetime:
    fail(isinstance(value, str) and len(value) <= 64, "INVALID_TIMESTAMP", f"{label} must be an RFC 3339 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise SelectorError("INVALID_TIMESTAMP", f"{label}: {exc}") from exc
    fail(parsed.tzinfo is not None and parsed.utcoffset() is not None, "INVALID_TIMESTAMP", f"{label} must include a timezone")
    return parsed.astimezone(timezone.utc)


def require_digest(value: Any, label: str) -> str:
    fail(isinstance(value, str) and DIGEST_PATTERN.fullmatch(value) is not None,
         "INVALID_DIGEST", f"{label} must be sha256:<64 lowercase hex characters>")
    return value


def require_schema(value: dict[str, Any], label: str) -> None:
    fail(value.get("schemaVersion") == SCHEMA_VERSION, "UNSUPPORTED_SCHEMA", f"{label} schemaVersion must be {SCHEMA_VERSION}")


def unique_rows(rows: list[dict[str, Any]], key: str, label: str) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for row in rows:
        value = row[key]
        fail(value not in result, "DUPLICATE_ID", f"duplicate {label}: {value}")
        result[value] = row
    return result


def validate_reasoning(value: Any, label: str) -> None:
    obj = require_exact(value, {"name", "parameters"}, label)
    require_id(obj["name"], f"{label}.name")
    params = require_object(obj["parameters"], f"{label}.parameters")
    fail(len(params) <= 32, "INVALID_VALUE", f"{label}.parameters has more than 32 entries")
    for key, item in params.items():
        require_id(key, f"{label}.parameters key")
        fail(item is None or type(item) in {str, int, bool}, "INVALID_VALUE", f"{label}.parameters.{key} must be a scalar")
        if isinstance(item, str):
            fail(valid_text(item, 256, allow_empty=True), "INVALID_VALUE", f"{label}.parameters.{key} is invalid text")


def validate_task(value: dict[str, Any]) -> dict[str, Any]:
    fields = {
        "schemaVersion", "taskId", "featureId", "graphNodeId", "requestedAt", "taskClass", "phase",
        "riskClass", "qualityFloorBps", "signals", "requirements", "constraints", "limits",
    }
    task = require_exact(value, fields, "task")
    require_schema(task, "task")
    require_id(task["taskId"], "task.taskId")
    require_nullable_id(task["featureId"], "task.featureId")
    require_nullable_id(task["graphNodeId"], "task.graphNodeId")
    require_timestamp(task["requestedAt"], "task.requestedAt")
    require_id(task["taskClass"], "task.taskClass")
    require_id(task["phase"], "task.phase")
    require_id(task["riskClass"], "task.riskClass")
    require_bps(task["qualityFloorBps"], "task.qualityFloorBps")

    signal_fields = {
        "ambiguity", "novelty", "reasoningDepth", "implementationSurface",
        "dependencyCount", "reversibility", "validationStrength",
    }
    signals = require_exact(task["signals"], signal_fields, "task.signals")
    for key in sorted(signal_fields):
        require_int(signals[key], f"task.signals.{key}", 0, 4)

    requirement_fields = {"capabilities", "tools", "modalities", "minimumContextTokens", "dataClasses", "laneId", "hostId"}
    requirements = require_exact(task["requirements"], requirement_fields, "task.requirements")
    for key in ("capabilities", "tools", "modalities", "dataClasses"):
        require_id_set(requirements[key], f"task.requirements.{key}")
    require_int(requirements["minimumContextTokens"], "task.requirements.minimumContextTokens")
    require_nullable_id(requirements["laneId"], "task.requirements.laneId")
    require_nullable_id(requirements["hostId"], "task.requirements.hostId")

    constraint_fields = {"allowedProfileIds", "excludedCandidateIds", "continuity", "override"}
    constraints = require_exact(task["constraints"], constraint_fields, "task.constraints")
    require_id_set(constraints["allowedProfileIds"], "task.constraints.allowedProfileIds")
    require_id_set(constraints["excludedCandidateIds"], "task.constraints.excludedCandidateIds")
    if constraints["continuity"] is not None:
        continuity = require_exact(constraints["continuity"], {"candidateId", "profileId"}, "task.constraints.continuity")
        require_nullable_id(continuity["candidateId"], "task.constraints.continuity.candidateId")
        require_nullable_id(continuity["profileId"], "task.constraints.continuity.profileId")
    if constraints["override"] is not None:
        override = require_exact(constraints["override"], {"candidateId", "reason"}, "task.constraints.override")
        require_id(override["candidateId"], "task.constraints.override.candidateId")
        require_text(override["reason"], "task.constraints.override.reason")

    limits = require_exact(task["limits"], {"maximumExpectedTokens", "maximumLatencyMs", "maximumCostMicrounits"}, "task.limits")
    for key in limits:
        require_nullable_int(limits[key], f"task.limits.{key}")
    return task


def validate_catalog(value: dict[str, Any]) -> dict[str, Any]:
    fields = {"schemaVersion", "catalogId", "revision", "observedAt", "validUntil", "profiles", "candidates"}
    catalog = require_exact(value, fields, "catalog")
    require_schema(catalog, "catalog")
    require_id(catalog["catalogId"], "catalog.catalogId")
    require_int(catalog["revision"], "catalog.revision", 1)
    observed = require_timestamp(catalog["observedAt"], "catalog.observedAt")
    valid_until = require_timestamp(catalog["validUntil"], "catalog.validUntil")
    fail(observed <= valid_until, "INVALID_CATALOG_WINDOW", "catalog.observedAt must not be after catalog.validUntil")

    fail(isinstance(catalog["profiles"], list) and 1 <= len(catalog["profiles"]) <= 64,
         "INVALID_VALUE", "catalog.profiles must contain 1..64 entries")
    profiles = []
    for index, raw in enumerate(catalog["profiles"]):
        profile = require_exact(raw, {"profileId", "description"}, f"catalog.profiles[{index}]")
        require_id(profile["profileId"], f"catalog.profiles[{index}].profileId")
        require_text(profile["description"], f"catalog.profiles[{index}].description")
        profiles.append(profile)
    profiles_by_id = unique_rows(profiles, "profileId", "profileId")

    fail(isinstance(catalog["candidates"], list) and 1 <= len(catalog["candidates"]) <= 512,
         "INVALID_VALUE", "catalog.candidates must contain 1..512 entries")
    candidates = []
    candidate_fields = {
        "candidateId", "providerId", "modelId", "enabled", "profileId", "reasoningSetting",
        "availability", "credentialCapability", "compatibility", "estimates",
    }
    compatibility_fields = {
        "capabilities", "tools", "modalities", "contextWindowTokens", "dataClasses",
        "laneIds", "hostIds", "maximumRiskClass",
    }
    estimate_fields = {
        "taskClass", "recoveryAssumptionId", "qualityBps", "confidenceBps", "firstAttemptTokens",
        "retryProbabilityBps", "retryTokens", "escalationProbabilityBps", "escalationTargetCandidateId",
        "escalationTokens", "latencyMs", "costMicrounits",
    }
    for index, raw in enumerate(catalog["candidates"]):
        label = f"catalog.candidates[{index}]"
        candidate = require_exact(raw, candidate_fields, label)
        require_id(candidate["candidateId"], f"{label}.candidateId")
        require_id(candidate["providerId"], f"{label}.providerId")
        require_text(candidate["modelId"], f"{label}.modelId", 256)
        require_bool(candidate["enabled"], f"{label}.enabled")
        require_id(candidate["profileId"], f"{label}.profileId")
        validate_reasoning(candidate["reasoningSetting"], f"{label}.reasoningSetting")
        require_enum(candidate["availability"], {"available", "unavailable", "unknown"}, f"{label}.availability")
        require_nullable_id(candidate["credentialCapability"], f"{label}.credentialCapability")
        compatibility = require_exact(candidate["compatibility"], compatibility_fields, f"{label}.compatibility")
        for key in ("capabilities", "tools", "modalities", "dataClasses", "laneIds", "hostIds"):
            require_id_set(compatibility[key], f"{label}.compatibility.{key}")
        require_int(compatibility["contextWindowTokens"], f"{label}.compatibility.contextWindowTokens", 1)
        require_id(compatibility["maximumRiskClass"], f"{label}.compatibility.maximumRiskClass")
        fail(isinstance(candidate["estimates"], list) and 1 <= len(candidate["estimates"]) <= 128,
             "INVALID_VALUE", f"{label}.estimates must contain 1..128 entries")
        estimates = []
        for estimate_index, raw_estimate in enumerate(candidate["estimates"]):
            estimate_label = f"{label}.estimates[{estimate_index}]"
            estimate = require_exact(raw_estimate, estimate_fields, estimate_label)
            require_id(estimate["taskClass"], f"{estimate_label}.taskClass")
            require_id(estimate["recoveryAssumptionId"], f"{estimate_label}.recoveryAssumptionId")
            for key in ("qualityBps", "confidenceBps", "retryProbabilityBps", "escalationProbabilityBps"):
                require_nullable_bps(estimate[key], f"{estimate_label}.{key}")
            for key in ("firstAttemptTokens", "retryTokens", "escalationTokens", "latencyMs", "costMicrounits"):
                require_nullable_int(estimate[key], f"{estimate_label}.{key}")
            require_nullable_id(estimate["escalationTargetCandidateId"], f"{estimate_label}.escalationTargetCandidateId")
            if estimate["escalationProbabilityBps"] is not None and estimate["escalationProbabilityBps"] > 0:
                fail(estimate["escalationTargetCandidateId"] is not None, "INVALID_REFERENCE",
                     f"{estimate_label}.escalationTargetCandidateId is required when escalation probability is positive")
            estimates.append(estimate)
        unique_rows(estimates, "taskClass", f"taskClass estimate for {candidate['candidateId']}")
        candidates.append(candidate)
    candidates_by_id = unique_rows(candidates, "candidateId", "candidateId")
    for candidate in candidates:
        fail(candidate["profileId"] in profiles_by_id, "INVALID_REFERENCE",
             f"candidate {candidate['candidateId']} references unknown profile {candidate['profileId']}")
        for estimate in candidate["estimates"]:
            target = estimate["escalationTargetCandidateId"]
            fail(target is None or target in candidates_by_id, "INVALID_REFERENCE",
                 f"candidate {candidate['candidateId']} references unknown escalation target {target}")
    return catalog


def validate_policy(value: dict[str, Any]) -> dict[str, Any]:
    fields = {
        "schemaVersion", "policyId", "revision", "algorithmVersion", "mode", "allowedProfileIds",
        "riskClassOrder", "qualityFloors", "riskFloors", "minimumConfidenceBps",
        "contextSafetyMarginTokens", "hardConstraints", "requiredEstimateFields", "dataPolicy",
        "overridePolicy", "recovery", "limits", "tieBreakOrder", "authority",
    }
    policy = require_exact(value, fields, "policy")
    require_schema(policy, "policy")
    require_id(policy["policyId"], "policy.policyId")
    require_int(policy["revision"], "policy.revision", 1)
    fail(policy["algorithmVersion"] == ALGORITHM_VERSION, "UNSUPPORTED_ALGORITHM",
         f"policy.algorithmVersion must be {ALGORITHM_VERSION}")
    require_enum(policy["mode"], {"off", "recommend", "policy-auto"}, "policy.mode")
    require_id_set(policy["allowedProfileIds"], "policy.allowedProfileIds")
    risk_order = require_id_set(policy["riskClassOrder"], "policy.riskClassOrder", 32)
    fail(bool(risk_order), "INVALID_RISK_ORDER", "policy.riskClassOrder must not be empty")

    quality = require_exact(policy["qualityFloors"], {"defaultBps", "byTaskClass"}, "policy.qualityFloors")
    require_bps(quality["defaultBps"], "policy.qualityFloors.defaultBps")
    fail(isinstance(quality["byTaskClass"], list) and len(quality["byTaskClass"]) <= 128,
         "INVALID_VALUE", "policy.qualityFloors.byTaskClass must be an array")
    quality_rows = []
    for index, raw in enumerate(quality["byTaskClass"]):
        row = require_exact(raw, {"taskClass", "minimumBps"}, f"policy.qualityFloors.byTaskClass[{index}]")
        require_id(row["taskClass"], f"policy.qualityFloors.byTaskClass[{index}].taskClass")
        require_bps(row["minimumBps"], f"policy.qualityFloors.byTaskClass[{index}].minimumBps")
        quality_rows.append(row)
    unique_rows(quality_rows, "taskClass", "quality floor taskClass")

    risks = require_exact(policy["riskFloors"], {"defaultClass", "byTaskClass"}, "policy.riskFloors")
    require_id(risks["defaultClass"], "policy.riskFloors.defaultClass")
    fail(risks["defaultClass"] in risk_order, "INVALID_RISK_ORDER", "policy default risk class is absent from riskClassOrder")
    fail(isinstance(risks["byTaskClass"], list) and len(risks["byTaskClass"]) <= 128,
         "INVALID_VALUE", "policy.riskFloors.byTaskClass must be an array")
    risk_rows = []
    for index, raw in enumerate(risks["byTaskClass"]):
        row = require_exact(raw, {"taskClass", "minimumClass"}, f"policy.riskFloors.byTaskClass[{index}]")
        require_id(row["taskClass"], f"policy.riskFloors.byTaskClass[{index}].taskClass")
        require_id(row["minimumClass"], f"policy.riskFloors.byTaskClass[{index}].minimumClass")
        fail(row["minimumClass"] in risk_order, "INVALID_RISK_ORDER",
             f"policy risk floor {row['minimumClass']} is absent from riskClassOrder")
        risk_rows.append(row)
    unique_rows(risk_rows, "taskClass", "risk floor taskClass")

    require_bps(policy["minimumConfidenceBps"], "policy.minimumConfidenceBps")
    require_int(policy["contextSafetyMarginTokens"], "policy.contextSafetyMarginTokens")
    hard = require_exact(policy["hardConstraints"], HARD_CONSTRAINT_FIELDS, "policy.hardConstraints")
    for key in HARD_CONSTRAINT_FIELDS:
        fail(hard[key] is True, "UNSAFE_POLICY", f"policy.hardConstraints.{key} must be true")
    fail(policy["requiredEstimateFields"] == REQUIRED_ESTIMATE_FIELDS, "UNSAFE_POLICY",
         "policy.requiredEstimateFields does not match the v1 required estimate list")

    data_policy = require_exact(policy["dataPolicy"], {"allowedDataClasses", "requireCandidateDeclaration"}, "policy.dataPolicy")
    require_id_set(data_policy["allowedDataClasses"], "policy.dataPolicy.allowedDataClasses")
    fail(data_policy["requireCandidateDeclaration"] is True, "UNSAFE_POLICY",
         "policy.dataPolicy.requireCandidateDeclaration must be true")
    override = require_exact(policy["overridePolicy"], {"allowCandidatePin", "requireReason", "enforceHardConstraints"}, "policy.overridePolicy")
    require_bool(override["allowCandidatePin"], "policy.overridePolicy.allowCandidatePin")
    fail(override["requireReason"] is True and override["enforceHardConstraints"] is True,
         "UNSAFE_POLICY", "policy override reasons and hard constraints must remain enforced")
    recovery = require_exact(policy["recovery"], {"assumptionId", "maximumRetries", "includeEscalation"}, "policy.recovery")
    require_id(recovery["assumptionId"], "policy.recovery.assumptionId")
    require_int(recovery["maximumRetries"], "policy.recovery.maximumRetries", 0, 1)
    require_bool(recovery["includeEscalation"], "policy.recovery.includeEscalation")
    fail(recovery["maximumRetries"] == 1 and recovery["includeEscalation"] is True,
         "UNSAFE_POLICY", "v1 recovery must model exactly one retry and one escalation")
    limits = require_exact(policy["limits"], {"maximumExpectedTokens", "maximumLatencyMs", "maximumCostMicrounits"}, "policy.limits")
    for key in limits:
        require_nullable_int(limits[key], f"policy.limits.{key}")
    fail(policy["tieBreakOrder"] == TIE_BREAK_ORDER, "UNSAFE_POLICY", "policy.tieBreakOrder must match the deterministic v1 order")
    authority = require_exact(policy["authority"], {"recommendationOnly", "policyAutoDryRunOnly", "onlineLearning"}, "policy.authority")
    fail(authority == {"recommendationOnly": True, "policyAutoDryRunOnly": True, "onlineLearning": False},
         "UNSAFE_POLICY", "policy authority must remain advisory and offline")
    return policy


def validate_expected(value: Any, label: str) -> None:
    fields = {
        "qualityBps", "confidenceBps", "firstAttemptTokens", "retryProbabilityBps", "retryTokens",
        "retryRiskTokens", "escalationProbabilityBps", "escalationTokens", "escalationRiskTokens",
        "expectedTotalTokens", "latencyMs", "costMicrounits",
    }
    expected = require_exact(value, fields, label)
    for key in ("qualityBps", "confidenceBps", "retryProbabilityBps", "escalationProbabilityBps"):
        require_bps(expected[key], f"{label}.{key}")
    for key in fields - {"qualityBps", "confidenceBps", "retryProbabilityBps", "escalationProbabilityBps"}:
        require_int(expected[key], f"{label}.{key}")


def validate_decision(value: dict[str, Any]) -> dict[str, Any]:
    fields = {
        "schemaVersion", "decisionId", "selectionFingerprint", "algorithmVersion", "generatedAt", "taskId",
        "status", "inputEvidence", "demandEvidence", "recommendation", "eligibleCandidateIds",
        "rejectedCandidates", "paretoFrontierCandidateIds", "fallbackCandidateIds", "tieBreakOrder",
        "tieBreakTrace", "overrideEvidence", "reasons", "authority",
    }
    decision = require_exact(value, fields, "decision")
    require_schema(decision, "decision")
    require_id(decision["decisionId"], "decision.decisionId")
    require_digest(decision["selectionFingerprint"], "decision.selectionFingerprint")
    fail(decision["algorithmVersion"] == ALGORITHM_VERSION, "UNSUPPORTED_ALGORITHM", "decision algorithmVersion is unsupported")
    require_timestamp(decision["generatedAt"], "decision.generatedAt")
    require_id(decision["taskId"], "decision.taskId")
    status = require_enum(decision["status"], {"recommended", "off", "needs_override"}, "decision.status")

    evidence_fields = {"taskDemandDigest", "catalogId", "catalogRevision", "catalogDigest", "policyId", "policyRevision", "policyDigest"}
    evidence = require_exact(decision["inputEvidence"], evidence_fields, "decision.inputEvidence")
    for key in ("taskDemandDigest", "catalogDigest", "policyDigest"):
        require_digest(evidence[key], f"decision.inputEvidence.{key}")
    for key in ("catalogId", "policyId"):
        require_id(evidence[key], f"decision.inputEvidence.{key}")
    for key in ("catalogRevision", "policyRevision"):
        require_int(evidence[key], f"decision.inputEvidence.{key}", 1)
    demand = require_exact(decision["demandEvidence"], {"taskClass", "effectiveRiskClass", "effectiveQualityFloorBps"}, "decision.demandEvidence")
    require_id(demand["taskClass"], "decision.demandEvidence.taskClass")
    require_id(demand["effectiveRiskClass"], "decision.demandEvidence.effectiveRiskClass")
    require_bps(demand["effectiveQualityFloorBps"], "decision.demandEvidence.effectiveQualityFloorBps")

    fail((status == "recommended") == (decision["recommendation"] is not None), "INVALID_DECISION",
         "decision.recommendation presence must match recommended status")
    if decision["recommendation"] is not None:
        rec = require_exact(decision["recommendation"],
                            {"candidateId", "profileId", "providerId", "modelId", "reasoningSetting", "expected", "continuityRank"},
                            "decision.recommendation")
        for key in ("candidateId", "profileId", "providerId"):
            require_id(rec[key], f"decision.recommendation.{key}")
        require_text(rec["modelId"], "decision.recommendation.modelId", 256)
        validate_reasoning(rec["reasoningSetting"], "decision.recommendation.reasoningSetting")
        validate_expected(rec["expected"], "decision.recommendation.expected")
        require_int(rec["continuityRank"], "decision.recommendation.continuityRank", 0, 2)
    for key in ("eligibleCandidateIds", "paretoFrontierCandidateIds", "fallbackCandidateIds"):
        require_id_set(decision[key], f"decision.{key}", 512)
    fail(isinstance(decision["rejectedCandidates"], list) and len(decision["rejectedCandidates"]) <= 512,
         "INVALID_VALUE", "decision.rejectedCandidates must be an array")
    rejected_ids = []
    for index, raw in enumerate(decision["rejectedCandidates"]):
        row = require_exact(raw, {"candidateId", "reasonCodes"}, f"decision.rejectedCandidates[{index}]")
        rejected_ids.append(require_id(row["candidateId"], f"decision.rejectedCandidates[{index}].candidateId"))
        require_id_set(row["reasonCodes"], f"decision.rejectedCandidates[{index}].reasonCodes")
    fail(len(rejected_ids) == len(set(rejected_ids)), "DUPLICATE_ID", "decision.rejectedCandidates contains duplicate candidates")
    fail(decision["tieBreakOrder"] == TIE_BREAK_ORDER, "INVALID_DECISION", "decision.tieBreakOrder is not deterministic v1 order")
    fail(isinstance(decision["tieBreakTrace"], list) and len(decision["tieBreakTrace"]) <= 512,
         "INVALID_VALUE", "decision.tieBreakTrace must be an array")
    trace_ids = []
    for index, raw in enumerate(decision["tieBreakTrace"]):
        row = require_exact(raw, {"candidateId", "expectedTotalTokens", "continuityRank", "latencyMs", "costMicrounits"},
                            f"decision.tieBreakTrace[{index}]")
        trace_ids.append(require_id(row["candidateId"], f"decision.tieBreakTrace[{index}].candidateId"))
        for key in ("expectedTotalTokens", "latencyMs", "costMicrounits"):
            require_int(row[key], f"decision.tieBreakTrace[{index}].{key}")
        require_int(row["continuityRank"], f"decision.tieBreakTrace[{index}].continuityRank", 0, 2)
    fail(len(trace_ids) == len(set(trace_ids)), "DUPLICATE_ID", "decision.tieBreakTrace contains duplicate candidates")
    override = require_exact(decision["overrideEvidence"], {"requestedCandidateId", "honored", "reasonCode"}, "decision.overrideEvidence")
    require_nullable_id(override["requestedCandidateId"], "decision.overrideEvidence.requestedCandidateId")
    fail(override["honored"] is None or type(override["honored"]) is bool, "INVALID_VALUE", "decision.overrideEvidence.honored must be boolean or null")
    require_nullable_id(override["reasonCode"], "decision.overrideEvidence.reasonCode")
    fail(isinstance(decision["reasons"], list) and len(decision["reasons"]) <= 256,
         "INVALID_VALUE", "decision.reasons must be an array")
    for index, reason in enumerate(decision["reasons"]):
        require_text(reason, f"decision.reasons[{index}]")
    authority = require_exact(decision["authority"], {"mode", "dispatchPerformed", "graphMutated", "executionSettingsChanged"}, "decision.authority")
    fail(authority == {"mode": "advisory", "dispatchPerformed": False, "graphMutated": False, "executionSettingsChanged": False},
         "INVALID_AUTHORITY", "decision authority must be advisory and non-mutating")
    return decision


def validate_token_usage(value: Any, label: str) -> None:
    usage = require_object(value, label)
    status = usage.get("status")
    if status == "reported":
        require_exact(usage, {"status", "inputTokens", "outputTokens", "cachedTokens", "reasoningTokens", "totalTokens"}, label)
        for key in ("inputTokens", "outputTokens", "cachedTokens", "reasoningTokens", "totalTokens"):
            require_int(usage[key], f"{label}.{key}")
    elif status == "unknown":
        require_exact(usage, {"status", "reason"}, label)
        require_text(usage["reason"], f"{label}.reason")
    else:
        raise SelectorError("INVALID_VALUE", f"{label}.status must be reported or unknown")


def validate_measurement(value: Any, label: str) -> None:
    measurement = require_object(value, label)
    status = measurement.get("status")
    if status == "reported":
        require_exact(measurement, {"status", "value"}, label)
        require_int(measurement["value"], f"{label}.value")
    elif status == "unknown":
        require_exact(measurement, {"status", "reason"}, label)
        require_text(measurement["reason"], f"{label}.reason")
    else:
        raise SelectorError("INVALID_VALUE", f"{label}.status must be reported or unknown")


def validate_execution(value: Any, label: str) -> None:
    execution = require_exact(value, {"candidateId"}, label)
    require_id(execution["candidateId"], f"{label}.candidateId")


def validate_outcome(value: dict[str, Any]) -> dict[str, Any]:
    fields = {
        "schemaVersion", "outcomeId", "recordedAt", "taskId", "decisionId", "catalogId", "catalogRevision",
        "policyId", "policyRevision", "recommendationDisposition", "actualExecution", "acceptance", "validation",
        "attempts", "retryCount", "escalationCount", "handoffCount", "humanCorrection", "totalTokenUsage",
        "totalLatencyMs", "totalCostMicrounits", "terminalReason", "evidenceRefs",
    }
    outcome = require_exact(value, fields, "outcome")
    require_schema(outcome, "outcome")
    for key in ("outcomeId", "taskId", "decisionId", "catalogId", "policyId", "terminalReason"):
        require_id(outcome[key], f"outcome.{key}")
    require_timestamp(outcome["recordedAt"], "outcome.recordedAt")
    require_int(outcome["catalogRevision"], "outcome.catalogRevision", 1)
    require_int(outcome["policyRevision"], "outcome.policyRevision", 1)
    require_enum(outcome["recommendationDisposition"], {"followed", "overridden", "not_run", "unknown"},
                 "outcome.recommendationDisposition")
    if outcome["actualExecution"] is not None:
        validate_execution(outcome["actualExecution"], "outcome.actualExecution")
    acceptance = require_exact(outcome["acceptance"], {"status", "reason"}, "outcome.acceptance")
    require_enum(acceptance["status"], {"accepted", "rejected", "unknown"}, "outcome.acceptance.status")
    if acceptance["reason"] is not None:
        require_text(acceptance["reason"], "outcome.acceptance.reason", 1024)
    validation = require_exact(outcome["validation"], {"status", "checks"}, "outcome.validation")
    require_enum(validation["status"], {"passed", "failed", "not_run", "unknown"}, "outcome.validation.status")
    fail(isinstance(validation["checks"], list) and len(validation["checks"]) <= 256,
         "INVALID_VALUE", "outcome.validation.checks must be an array")
    check_ids = []
    for index, raw in enumerate(validation["checks"]):
        row = require_exact(raw, {"checkId", "status"}, f"outcome.validation.checks[{index}]")
        check_ids.append(require_id(row["checkId"], f"outcome.validation.checks[{index}].checkId"))
        require_enum(row["status"], {"passed", "failed", "not_run", "unknown"}, f"outcome.validation.checks[{index}].status")
    fail(len(check_ids) == len(set(check_ids)), "DUPLICATE_ID", "outcome validation check IDs must be unique")
    fail(isinstance(outcome["attempts"], list) and len(outcome["attempts"]) <= 64,
         "INVALID_VALUE", "outcome.attempts must be an array")
    attempt_ids = []
    attempt_indexes = []
    reported_attempt_total = 0
    all_attempt_tokens_reported = True
    for index, raw in enumerate(outcome["attempts"]):
        label = f"outcome.attempts[{index}]"
        attempt = require_exact(raw, {"attemptId", "index", "execution", "result", "tokenUsage", "latencyMs", "costMicrounits"}, label)
        attempt_ids.append(require_id(attempt["attemptId"], f"{label}.attemptId"))
        attempt_indexes.append(require_int(attempt["index"], f"{label}.index"))
        validate_execution(attempt["execution"], f"{label}.execution")
        require_enum(attempt["result"], {"accepted", "rejected", "error", "abandoned", "unknown"}, f"{label}.result")
        validate_token_usage(attempt["tokenUsage"], f"{label}.tokenUsage")
        if attempt["tokenUsage"]["status"] == "reported":
            reported_attempt_total += attempt["tokenUsage"]["totalTokens"]
        else:
            all_attempt_tokens_reported = False
        validate_measurement(attempt["latencyMs"], f"{label}.latencyMs")
        validate_measurement(attempt["costMicrounits"], f"{label}.costMicrounits")
    fail(len(attempt_ids) == len(set(attempt_ids)), "DUPLICATE_ID", "outcome attempt IDs must be unique")
    fail(len(attempt_indexes) == len(set(attempt_indexes)), "DUPLICATE_ID", "outcome attempt indexes must be unique")
    fail(sorted(attempt_indexes) == list(range(len(attempt_indexes))), "INVALID_VALUE", "outcome attempt indexes must be contiguous from zero")
    for key in ("retryCount", "escalationCount", "handoffCount"):
        require_int(outcome[key], f"outcome.{key}")
    fail(outcome["humanCorrection"] is None or type(outcome["humanCorrection"]) is bool,
         "INVALID_VALUE", "outcome.humanCorrection must be boolean or null")
    validate_token_usage(outcome["totalTokenUsage"], "outcome.totalTokenUsage")
    if all_attempt_tokens_reported and outcome["totalTokenUsage"]["status"] == "reported":
        fail(outcome["totalTokenUsage"]["totalTokens"] == reported_attempt_total, "INCONSISTENT_TELEMETRY",
             "outcome totalTokenUsage.totalTokens must equal the sum of reported attempt totals")
    validate_measurement(outcome["totalLatencyMs"], "outcome.totalLatencyMs")
    validate_measurement(outcome["totalCostMicrounits"], "outcome.totalCostMicrounits")
    fail(isinstance(outcome["evidenceRefs"], list) and len(outcome["evidenceRefs"]) <= 256,
         "INVALID_VALUE", "outcome.evidenceRefs must be an array")
    for index, ref in enumerate(outcome["evidenceRefs"]):
        require_text(ref, f"outcome.evidenceRefs[{index}]", 1024)
    fail(len(outcome["evidenceRefs"]) == len(set(outcome["evidenceRefs"])), "DUPLICATE_ID", "outcome evidenceRefs must be unique")
    return outcome


def validate_suggestion(value: dict[str, Any]) -> dict[str, Any]:
    fields = {
        "schemaVersion", "suggestionId", "evidenceFingerprint", "algorithmVersion", "status",
        "projectName", "inputs", "authority", "laneObservations", "taskClassObservations",
        "candidateObservations", "policyHints", "missingInputs",
    }
    suggestion = require_exact(value, fields, "suggestion")
    fail(suggestion["schemaVersion"] == SUGGESTION_VERSION, "UNSUPPORTED_SCHEMA",
         f"suggestion schemaVersion must be {SUGGESTION_VERSION}")
    require_id(suggestion["suggestionId"], "suggestion.suggestionId")
    require_digest(suggestion["evidenceFingerprint"], "suggestion.evidenceFingerprint")
    fail(suggestion["algorithmVersion"] == SUGGESTION_ALGORITHM_VERSION, "UNSUPPORTED_ALGORITHM",
         f"suggestion algorithmVersion must be {SUGGESTION_ALGORITHM_VERSION}")
    require_enum(suggestion["status"], {"draft_ready", "needs_input"}, "suggestion.status")
    if suggestion["projectName"] is not None:
        require_text(suggestion["projectName"], "suggestion.projectName", 256)

    inputs = require_exact(suggestion["inputs"], {"laneMap", "tasks", "outcomes", "catalog"}, "suggestion.inputs")
    for key in ("laneMap", "tasks", "outcomes", "catalog"):
        row = require_exact(inputs[key], {"status", "digest", "recordCount"}, f"suggestion.inputs.{key}")
        require_enum(row["status"], {"reported", "missing"}, f"suggestion.inputs.{key}.status")
        if row["digest"] is not None:
            require_digest(row["digest"], f"suggestion.inputs.{key}.digest")
        require_int(row["recordCount"], f"suggestion.inputs.{key}.recordCount")
        fail((row["status"] == "reported") == (row["digest"] is not None), "INVALID_VALUE",
             f"suggestion.inputs.{key} reported status and digest must agree")

    authority = require_exact(
        suggestion["authority"],
        {"mode", "recommendationOnly", "writesFiles", "appliesSettings", "dispatchesWork", "onlineLearning", "draftPolicyMode"},
        "suggestion.authority",
    )
    fail(authority == {
        "mode": "advisory",
        "recommendationOnly": True,
        "writesFiles": False,
        "appliesSettings": False,
        "dispatchesWork": False,
        "onlineLearning": False,
        "draftPolicyMode": "off",
    }, "INVALID_AUTHORITY", "suggestion authority must remain advisory, read-only, offline, and off")

    fail(isinstance(suggestion["laneObservations"], list) and len(suggestion["laneObservations"]) <= 256,
         "INVALID_VALUE", "suggestion.laneObservations must be an array")
    lane_ids = []
    for index, raw in enumerate(suggestion["laneObservations"]):
        label = f"suggestion.laneObservations[{index}]"
        row = require_exact(raw, {"laneId", "owner", "worktree", "branch", "commandDigest", "modelHint", "reasoningHint", "evidenceRef"}, label)
        lane_ids.append(require_id(row["laneId"], f"{label}.laneId"))
        for key in ("owner", "worktree", "branch", "evidenceRef"):
            require_text(row[key], f"{label}.{key}", 1024)
        require_digest(row["commandDigest"], f"{label}.commandDigest")
        if row["modelHint"] is not None:
            require_text(row["modelHint"], f"{label}.modelHint", 256)
        if row["reasoningHint"] is not None:
            require_text(row["reasoningHint"], f"{label}.reasoningHint", 256)
    fail(len(lane_ids) == len(set(lane_ids)), "DUPLICATE_ID", "suggestion lane IDs must be unique")

    fail(isinstance(suggestion["taskClassObservations"], list), "INVALID_VALUE",
         "suggestion.taskClassObservations must be an array")
    task_classes = []
    for index, raw in enumerate(suggestion["taskClassObservations"]):
        label = f"suggestion.taskClassObservations[{index}]"
        row = require_exact(raw, {"taskClass", "taskCount", "laneIds", "hostIds", "riskClasses", "observedQualityFloorBps"}, label)
        task_classes.append(require_id(row["taskClass"], f"{label}.taskClass"))
        require_int(row["taskCount"], f"{label}.taskCount", 1)
        for key in ("laneIds", "hostIds", "riskClasses"):
            require_id_set(row[key], f"{label}.{key}")
        quality = require_exact(row["observedQualityFloorBps"], {"minimum", "maximum", "values"}, f"{label}.observedQualityFloorBps")
        require_bps(quality["minimum"], f"{label}.observedQualityFloorBps.minimum")
        require_bps(quality["maximum"], f"{label}.observedQualityFloorBps.maximum")
        fail(isinstance(quality["values"], list) and quality["values"], "INVALID_VALUE", f"{label}.observedQualityFloorBps.values must be non-empty")
        for value_index, quality_value in enumerate(quality["values"]):
            require_bps(quality_value, f"{label}.observedQualityFloorBps.values[{value_index}]")
    fail(len(task_classes) == len(set(task_classes)), "DUPLICATE_ID", "suggestion task classes must be unique")

    fail(isinstance(suggestion["candidateObservations"], list), "INVALID_VALUE",
         "suggestion.candidateObservations must be an array")
    candidate_keys = []
    for index, raw in enumerate(suggestion["candidateObservations"]):
        label = f"suggestion.candidateObservations[{index}]"
        row = require_exact(raw, {
            "candidateId", "taskClass", "catalogIdentity", "taskIds", "outcomeIds", "sampleCount",
            "acceptedOutcomeRate", "validationCounts", "firstAttemptTokens", "totalTokens", "latencyMs",
            "costMicrounits", "retry", "escalation", "handoff", "humanCorrection",
        }, label)
        candidate_id = require_id(row["candidateId"], f"{label}.candidateId")
        task_class = require_id(row["taskClass"], f"{label}.taskClass")
        candidate_keys.append((candidate_id, task_class))
        if row["catalogIdentity"] is not None:
            identity = require_exact(row["catalogIdentity"], {"providerId", "modelId", "profileId", "reasoningSetting", "enabled", "availability"}, f"{label}.catalogIdentity")
            require_id(identity["providerId"], f"{label}.catalogIdentity.providerId")
            require_text(identity["modelId"], f"{label}.catalogIdentity.modelId", 256)
            require_id(identity["profileId"], f"{label}.catalogIdentity.profileId")
            validate_reasoning(identity["reasoningSetting"], f"{label}.catalogIdentity.reasoningSetting")
            require_bool(identity["enabled"], f"{label}.catalogIdentity.enabled")
            require_enum(identity["availability"], {"available", "unavailable", "unknown"}, f"{label}.catalogIdentity.availability")
        task_ids = require_id_set(row["taskIds"], f"{label}.taskIds")
        outcome_ids = require_id_set(row["outcomeIds"], f"{label}.outcomeIds")
        sample_count = require_int(row["sampleCount"], f"{label}.sampleCount", 1)
        fail(sample_count == len(outcome_ids), "INVALID_VALUE", f"{label}.sampleCount must equal outcomeIds length")
        fail(bool(task_ids), "INVALID_VALUE", f"{label}.taskIds must be non-empty")
        rate = require_exact(row["acceptedOutcomeRate"], {"accepted", "known", "unknown", "rateBps"}, f"{label}.acceptedOutcomeRate")
        for key in ("accepted", "known", "unknown"):
            require_int(rate[key], f"{label}.acceptedOutcomeRate.{key}")
        require_nullable_bps(rate["rateBps"], f"{label}.acceptedOutcomeRate.rateBps")
        counts = require_exact(row["validationCounts"], {"passed", "failed", "notRun", "unknown"}, f"{label}.validationCounts")
        for key in counts:
            require_int(counts[key], f"{label}.validationCounts.{key}")
        for key in ("firstAttemptTokens", "totalTokens", "latencyMs", "costMicrounits"):
            metric = require_exact(row[key], {"reported", "unknown", "median"}, f"{label}.{key}")
            require_int(metric["reported"], f"{label}.{key}.reported")
            require_int(metric["unknown"], f"{label}.{key}.unknown")
            require_nullable_int(metric["median"], f"{label}.{key}.median")
        for key, count_key in (("retry", "totalCount"), ("escalation", "totalCount"), ("handoff", "totalCount")):
            recovery = require_exact(row[key], {"outcomesWithAny", count_key, "rateBps"}, f"{label}.{key}")
            require_int(recovery["outcomesWithAny"], f"{label}.{key}.outcomesWithAny")
            require_int(recovery[count_key], f"{label}.{key}.{count_key}")
            require_bps(recovery["rateBps"], f"{label}.{key}.rateBps")
        correction = require_exact(row["humanCorrection"], {"true", "false", "unknown", "rateBps"}, f"{label}.humanCorrection")
        for key in ("true", "false", "unknown"):
            require_int(correction[key], f"{label}.humanCorrection.{key}")
        require_nullable_bps(correction["rateBps"], f"{label}.humanCorrection.rateBps")
    fail(len(candidate_keys) == len(set(candidate_keys)), "DUPLICATE_ID", "suggestion candidate/task-class pairs must be unique")

    hints = require_exact(suggestion["policyHints"], {
        "mode", "requiresHumanReview", "taskClasses", "laneIds", "hostIds", "candidateIds", "profileIds",
        "candidateShortlists", "qualityFloors", "limits",
    }, "suggestion.policyHints")
    fail(hints["mode"] == "off", "INVALID_AUTHORITY", "suggestion policyHints.mode must be off")
    fail(hints["requiresHumanReview"] is True, "INVALID_AUTHORITY", "suggestion policy hints must require human review")
    for key in ("taskClasses", "laneIds", "hostIds", "candidateIds", "profileIds"):
        require_id_set(hints[key], f"suggestion.policyHints.{key}")
    for index, raw in enumerate(hints["candidateShortlists"]):
        label = f"suggestion.policyHints.candidateShortlists[{index}]"
        row = require_exact(raw, {"taskClass", "candidateIds", "minimumKnownOutcomes", "method"}, label)
        require_id(row["taskClass"], f"{label}.taskClass")
        require_id_set(row["candidateIds"], f"{label}.candidateIds")
        require_int(row["minimumKnownOutcomes"], f"{label}.minimumKnownOutcomes", 1)
        require_text(row["method"], f"{label}.method", 1024)
    for index, raw in enumerate(hints["qualityFloors"]):
        label = f"suggestion.policyHints.qualityFloors[{index}]"
        row = require_exact(raw, {"taskClass", "observedValuesBps", "suggestedMinimumBps", "basis"}, label)
        require_id(row["taskClass"], f"{label}.taskClass")
        for value_index, quality_value in enumerate(row["observedValuesBps"]):
            require_bps(quality_value, f"{label}.observedValuesBps[{value_index}]")
        require_nullable_bps(row["suggestedMinimumBps"], f"{label}.suggestedMinimumBps")
        require_text(row["basis"], f"{label}.basis", 1024)
    limits = require_exact(hints["limits"], {"maximumExpectedTokens", "maximumLatencyMs", "maximumCostMicrounits"}, "suggestion.policyHints.limits")
    for key in limits:
        require_nullable_int(limits[key], f"suggestion.policyHints.limits.{key}")

    fail(isinstance(suggestion["missingInputs"], list), "INVALID_VALUE", "suggestion.missingInputs must be an array")
    for index, raw in enumerate(suggestion["missingInputs"]):
        label = f"suggestion.missingInputs[{index}]"
        row = require_exact(raw, {"code", "scope", "severity", "message"}, label)
        require_id(row["code"], f"{label}.code")
        require_id(row["scope"], f"{label}.scope")
        require_enum(row["severity"], {"blocking", "review"}, f"{label}.severity")
        require_text(row["message"], f"{label}.message", 1024)
    return suggestion


VALIDATORS = {
    "task": validate_task,
    "catalog": validate_catalog,
    "policy": validate_policy,
    "decision": validate_decision,
    "outcome": validate_outcome,
    "suggestion": validate_suggestion,
}


def policy_row(rows: list[dict[str, Any]], task_class: str, value_key: str, default: Any) -> Any:
    for row in rows:
        if row["taskClass"] == task_class:
            return row[value_key]
    return default


def effective_demand(task: dict[str, Any], policy: dict[str, Any]) -> tuple[str, int]:
    risk_order = policy["riskClassOrder"]
    fail(task["riskClass"] in risk_order, "UNKNOWN_RISK_CLASS", f"task risk class {task['riskClass']} is absent from policy riskClassOrder")
    policy_risk = policy_row(policy["riskFloors"]["byTaskClass"], task["taskClass"], "minimumClass",
                             policy["riskFloors"]["defaultClass"])
    effective_risk = risk_order[max(risk_order.index(task["riskClass"]), risk_order.index(policy_risk))]
    policy_quality = policy_row(policy["qualityFloors"]["byTaskClass"], task["taskClass"], "minimumBps",
                                policy["qualityFloors"]["defaultBps"])
    return effective_risk, max(task["qualityFloorBps"], policy_quality)


def minimum_limit(task_value: int | None, policy_value: int | None) -> int | None:
    values = [value for value in (task_value, policy_value) if value is not None]
    return min(values) if values else None


def ceil_bps(probability_bps: int, value: int) -> int:
    return (probability_bps * value + 9999) // 10000


def continuity_rank(task: dict[str, Any], candidate: dict[str, Any]) -> int:
    continuity = task["constraints"]["continuity"]
    if continuity is None:
        return 2
    if continuity["candidateId"] == candidate["candidateId"]:
        return 0
    if continuity["profileId"] == candidate["profileId"]:
        return 1
    return 2


def tie_key(item: dict[str, Any]) -> tuple[int, int, int, int, str]:
    metrics = item["metrics"]
    return (
        metrics["expectedTotalTokens"],
        item["continuityRank"],
        metrics["latencyMs"],
        metrics["costMicrounits"],
        item["candidate"]["candidateId"],
    )


def dominates(left: dict[str, Any], right: dict[str, Any]) -> bool:
    a = left["metrics"]
    b = right["metrics"]
    comparisons = [
        a["qualityBps"] >= b["qualityBps"],
        a["expectedTotalTokens"] <= b["expectedTotalTokens"],
        a["latencyMs"] <= b["latencyMs"],
        a["costMicrounits"] <= b["costMicrounits"],
    ]
    strict = [
        a["qualityBps"] > b["qualityBps"],
        a["expectedTotalTokens"] < b["expectedTotalTokens"],
        a["latencyMs"] < b["latencyMs"],
        a["costMicrounits"] < b["costMicrounits"],
    ]
    return all(comparisons) and any(strict)


def selection_fingerprint(task: dict[str, Any], catalog: dict[str, Any], policy: dict[str, Any]) -> str:
    return digest({
        "algorithmVersion": ALGORITHM_VERSION,
        "taskDemandDigest": digest(task),
        "catalogDigest": digest(catalog),
        "policyDigest": digest(policy),
    })


def decision_base(task: dict[str, Any], catalog: dict[str, Any], policy: dict[str, Any],
                  effective_risk: str, effective_quality: int, generated_at: str | None) -> dict[str, Any]:
    fingerprint = selection_fingerprint(task, catalog, policy)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "decisionId": "decision-" + fingerprint.removeprefix("sha256:")[:32],
        "selectionFingerprint": fingerprint,
        "algorithmVersion": ALGORITHM_VERSION,
        "generatedAt": generated_at or utc_now(),
        "taskId": task["taskId"],
        "status": "needs_override",
        "inputEvidence": {
            "taskDemandDigest": digest(task),
            "catalogId": catalog["catalogId"],
            "catalogRevision": catalog["revision"],
            "catalogDigest": digest(catalog),
            "policyId": policy["policyId"],
            "policyRevision": policy["revision"],
            "policyDigest": digest(policy),
        },
        "demandEvidence": {
            "taskClass": task["taskClass"],
            "effectiveRiskClass": effective_risk,
            "effectiveQualityFloorBps": effective_quality,
        },
        "recommendation": None,
        "eligibleCandidateIds": [],
        "rejectedCandidates": [],
        "paretoFrontierCandidateIds": [],
        "fallbackCandidateIds": [],
        "tieBreakOrder": list(TIE_BREAK_ORDER),
        "tieBreakTrace": [],
        "overrideEvidence": {
            "requestedCandidateId": task["constraints"]["override"]["candidateId"] if task["constraints"]["override"] else None,
            "honored": None,
            "reasonCode": None,
        },
        "reasons": [],
        "authority": {
            "mode": "advisory",
            "dispatchPerformed": False,
            "graphMutated": False,
            "executionSettingsChanged": False,
        },
    }


def recommend(task: dict[str, Any], catalog: dict[str, Any], policy: dict[str, Any],
              generated_at: str | None = None) -> dict[str, Any]:
    validate_task(task)
    validate_catalog(catalog)
    validate_policy(policy)
    effective_risk, effective_quality = effective_demand(task, policy)
    receipt = decision_base(task, catalog, policy, effective_risk, effective_quality, generated_at)

    profile_ids = {profile["profileId"] for profile in catalog["profiles"]}
    unknown_policy_profiles = sorted(set(policy["allowedProfileIds"]) - profile_ids)
    fail(not unknown_policy_profiles, "INVALID_REFERENCE", f"policy references unknown profiles: {unknown_policy_profiles}")
    unknown_task_profiles = sorted(set(task["constraints"]["allowedProfileIds"]) - profile_ids)
    fail(not unknown_task_profiles, "INVALID_REFERENCE", f"task references unknown profiles: {unknown_task_profiles}")
    candidate_ids = {candidate["candidateId"] for candidate in catalog["candidates"]}
    unknown_exclusions = sorted(set(task["constraints"]["excludedCandidateIds"]) - candidate_ids)
    fail(not unknown_exclusions, "INVALID_REFERENCE", f"task excludes unknown candidates: {unknown_exclusions}")
    continuity = task["constraints"]["continuity"]
    if continuity:
        fail(continuity["candidateId"] is None or continuity["candidateId"] in candidate_ids,
             "INVALID_REFERENCE", "task continuity references an unknown candidate")
        fail(continuity["profileId"] is None or continuity["profileId"] in profile_ids,
             "INVALID_REFERENCE", "task continuity references an unknown profile")
    for candidate in catalog["candidates"]:
        fail(candidate["compatibility"]["maximumRiskClass"] in policy["riskClassOrder"], "UNKNOWN_RISK_CLASS",
             f"candidate {candidate['candidateId']} maximumRiskClass is absent from policy riskClassOrder")

    requested_at = require_timestamp(task["requestedAt"], "task.requestedAt")
    observed_at = require_timestamp(catalog["observedAt"], "catalog.observedAt")
    valid_until = require_timestamp(catalog["validUntil"], "catalog.validUntil")
    fail(observed_at <= requested_at <= valid_until, "CATALOG_STALE",
         "task.requestedAt is outside the catalog observation/validity window")

    if policy["mode"] == "off":
        receipt["status"] = "off"
        receipt["reasons"] = ["Policy mode is off; no recommendation was made."]
        validate_decision(receipt)
        return receipt

    override = task["constraints"]["override"]
    if override and not policy["overridePolicy"]["allowCandidatePin"]:
        receipt["overrideEvidence"].update({"honored": False, "reasonCode": "OVERRIDE_NOT_ALLOWED"})
        receipt["reasons"] = ["The requested candidate pin is not allowed by policy."]
        validate_decision(receipt)
        return receipt
    if override and override["candidateId"] not in candidate_ids:
        receipt["overrideEvidence"].update({"honored": False, "reasonCode": "OVERRIDE_UNKNOWN_CANDIDATE"})
        receipt["reasons"] = ["The requested candidate pin does not exist in the catalog."]
        validate_decision(receipt)
        return receipt

    risk_index = {risk: index for index, risk in enumerate(policy["riskClassOrder"])}
    required_context = task["requirements"]["minimumContextTokens"] + policy["contextSafetyMarginTokens"]
    token_limit = minimum_limit(task["limits"]["maximumExpectedTokens"], policy["limits"]["maximumExpectedTokens"])
    latency_limit = minimum_limit(task["limits"]["maximumLatencyMs"], policy["limits"]["maximumLatencyMs"])
    cost_limit = minimum_limit(task["limits"]["maximumCostMicrounits"], policy["limits"]["maximumCostMicrounits"])
    policy_data_classes = set(policy["dataPolicy"]["allowedDataClasses"])
    task_data_classes = set(task["requirements"]["dataClasses"])
    task_allowed_profiles = set(task["constraints"]["allowedProfileIds"])
    policy_allowed_profiles = set(policy["allowedProfileIds"])
    excluded_candidates = set(task["constraints"]["excludedCandidateIds"])
    eligible = []
    rejected = []

    for candidate in sorted(catalog["candidates"], key=lambda item: item["candidateId"]):
        candidate_id = candidate["candidateId"]
        compatibility = candidate["compatibility"]
        reasons: list[str] = []
        if override and candidate_id != override["candidateId"]:
            reasons.append("OVERRIDE_MISMATCH")
        if candidate_id in excluded_candidates:
            reasons.append("EXCLUDED_BY_TASK")
        if not candidate["enabled"]:
            reasons.append("DISABLED")
        if candidate["availability"] != "available":
            reasons.append("UNAVAILABLE")
        if candidate["profileId"] not in policy_allowed_profiles:
            reasons.append("PROFILE_NOT_ALLOWED")
        if task_allowed_profiles and candidate["profileId"] not in task_allowed_profiles:
            reasons.append("TASK_PROFILE_NOT_ALLOWED")
        if not set(task["requirements"]["capabilities"]).issubset(compatibility["capabilities"]):
            reasons.append("CAPABILITY_MISSING")
        if not set(task["requirements"]["tools"]).issubset(compatibility["tools"]):
            reasons.append("TOOL_MISSING")
        if not set(task["requirements"]["modalities"]).issubset(compatibility["modalities"]):
            reasons.append("MODALITY_MISSING")
        if compatibility["contextWindowTokens"] < required_context:
            reasons.append("CONTEXT_INSUFFICIENT")
        if not task_data_classes.issubset(policy_data_classes) or not task_data_classes.issubset(compatibility["dataClasses"]):
            reasons.append("DATA_POLICY_MISMATCH")
        lane = task["requirements"]["laneId"]
        if lane is not None and compatibility["laneIds"] and lane not in compatibility["laneIds"]:
            reasons.append("LANE_INCOMPATIBLE")
        host = task["requirements"]["hostId"]
        if host is not None and compatibility["hostIds"] and host not in compatibility["hostIds"]:
            reasons.append("HOST_INCOMPATIBLE")
        if risk_index[compatibility["maximumRiskClass"]] < risk_index[effective_risk]:
            reasons.append("RISK_FLOOR_MISS")

        estimate = next((item for item in candidate["estimates"] if item["taskClass"] == task["taskClass"]), None)
        if estimate is None:
            reasons.append("ESTIMATE_MISSING")
        else:
            if estimate["recoveryAssumptionId"] != policy["recovery"]["assumptionId"]:
                reasons.append("RECOVERY_ASSUMPTION_MISMATCH")
            if any(estimate[field] is None for field in policy["requiredEstimateFields"]):
                reasons.append("ESTIMATE_MISSING")

        reasons = list(dict.fromkeys(reasons))
        if reasons:
            rejected.append({"candidateId": candidate_id, "reasonCodes": reasons})
            continue
        assert estimate is not None
        quality_bps = estimate["qualityBps"]
        confidence_bps = estimate["confidenceBps"]
        first_tokens = estimate["firstAttemptTokens"]
        retry_probability = estimate["retryProbabilityBps"]
        retry_tokens = estimate["retryTokens"]
        escalation_probability = estimate["escalationProbabilityBps"]
        escalation_tokens = estimate["escalationTokens"]
        latency_ms = estimate["latencyMs"]
        cost_microunits = estimate["costMicrounits"]
        assert all(value is not None for value in (
            quality_bps, confidence_bps, first_tokens, retry_probability, retry_tokens,
            escalation_probability, escalation_tokens, latency_ms, cost_microunits,
        ))
        retry_risk_tokens = ceil_bps(retry_probability, retry_tokens)
        escalation_risk_tokens = ceil_bps(escalation_probability, escalation_tokens)
        expected_total_tokens = first_tokens + retry_risk_tokens + escalation_risk_tokens
        post_estimate_reasons = []
        if confidence_bps < policy["minimumConfidenceBps"]:
            post_estimate_reasons.append("CONFIDENCE_FLOOR_MISS")
        if quality_bps < effective_quality:
            post_estimate_reasons.append("QUALITY_FLOOR_MISS")
        if token_limit is not None and expected_total_tokens > token_limit:
            post_estimate_reasons.append("TOKEN_BUDGET_EXCEEDED")
        if latency_limit is not None and latency_ms > latency_limit:
            post_estimate_reasons.append("LATENCY_BUDGET_EXCEEDED")
        if cost_limit is not None and cost_microunits > cost_limit:
            post_estimate_reasons.append("COST_BUDGET_EXCEEDED")
        if post_estimate_reasons:
            rejected.append({"candidateId": candidate_id, "reasonCodes": post_estimate_reasons})
            continue
        metrics = {
            "qualityBps": quality_bps,
            "confidenceBps": confidence_bps,
            "firstAttemptTokens": first_tokens,
            "retryProbabilityBps": retry_probability,
            "retryTokens": retry_tokens,
            "retryRiskTokens": retry_risk_tokens,
            "escalationProbabilityBps": escalation_probability,
            "escalationTokens": escalation_tokens,
            "escalationRiskTokens": escalation_risk_tokens,
            "expectedTotalTokens": expected_total_tokens,
            "latencyMs": latency_ms,
            "costMicrounits": cost_microunits,
        }
        eligible.append({"candidate": candidate, "metrics": metrics, "continuityRank": continuity_rank(task, candidate)})

    receipt["eligibleCandidateIds"] = sorted(item["candidate"]["candidateId"] for item in eligible)
    receipt["rejectedCandidates"] = rejected
    if not eligible:
        if override:
            receipt["overrideEvidence"].update({"honored": False, "reasonCode": "OVERRIDE_INELIGIBLE"})
            receipt["reasons"] = ["The requested candidate pin failed one or more hard constraints."]
        else:
            receipt["reasons"] = ["No catalog candidate satisfied every hard constraint and evidence floor."]
        validate_decision(receipt)
        return receipt

    frontier = [item for item in eligible if not any(dominates(other, item) for other in eligible if other is not item)]
    ordered = sorted(frontier, key=tie_key)
    selected = ordered[0]
    receipt["status"] = "recommended"
    receipt["paretoFrontierCandidateIds"] = [item["candidate"]["candidateId"] for item in ordered]
    receipt["fallbackCandidateIds"] = [item["candidate"]["candidateId"] for item in ordered[1:]]
    receipt["tieBreakTrace"] = [
        {
            "candidateId": item["candidate"]["candidateId"],
            "expectedTotalTokens": item["metrics"]["expectedTotalTokens"],
            "continuityRank": item["continuityRank"],
            "latencyMs": item["metrics"]["latencyMs"],
            "costMicrounits": item["metrics"]["costMicrounits"],
        }
        for item in ordered
    ]
    candidate = selected["candidate"]
    receipt["recommendation"] = {
        "candidateId": candidate["candidateId"],
        "profileId": candidate["profileId"],
        "providerId": candidate["providerId"],
        "modelId": candidate["modelId"],
        "reasoningSetting": copy.deepcopy(candidate["reasoningSetting"]),
        "expected": selected["metrics"],
        "continuityRank": selected["continuityRank"],
    }
    if override:
        receipt["overrideEvidence"].update({"honored": True, "reasonCode": None})
    mode_reason = " Policy-auto is dry-run only; no execution setting was changed." if policy["mode"] == "policy-auto" else ""
    receipt["reasons"] = [
        f"Selected {candidate['candidateId']} from the constrained Pareto frontier by the deterministic v1 tie-break order.{mode_reason}"
    ]
    validate_decision(receipt)
    return receipt


def median_integer(values: list[int]) -> int | None:
    if not values:
        return None
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle] + 1) // 2


def basis_point_rate(numerator: int, denominator: int) -> int | None:
    return (numerator * 10000) // denominator if denominator else None


def command_hint(tokens: list[str], names: set[str]) -> str | None:
    result = None
    index = 0
    while index < len(tokens):
        token = tokens[index]
        for name in names:
            prefix = name + "="
            if token == name and index + 1 < len(tokens):
                result = tokens[index + 1]
                index += 1
                break
            if token.startswith(prefix):
                result = token[len(prefix):]
                break
        index += 1
    if result is None or not valid_text(result, 256):
        return None
    return result


def parse_lane_map(raw: str) -> list[dict[str, Any]]:
    lanes = []
    for line_number, raw_line in enumerate(raw.splitlines(), 1):
        if not raw_line.strip():
            continue
        fields = raw_line.split("|")
        fail(len(fields) >= 4, "INVALID_LANE_MAP",
             f"OPERATOR_LANES line {line_number} must have at least four pipe-delimited fields")
        lane_id, owner, worktree, branch = fields[:4]
        command = "|".join(fields[4:]) if len(fields) > 4 else ""
        require_id(lane_id, f"OPERATOR_LANES line {line_number} lane id")
        for value, label in ((owner, "owner"), (worktree, "worktree"), (branch, "branch")):
            require_text(value, f"OPERATOR_LANES line {line_number} {label}", 1024)
        try:
            tokens = shlex.split(command) if command else []
        except ValueError:
            tokens = []
        lanes.append({
            "laneId": lane_id,
            "owner": owner,
            "worktree": worktree,
            "branch": branch,
            "commandDigest": digest(command),
            "modelHint": command_hint(tokens, {"--model"}),
            "reasoningHint": command_hint(tokens, {"--reasoning", "--reasoning-effort", "--thinking", "--effort"}),
            "evidenceRef": f"operator.config.env:OPERATOR_LANES:{lane_id}",
        })
    unique_rows(lanes, "laneId", "laneId in OPERATOR_LANES")
    return sorted(lanes, key=lambda item: item["laneId"])


def telemetry_summary(values: list[int | None]) -> dict[str, Any]:
    reported = [value for value in values if value is not None]
    return {
        "reported": len(reported),
        "unknown": len(values) - len(reported),
        "median": median_integer(reported),
    }


def reported_token_total(value: dict[str, Any]) -> int | None:
    return value["totalTokens"] if value["status"] == "reported" else None


def reported_measurement(value: dict[str, Any]) -> int | None:
    return value["value"] if value["status"] == "reported" else None


def suggestion_input(status: str, value: Any, record_count: int) -> dict[str, Any]:
    return {
        "status": status,
        "digest": digest(value) if status == "reported" else None,
        "recordCount": record_count,
    }


def suggest_from_history(project_name: str | None, lane_map: str, tasks: list[dict[str, Any]],
                         outcomes: list[dict[str, Any]], catalog: dict[str, Any] | None,
                         task_status: str, outcome_status: str, catalog_status: str) -> dict[str, Any]:
    for task in tasks:
        validate_task(task)
    for outcome in outcomes:
        validate_outcome(outcome)
    if catalog is not None:
        validate_catalog(catalog)
    lanes = parse_lane_map(lane_map)
    tasks_by_id = unique_rows(tasks, "taskId", "suggestion taskId")
    unique_rows(outcomes, "outcomeId", "suggestion outcomeId")
    candidates_by_id = {
        candidate["candidateId"]: candidate for candidate in catalog["candidates"]
    } if catalog is not None else {}

    missing: list[dict[str, str]] = []
    missing_keys: set[tuple[str, str]] = set()

    def add_missing(code: str, scope: str, severity: str, message: str) -> None:
        key = (code, scope)
        if key in missing_keys:
            return
        missing_keys.add(key)
        missing.append({"code": code, "scope": scope, "severity": severity, "message": message})

    if not lanes:
        add_missing("LANE_SETUP_MISSING", "project", "blocking",
                    "No durable lanes were available from OPERATOR_LANES.")
    for lane in lanes:
        if lane["modelHint"] is None:
            add_missing("LANE_MODEL_HINT_MISSING", f"lane:{lane['laneId']}", "review",
                        "The lane command does not contain an explicit --model value; do not infer one.")
        if lane["reasoningHint"] is None:
            add_missing("LANE_REASONING_HINT_MISSING", f"lane:{lane['laneId']}", "review",
                        "The lane command does not contain an explicit reasoning or thinking value; do not infer one.")
    if task_status == "missing":
        add_missing("TASK_HISTORY_MISSING", "project", "blocking",
                    "Add validated task-demand receipts to model-selection/tasks.jsonl or pass --tasks.")
    elif not tasks:
        add_missing("TASK_HISTORY_EMPTY", "project", "blocking",
                    "The supplied task history contains no task-demand receipts.")
    if outcome_status == "missing":
        add_missing("OUTCOME_HISTORY_MISSING", "project", "blocking",
                    "Add validated outcome receipts to model-selection/outcomes.jsonl or pass --outcomes.")
    elif not outcomes:
        add_missing("OUTCOME_HISTORY_EMPTY", "project", "blocking",
                    "The supplied outcome history contains no outcome receipts.")
    if catalog_status == "missing":
        add_missing("CATALOG_MISSING", "project", "blocking",
                    "Provide a reviewed catalog to resolve candidate IDs to exact provider, model, and reasoning settings.")

    configured_lane_ids = {lane["laneId"] for lane in lanes}
    for task in tasks:
        lane_id = task["requirements"]["laneId"]
        if lane_id is not None and lane_id not in configured_lane_ids:
            add_missing("TASK_LANE_NOT_CONFIGURED", f"lane:{lane_id}", "blocking",
                        "A historical task references a lane absent from the current OPERATOR_LANES setup.")

    task_class_rows = []
    for task_class in sorted({task["taskClass"] for task in tasks}):
        class_tasks = [task for task in tasks if task["taskClass"] == task_class]
        quality_values = sorted({task["qualityFloorBps"] for task in class_tasks})
        task_class_rows.append({
            "taskClass": task_class,
            "taskCount": len(class_tasks),
            "laneIds": sorted({task["requirements"]["laneId"] for task in class_tasks if task["requirements"]["laneId"] is not None}),
            "hostIds": sorted({task["requirements"]["hostId"] for task in class_tasks if task["requirements"]["hostId"] is not None}),
            "riskClasses": sorted({task["riskClass"] for task in class_tasks}),
            "observedQualityFloorBps": {
                "minimum": min(quality_values),
                "maximum": max(quality_values),
                "values": quality_values,
            },
        })

    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for outcome in outcomes:
        task = tasks_by_id.get(outcome["taskId"])
        if task is None:
            add_missing("TASK_RECEIPT_MISSING", f"outcome:{outcome['outcomeId']}", "blocking",
                        "The outcome references a task absent from the supplied task history.")
            continue
        execution = outcome["actualExecution"]
        if execution is None:
            add_missing("ACTUAL_EXECUTION_MISSING", f"outcome:{outcome['outcomeId']}", "review",
                        "The outcome has no actual candidate execution and cannot inform a candidate suggestion.")
            continue
        candidate_id = execution["candidateId"]
        grouped.setdefault((candidate_id, task["taskClass"]), []).append(outcome)

    candidate_rows = []
    for (candidate_id, task_class), candidate_outcomes in sorted(grouped.items()):
        candidate = candidates_by_id.get(candidate_id)
        identity = None
        if candidate is None:
            add_missing("CANDIDATE_IDENTITY_MISSING", f"candidate:{candidate_id}", "blocking",
                        "The candidate is absent from the catalog, so provider, model, profile, and reasoning remain unknown.")
        else:
            identity = {
                "providerId": candidate["providerId"],
                "modelId": candidate["modelId"],
                "profileId": candidate["profileId"],
                "reasoningSetting": copy.deepcopy(candidate["reasoningSetting"]),
                "enabled": candidate["enabled"],
                "availability": candidate["availability"],
            }
            if not candidate["enabled"] or candidate["availability"] != "available":
                add_missing("CANDIDATE_AVAILABILITY_REVIEW_REQUIRED", f"candidate:{candidate_id}", "blocking",
                            "Historical evidence exists, but the catalog does not mark this candidate enabled and available.")

        accepted = sum(outcome["acceptance"]["status"] == "accepted" for outcome in candidate_outcomes)
        acceptance_known = sum(outcome["acceptance"]["status"] != "unknown" for outcome in candidate_outcomes)
        acceptance_unknown = len(candidate_outcomes) - acceptance_known
        validation_counts = {
            "passed": sum(outcome["validation"]["status"] == "passed" for outcome in candidate_outcomes),
            "failed": sum(outcome["validation"]["status"] == "failed" for outcome in candidate_outcomes),
            "notRun": sum(outcome["validation"]["status"] == "not_run" for outcome in candidate_outcomes),
            "unknown": sum(outcome["validation"]["status"] == "unknown" for outcome in candidate_outcomes),
        }
        first_attempt_tokens = []
        for outcome in candidate_outcomes:
            if outcome["attempts"]:
                first_attempt_tokens.append(reported_token_total(outcome["attempts"][0]["tokenUsage"]))
            else:
                first_attempt_tokens.append(None)
        total_tokens = [reported_token_total(outcome["totalTokenUsage"]) for outcome in candidate_outcomes]
        latency = [reported_measurement(outcome["totalLatencyMs"]) for outcome in candidate_outcomes]
        cost = [reported_measurement(outcome["totalCostMicrounits"]) for outcome in candidate_outcomes]
        retry_any = sum(outcome["retryCount"] > 0 for outcome in candidate_outcomes)
        escalation_any = sum(outcome["escalationCount"] > 0 for outcome in candidate_outcomes)
        handoff_any = sum(outcome["handoffCount"] > 0 for outcome in candidate_outcomes)
        correction_true = sum(outcome["humanCorrection"] is True for outcome in candidate_outcomes)
        correction_false = sum(outcome["humanCorrection"] is False for outcome in candidate_outcomes)
        correction_known = correction_true + correction_false
        candidate_rows.append({
            "candidateId": candidate_id,
            "taskClass": task_class,
            "catalogIdentity": identity,
            "taskIds": sorted({outcome["taskId"] for outcome in candidate_outcomes}),
            "outcomeIds": sorted(outcome["outcomeId"] for outcome in candidate_outcomes),
            "sampleCount": len(candidate_outcomes),
            "acceptedOutcomeRate": {
                "accepted": accepted,
                "known": acceptance_known,
                "unknown": acceptance_unknown,
                "rateBps": basis_point_rate(accepted, acceptance_known),
            },
            "validationCounts": validation_counts,
            "firstAttemptTokens": telemetry_summary(first_attempt_tokens),
            "totalTokens": telemetry_summary(total_tokens),
            "latencyMs": telemetry_summary(latency),
            "costMicrounits": telemetry_summary(cost),
            "retry": {
                "outcomesWithAny": retry_any,
                "totalCount": sum(outcome["retryCount"] for outcome in candidate_outcomes),
                "rateBps": basis_point_rate(retry_any, len(candidate_outcomes)) or 0,
            },
            "escalation": {
                "outcomesWithAny": escalation_any,
                "totalCount": sum(outcome["escalationCount"] for outcome in candidate_outcomes),
                "rateBps": basis_point_rate(escalation_any, len(candidate_outcomes)) or 0,
            },
            "handoff": {
                "outcomesWithAny": handoff_any,
                "totalCount": sum(outcome["handoffCount"] for outcome in candidate_outcomes),
                "rateBps": basis_point_rate(handoff_any, len(candidate_outcomes)) or 0,
            },
            "humanCorrection": {
                "true": correction_true,
                "false": correction_false,
                "unknown": len(candidate_outcomes) - correction_known,
                "rateBps": basis_point_rate(correction_true, correction_known),
            },
        })
        if acceptance_unknown:
            add_missing("ACCEPTANCE_EVIDENCE_INCOMPLETE", f"candidate:{candidate_id}", "review",
                        "At least one outcome has unknown acceptance and is excluded from the accepted-outcome rate.")
        if any(value is None for value in total_tokens + latency + cost):
            add_missing("TELEMETRY_INCOMPLETE", f"candidate:{candidate_id}", "review",
                        "At least one outcome has unknown token, latency, or cost telemetry; unknown values remain excluded, never zero.")

    shortlists = []
    for task_class in sorted({row["taskClass"] for row in candidate_rows}):
        eligible_rows = [
            row for row in candidate_rows
            if row["taskClass"] == task_class
            and row["acceptedOutcomeRate"]["known"] >= MINIMUM_SUGGESTION_OUTCOMES
            and row["catalogIdentity"] is not None
            and row["catalogIdentity"]["enabled"] is True
            and row["catalogIdentity"]["availability"] == "available"
        ]
        if eligible_rows:
            ordered = sorted(eligible_rows, key=lambda row: (
                -(row["acceptedOutcomeRate"]["rateBps"] if row["acceptedOutcomeRate"]["rateBps"] is not None else -1),
                -row["acceptedOutcomeRate"]["known"],
                row["totalTokens"]["median"] if row["totalTokens"]["median"] is not None else sys.maxsize,
                row["candidateId"],
            ))
            shortlists.append({
                "taskClass": task_class,
                "candidateIds": [row["candidateId"] for row in ordered],
                "minimumKnownOutcomes": MINIMUM_SUGGESTION_OUTCOMES,
                "method": "Observed accepted-outcome rate descending, known sample count descending, median total tokens ascending, then candidate ID.",
            })
        else:
            add_missing("INSUFFICIENT_OUTCOME_SAMPLES", f"taskClass:{task_class}", "review",
                        f"No catalog-resolved candidate has {MINIMUM_SUGGESTION_OUTCOMES} known outcomes for this task class.")

    if outcomes and not candidate_rows:
        add_missing("CANDIDATE_EVIDENCE_MISSING", "project", "blocking",
                    "No supplied outcome could be joined to a task and actual candidate execution.")
    add_missing("RISK_FLOOR_REVIEW_REQUIRED", "policy", "review",
                "Observed risk-class labels do not establish their ordering or an acceptable minimum; review the risk policy.")
    add_missing("DATA_POLICY_REVIEW_REQUIRED", "policy", "review",
                "Historical receipts do not authorize data classes or credential capabilities; review them explicitly.")
    add_missing("BUDGET_REVIEW_REQUIRED", "policy", "review",
                "Review token, latency, and cost limits before creating or changing a live policy.")
    add_missing("USER_PREFERENCES_REQUIRED", "policy", "review",
                "Confirm preferred profiles, continuity behavior, pins, and override rules with the user.")

    shortlisted_candidate_ids = sorted({
        candidate_id for shortlist in shortlists for candidate_id in shortlist["candidateIds"]
    })
    policy_hints = {
        "mode": "off",
        "requiresHumanReview": True,
        "taskClasses": sorted({task["taskClass"] for task in tasks}),
        "laneIds": sorted(configured_lane_ids),
        "hostIds": sorted({task["requirements"]["hostId"] for task in tasks if task["requirements"]["hostId"] is not None}),
        "candidateIds": shortlisted_candidate_ids,
        "profileIds": sorted({
            row["catalogIdentity"]["profileId"] for row in candidate_rows
            if row["catalogIdentity"] is not None and row["candidateId"] in shortlisted_candidate_ids
        }),
        "candidateShortlists": shortlists,
        "qualityFloors": [{
            "taskClass": row["taskClass"],
            "observedValuesBps": row["observedQualityFloorBps"]["values"],
            "suggestedMinimumBps": row["observedQualityFloorBps"]["maximum"],
            "basis": "Retain the highest explicit quality floor observed in historical task-demand receipts; human review is required.",
        } for row in task_class_rows],
        "limits": {
            "maximumExpectedTokens": None,
            "maximumLatencyMs": None,
            "maximumCostMicrounits": None,
        },
    }
    inputs = {
        "laneMap": suggestion_input("reported" if lanes else "missing", lane_map, len(lanes)),
        "tasks": suggestion_input(task_status, tasks, len(tasks)),
        "outcomes": suggestion_input(outcome_status, outcomes, len(outcomes)),
        "catalog": suggestion_input(catalog_status, catalog, len(catalog["candidates"]) if catalog is not None else 0),
    }
    evidence_fingerprint = digest({
        "algorithmVersion": SUGGESTION_ALGORITHM_VERSION,
        "inputs": inputs,
    })
    missing = sorted(missing, key=lambda row: (row["severity"], row["code"], row["scope"]))
    receipt = {
        "schemaVersion": SUGGESTION_VERSION,
        "suggestionId": "suggestion-" + evidence_fingerprint.removeprefix("sha256:")[:32],
        "evidenceFingerprint": evidence_fingerprint,
        "algorithmVersion": SUGGESTION_ALGORITHM_VERSION,
        "status": "needs_input" if any(row["severity"] == "blocking" for row in missing) else "draft_ready",
        "projectName": project_name,
        "inputs": inputs,
        "authority": {
            "mode": "advisory",
            "recommendationOnly": True,
            "writesFiles": False,
            "appliesSettings": False,
            "dispatchesWork": False,
            "onlineLearning": False,
            "draftPolicyMode": "off",
        },
        "laneObservations": lanes,
        "taskClassObservations": task_class_rows,
        "candidateObservations": candidate_rows,
        "policyHints": policy_hints,
        "missingInputs": missing,
    }
    validate_suggestion(receipt)
    return receipt


def arm_metrics(cases: list[dict[str, Any]], arm: str) -> dict[str, Any]:
    selected = 0
    abstained = 0
    missing_outcomes = 0
    acceptance_known = 0
    accepted = 0
    token_known = 0
    token_unknown = 0
    total_tokens = 0
    accepted_with_known_tokens = 0
    accepted_token_totals = []
    for case in cases:
        result = case[arm]
        if result["candidateId"] is None:
            abstained += 1
            continue
        selected += 1
        outcome = result.get("outcome")
        if outcome is None:
            missing_outcomes += 1
            continue
        acceptance = outcome["acceptance"]["status"]
        token_usage = outcome["totalTokenUsage"]
        if acceptance != "unknown":
            acceptance_known += 1
            if acceptance == "accepted":
                accepted += 1
        if token_usage["status"] == "reported":
            token_known += 1
            task_tokens = token_usage["totalTokens"]
            total_tokens += task_tokens
            if acceptance == "accepted":
                accepted_with_known_tokens += 1
                accepted_token_totals.append(task_tokens)
        else:
            token_unknown += 1
    rate_bps = (accepted * 10000) // acceptance_known if acceptance_known else None
    per_million = (accepted_with_known_tokens * 1_000_000) // total_tokens if total_tokens else None
    return {
        "tasks": len(cases),
        "selected": selected,
        "abstained": abstained,
        "missingOutcomes": missing_outcomes,
        "acceptedOutcomeRate": {"accepted": accepted, "known": acceptance_known, "rateBps": rate_bps},
        "tokenTelemetry": {"reported": token_known, "unknown": token_unknown, "totalTokens": total_tokens},
        "acceptedOutcomesPerToken": {
            "acceptedWithReportedTokens": accepted_with_known_tokens,
            "totalReportedTokens": total_tokens,
            "perMillionTokens": per_million,
        },
        "medianTotalTokensPerAcceptedTask": median_integer(accepted_token_totals),
        "medianMethod": "integer-ceiling-midpoint",
    }


def replay(tasks: list[dict[str, Any]], outcomes: list[dict[str, Any]], catalog: dict[str, Any],
           policy: dict[str, Any], baseline_candidate: str | None) -> dict[str, Any]:
    validate_catalog(catalog)
    validate_policy(policy)
    for task in tasks:
        validate_task(task)
    for outcome in outcomes:
        validate_outcome(outcome)
    tasks_by_id = unique_rows(tasks, "taskId", "replay taskId")
    unique_rows(outcomes, "outcomeId", "replay outcomeId")
    candidates = {candidate["candidateId"] for candidate in catalog["candidates"]}
    if baseline_candidate is not None:
        require_id(baseline_candidate, "baseline candidate")
        fail(baseline_candidate in candidates, "INVALID_REFERENCE", "baseline candidate is not present in the catalog")
    outcome_by_key: dict[tuple[str, str], dict[str, Any]] = {}
    for outcome in outcomes:
        fail(outcome["taskId"] in tasks_by_id, "INVALID_REFERENCE",
             f"outcome {outcome['outcomeId']} references a task absent from the replay corpus")
        fail(outcome["catalogId"] == catalog["catalogId"] and outcome["catalogRevision"] == catalog["revision"],
             "INVALID_REFERENCE", f"outcome {outcome['outcomeId']} references a different catalog revision")
        fail(outcome["policyId"] == policy["policyId"] and outcome["policyRevision"] == policy["revision"],
             "INVALID_REFERENCE", f"outcome {outcome['outcomeId']} references a different policy revision")
        for attempt in outcome["attempts"]:
            attempt_candidate = attempt["execution"]["candidateId"]
            fail(attempt_candidate in candidates, "INVALID_REFERENCE",
                 f"outcome {outcome['outcomeId']} attempt references unknown candidate {attempt_candidate}")
        execution = outcome["actualExecution"]
        if execution is None:
            continue
        candidate_id = execution["candidateId"]
        fail(candidate_id in candidates, "INVALID_REFERENCE", f"outcome {outcome['outcomeId']} references unknown candidate {candidate_id}")
        key = (outcome["taskId"], candidate_id)
        fail(key not in outcome_by_key, "DUPLICATE_ID", f"multiple outcomes exist for task/candidate {key}")
        outcome_by_key[key] = outcome

    cases = []
    for task in sorted(tasks, key=lambda item: item["taskId"]):
        adaptive_decision = recommend(task, catalog, policy)
        adaptive_candidate = adaptive_decision["recommendation"]["candidateId"] if adaptive_decision["recommendation"] else None
        adaptive_outcome = outcome_by_key.get((task["taskId"], adaptive_candidate)) if adaptive_candidate else None
        adaptive_case = {
            "status": adaptive_decision["status"],
            "candidateId": adaptive_candidate,
            "outcomeId": adaptive_outcome["outcomeId"] if adaptive_outcome else None,
            "outcome": adaptive_outcome,
        }
        baseline_case = {"status": "not_configured", "candidateId": None, "outcomeId": None, "outcome": None}
        if baseline_candidate is not None:
            baseline_outcome = outcome_by_key.get((task["taskId"], baseline_candidate))
            baseline_case = {
                "status": "fixed",
                "candidateId": baseline_candidate,
                "outcomeId": baseline_outcome["outcomeId"] if baseline_outcome else None,
                "outcome": baseline_outcome,
            }
        cases.append({"taskId": task["taskId"], "adaptive": adaptive_case, "baseline": baseline_case})

    adaptive_metrics = arm_metrics(cases, "adaptive")
    baseline_metrics = arm_metrics(cases, "baseline") if baseline_candidate is not None else None
    comparison = None
    if baseline_metrics is not None:
        adaptive_rate = adaptive_metrics["acceptedOutcomeRate"]["rateBps"]
        baseline_rate = baseline_metrics["acceptedOutcomeRate"]["rateBps"]
        adaptive_per_token = adaptive_metrics["acceptedOutcomesPerToken"]["perMillionTokens"]
        baseline_per_token = baseline_metrics["acceptedOutcomesPerToken"]["perMillionTokens"]
        adaptive_median = adaptive_metrics["medianTotalTokensPerAcceptedTask"]
        baseline_median = baseline_metrics["medianTotalTokensPerAcceptedTask"]
        comparison = {
            "acceptedOutcomeRateDeltaBps": adaptive_rate - baseline_rate if adaptive_rate is not None and baseline_rate is not None else None,
            "acceptedOutcomesPerMillionTokensDelta": adaptive_per_token - baseline_per_token
            if adaptive_per_token is not None and baseline_per_token is not None else None,
            "medianTotalTokensPerAcceptedTaskDelta": adaptive_median - baseline_median
            if adaptive_median is not None and baseline_median is not None else None,
        }
    public_cases = []
    for case in cases:
        public_cases.append({
            "taskId": case["taskId"],
            "adaptive": {key: case["adaptive"][key] for key in ("status", "candidateId", "outcomeId")},
            "baseline": {key: case["baseline"][key] for key in ("status", "candidateId", "outcomeId")},
        })
    return {
        "schemaVersion": REPLAY_VERSION,
        "algorithmVersion": ALGORITHM_VERSION,
        "catalogDigest": digest(catalog),
        "policyDigest": digest(policy),
        "baselineCandidateId": baseline_candidate,
        "cases": public_cases,
        "adaptive": adaptive_metrics,
        "baseline": baseline_metrics,
        "comparison": comparison,
    }


def emit(value: Any) -> None:
    print(canonical_json(value))


def parser() -> argparse.ArgumentParser:
    root = SelectorArgumentParser(
        prog="operator-model-select",
        description="Deterministic advisory model selector (no dispatch or graph mutation)",
        epilog="Exit 0: recommendation/validation/replay/suggestion; exit 3: valid off or needs_override; exit 2: invalid input/usage/I/O.",
    )
    root.add_argument("--operator-dir", required=True)
    root.add_argument("--project-name")
    root.add_argument("--lane-map", default="")
    commands = root.add_subparsers(dest="command", required=True)

    validate = commands.add_parser("validate")
    validate.add_argument("--kind", choices=sorted(VALIDATORS), required=True)
    validate.add_argument("file")

    recommend_parser = commands.add_parser("recommend")
    recommend_parser.add_argument("--task", required=True)
    recommend_parser.add_argument("--catalog")
    recommend_parser.add_argument("--policy")

    replay_parser = commands.add_parser("replay")
    replay_parser.add_argument("--tasks", required=True)
    replay_parser.add_argument("--outcomes", required=True)
    replay_parser.add_argument("--catalog")
    replay_parser.add_argument("--policy")
    replay_parser.add_argument("--baseline-candidate")

    suggest_parser = commands.add_parser("suggest-from-history")
    suggest_parser.add_argument("--tasks")
    suggest_parser.add_argument("--outcomes")
    suggest_parser.add_argument("--catalog")
    return root


def main(argv: Iterable[str] | None = None) -> int:
    args = parser().parse_args(argv)
    operator_dir = Path(args.operator_dir)
    if args.command == "validate":
        value = load_json(Path(args.file), args.kind)
        VALIDATORS[args.kind](value)
        emit({"kind": args.kind, "ok": True, "schemaVersion": value["schemaVersion"]})
        return EXIT_OK
    if args.command == "suggest-from-history":
        default_root = operator_dir / "model-selection"
        task_path = Path(args.tasks) if args.tasks else default_root / "tasks.jsonl"
        outcome_path = Path(args.outcomes) if args.outcomes else default_root / "outcomes.jsonl"
        catalog_path = Path(args.catalog) if args.catalog else default_root / "catalog.json"
        if args.tasks or task_path.is_file():
            tasks = load_jsonl(task_path, "tasks")
            task_status = "reported"
        else:
            tasks = []
            task_status = "missing"
        if args.outcomes or outcome_path.is_file():
            outcomes = load_jsonl(outcome_path, "outcomes")
            outcome_status = "reported"
        else:
            outcomes = []
            outcome_status = "missing"
        if args.catalog or catalog_path.is_file():
            catalog = load_json(catalog_path, "catalog")
            catalog_status = "reported"
        else:
            catalog = None
            catalog_status = "missing"
        suggestion = suggest_from_history(
            args.project_name,
            args.lane_map,
            tasks,
            outcomes,
            catalog,
            task_status,
            outcome_status,
            catalog_status,
        )
        emit(suggestion)
        return EXIT_OK
    catalog_path = Path(args.catalog) if args.catalog else operator_dir / "model-selection" / "catalog.json"
    policy_path = Path(args.policy) if args.policy else operator_dir / "model-selection" / "policy.json"
    catalog = load_json(catalog_path, "catalog")
    policy = load_json(policy_path, "policy")
    if args.command == "recommend":
        task = load_json(Path(args.task), "task")
        decision = recommend(task, catalog, policy)
        emit(decision)
        return EXIT_OK if decision["status"] == "recommended" else EXIT_NO_RECOMMENDATION
    if args.command == "replay":
        tasks = load_jsonl(Path(args.tasks), "tasks")
        outcomes = load_jsonl(Path(args.outcomes), "outcomes")
        report = replay(tasks, outcomes, catalog, policy, args.baseline_candidate)
        emit(report)
        return EXIT_OK
    raise SelectorError("USAGE", f"unsupported command: {args.command}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SelectorError as exc:
        print(canonical_json({"ok": False, "error": {"code": exc.code, "message": exc.message}}), file=sys.stderr)
        raise SystemExit(EXIT_INVALID)
