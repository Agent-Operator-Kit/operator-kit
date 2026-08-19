#!/usr/bin/env bash
set -euo pipefail

unset OPERATOR_CONFIG OPERATOR_DIR PROJECT_NAME PROJECT_ROOT CODE_DIR
unset TMUX_SESSION DEFAULT_BRANCH OPERATOR_LANES OPERATOR_KIT_VERSION

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$KIT_ROOT/tests/fixtures/model-selection/v1"
tmp_root="$(mktemp -d /tmp/operator-model-selector-smoke.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

operator_dir="$tmp_root/operator"
config_file="$tmp_root/operator.config.env"
mkdir -p "$operator_dir/model-selection"
cp "$FIXTURES/catalog.json" "$operator_dir/model-selection/catalog.json"
cp "$FIXTURES/policy.json" "$operator_dir/model-selection/policy.json"

cat >"$config_file" <<EOF
PROJECT_NAME="model-selector-smoke"
PROJECT_ROOT="$tmp_root"
CODE_DIR="$KIT_ROOT"
OPERATOR_DIR="$operator_dir"
TMUX_SESSION="model-selector-smoke"
DEFAULT_BRANCH="main"
OPERATOR_KIT_VERSION="5.1"
OPERATOR_LANES="model-strategy"
EOF

selector() {
  OPERATOR_CONFIG="$config_file" bash "$KIT_ROOT/scripts/operator-model-select.sh" "$@"
}

expect_exit() {
  local expected="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  shift 3
  local actual
  set +e
  "$@" >"$stdout_file" 2>"$stderr_file"
  actual=$?
  set -e
  [ "$actual" -eq "$expected" ] || {
    cat "$stderr_file" >&2 || true
    fail "expected exit $expected, got $actual: $*"
  }
}

sed -n '2p' "$FIXTURES/tasks.jsonl" >"$tmp_root/task.json"
sed -n '1p' "$FIXTURES/outcomes.jsonl" >"$tmp_root/outcome.json"
sed -n '7p' "$FIXTURES/outcomes.jsonl" >"$tmp_root/outcome-unknown.json"

selector validate --kind task "$tmp_root/task.json" >/dev/null
selector validate --kind catalog "$FIXTURES/catalog.json" >/dev/null
selector validate --kind policy "$FIXTURES/policy.json" >/dev/null
selector validate --kind outcome "$tmp_root/outcome.json" >/dev/null
selector validate --kind outcome "$tmp_root/outcome-unknown.json" >/dev/null

/usr/bin/python3 - "$FIXTURES/catalog.json" "$FIXTURES/policy.json" "$tmp_root/task.json" "$tmp_root" <<'PY'
import copy
import json
import pathlib
import sys

catalog_path, policy_path, task_path, output_raw = sys.argv[1:]
output = pathlib.Path(output_raw)
catalog = json.loads(pathlib.Path(catalog_path).read_text())
policy = json.loads(pathlib.Path(policy_path).read_text())
task = json.loads(pathlib.Path(task_path).read_text())


def write(name, value):
    (output / name).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


coverage = copy.deepcopy(catalog)
source = next(item for item in catalog["candidates"] if item["candidateId"] == "steady-balanced")


def candidate(candidate_id):
    value = copy.deepcopy(source)
    value["candidateId"] = candidate_id
    value["modelId"] = "synthetic/" + candidate_id
    value["estimates"][0]["escalationTargetCandidateId"] = "tie-a"
    return value


variants = []
value = candidate("reject-capability")
value["compatibility"]["capabilities"] = ["structured-output"]
variants.append(value)
value = candidate("reject-tool")
value["compatibility"]["tools"] = []
variants.append(value)
value = candidate("reject-context")
value["compatibility"]["contextWindowTokens"] = 12000
variants.append(value)
value = candidate("reject-data")
value["compatibility"]["dataClasses"] = ["public"]
variants.append(value)
value = candidate("reject-risk")
value["compatibility"]["maximumRiskClass"] = "low"
variants.append(value)
value = candidate("reject-quality")
value["estimates"][0]["qualityBps"] = 8000
variants.append(value)
value = candidate("reject-confidence")
value["estimates"][0]["confidenceBps"] = 6000
variants.append(value)
value = candidate("reject-missing-estimate")
value["estimates"][0]["retryTokens"] = None
variants.append(value)
value = candidate("reject-unavailable")
value["availability"] = "unavailable"
variants.append(value)
coverage["candidates"].extend(variants)
write("coverage-catalog.json", coverage)

tie_lexical = copy.deepcopy(task)
tie_lexical["taskId"] = "tie-lexical"
tie_lexical["taskClass"] = "tie-work"
tie_lexical["qualityFloorBps"] = 9000
tie_lexical["constraints"]["allowedProfileIds"] = ["deep"]
tie_lexical["constraints"]["continuity"] = None
write("tie-lexical-task.json", tie_lexical)

tie_continuity = copy.deepcopy(tie_lexical)
tie_continuity["taskId"] = "tie-continuity"
tie_continuity["constraints"]["continuity"] = {"candidateId": "tie-b", "profileId": "deep"}
write("tie-continuity-task.json", tie_continuity)

valid_pin = copy.deepcopy(task)
valid_pin["taskId"] = "valid-pin"
valid_pin["constraints"]["override"] = {"candidateId": "baseline-cheap", "reason": "Synthetic valid user pin."}
write("valid-pin-task.json", valid_pin)

invalid_pin = copy.deepcopy(task)
invalid_pin["taskId"] = "invalid-pin"
invalid_pin["constraints"]["override"] = {"candidateId": "reject-risk", "reason": "Synthetic invalid user pin."}
write("invalid-pin-task.json", invalid_pin)

unknown_pin = copy.deepcopy(task)
unknown_pin["taskId"] = "unknown-pin"
unknown_pin["constraints"]["override"] = {"candidateId": "not-in-catalog", "reason": "Synthetic unknown user pin."}
write("unknown-pin-task.json", unknown_pin)

no_eligible = copy.deepcopy(task)
no_eligible["taskId"] = "no-eligible"
no_eligible["requirements"]["capabilities"] = ["image-generation"]
write("no-eligible-task.json", no_eligible)

low_confidence = copy.deepcopy(task)
low_confidence["taskId"] = "low-confidence"
low_confidence["constraints"]["override"] = {"candidateId": "reject-confidence", "reason": "Exercise confidence floor."}
write("low-confidence-task.json", low_confidence)

missing_estimate = copy.deepcopy(task)
missing_estimate["taskId"] = "missing-estimate"
missing_estimate["constraints"]["override"] = {"candidateId": "reject-missing-estimate", "reason": "Exercise missing estimate handling."}
write("missing-estimate-task.json", missing_estimate)

policy_auto = copy.deepcopy(policy)
policy_auto["mode"] = "policy-auto"
write("policy-auto.json", policy_auto)
policy_off = copy.deepcopy(policy)
policy_off["mode"] = "off"
write("policy-off.json", policy_off)

stale = copy.deepcopy(catalog)
stale["validUntil"] = "2026-08-18T23:59:59Z"
write("stale-catalog.json", stale)
duplicate = copy.deepcopy(catalog)
duplicate["candidates"].append(copy.deepcopy(duplicate["candidates"][0]))
write("duplicate-catalog.json", duplicate)
bad_probability = copy.deepcopy(catalog)
bad_probability["candidates"][0]["estimates"][0]["retryProbabilityBps"] = 10001
write("bad-probability-catalog.json", bad_probability)

bad_tie = copy.deepcopy(policy)
bad_tie["tieBreakOrder"] = list(reversed(bad_tie["tieBreakOrder"]))
write("bad-tie-policy.json", bad_tie)
bad_authority = copy.deepcopy(policy)
bad_authority["authority"]["recommendationOnly"] = False
write("bad-authority-policy.json", bad_authority)
bad_risk = copy.deepcopy(policy)
bad_risk["riskClassOrder"].append("low")
write("bad-risk-policy.json", bad_risk)
bad_recovery = copy.deepcopy(policy)
bad_recovery["recovery"]["includeEscalation"] = False
write("bad-recovery-policy.json", bad_recovery)

extra_task = copy.deepcopy(task)
extra_task["unknownField"] = True
write("extra-task.json", extra_task)
PY

selector recommend --task "$tmp_root/task.json" --catalog "$tmp_root/coverage-catalog.json" \
  --policy "$FIXTURES/policy.json" >"$tmp_root/decision-a.json"
selector recommend --task "$tmp_root/task.json" --catalog "$tmp_root/coverage-catalog.json" \
  --policy "$FIXTURES/policy.json" >"$tmp_root/decision-b.json"
selector validate --kind decision "$tmp_root/decision-a.json" >/dev/null

/usr/bin/python3 - "$tmp_root/decision-a.json" "$tmp_root/decision-b.json" <<'PY'
import json
import sys

first, second = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert first["status"] == "recommended"
assert first["recommendation"]["candidateId"] == "steady-balanced"
expected = first["recommendation"]["expected"]
assert expected["retryRiskTokens"] == 50
assert expected["escalationRiskTokens"] == 75
assert expected["expectedTotalTokens"] == 1325
assert "dominated-balanced" in first["eligibleCandidateIds"]
assert "dominated-balanced" not in first["paretoFrontierCandidateIds"]
assert first["selectionFingerprint"] == second["selectionFingerprint"]
assert first["decisionId"] == second["decisionId"]
assert first["recommendation"] == second["recommendation"]
assert first["authority"] == {
    "mode": "advisory",
    "dispatchPerformed": False,
    "graphMutated": False,
    "executionSettingsChanged": False,
}
rejections = {row["candidateId"]: set(row["reasonCodes"]) for row in first["rejectedCandidates"]}
expected_rejections = {
    "reject-capability": "CAPABILITY_MISSING",
    "reject-tool": "TOOL_MISSING",
    "reject-context": "CONTEXT_INSUFFICIENT",
    "reject-data": "DATA_POLICY_MISMATCH",
    "reject-risk": "RISK_FLOOR_MISS",
    "reject-quality": "QUALITY_FLOOR_MISS",
    "reject-confidence": "CONFIDENCE_FLOOR_MISS",
    "reject-missing-estimate": "ESTIMATE_MISSING",
    "reject-unavailable": "UNAVAILABLE",
}
for candidate_id, reason in expected_rejections.items():
    assert reason in rejections[candidate_id], (candidate_id, rejections[candidate_id])
PY

/usr/bin/python3 - "$KIT_ROOT" "$tmp_root/coverage-catalog.json" "$FIXTURES/policy.json" "$tmp_root/task.json" <<'PY'
import json
import pathlib
import sys

root, catalog_path, policy_path, task_path = sys.argv[1:]
sys.path.insert(0, str(pathlib.Path(root) / "scripts"))
from operator_model_selector import recommend

catalog = json.load(open(catalog_path, encoding="utf-8"))
policy = json.load(open(policy_path, encoding="utf-8"))
task = json.load(open(task_path, encoding="utf-8"))
first = recommend(task, catalog, policy, generated_at="2026-08-19T12:00:00Z")
second = recommend(task, catalog, policy, generated_at="2026-08-19T12:00:01Z")
assert first["generatedAt"] != second["generatedAt"]
assert first["selectionFingerprint"] == second["selectionFingerprint"]
assert first["recommendation"] == second["recommendation"]
PY

selector recommend --task "$tmp_root/tie-lexical-task.json" --catalog "$FIXTURES/catalog.json" \
  --policy "$FIXTURES/policy.json" >"$tmp_root/tie-lexical.json"
selector recommend --task "$tmp_root/tie-continuity-task.json" --catalog "$FIXTURES/catalog.json" \
  --policy "$FIXTURES/policy.json" >"$tmp_root/tie-continuity.json"
selector recommend --task "$tmp_root/valid-pin-task.json" --catalog "$tmp_root/coverage-catalog.json" \
  --policy "$FIXTURES/policy.json" >"$tmp_root/valid-pin.json"

/usr/bin/python3 - "$tmp_root/tie-lexical.json" "$tmp_root/tie-continuity.json" "$tmp_root/valid-pin.json" <<'PY'
import json
import sys

lexical, continuity, valid_pin = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert lexical["recommendation"]["candidateId"] == "tie-a"
assert continuity["recommendation"]["candidateId"] == "tie-b"
assert continuity["recommendation"]["continuityRank"] == 0
assert valid_pin["recommendation"]["candidateId"] == "baseline-cheap"
assert valid_pin["overrideEvidence"]["honored"] is True
PY

expect_exit 3 "$tmp_root/invalid-pin.json" "$tmp_root/invalid-pin.err" selector recommend \
  --task "$tmp_root/invalid-pin-task.json" --catalog "$tmp_root/coverage-catalog.json" --policy "$FIXTURES/policy.json"
expect_exit 3 "$tmp_root/unknown-pin.json" "$tmp_root/unknown-pin.err" selector recommend \
  --task "$tmp_root/unknown-pin-task.json" --catalog "$tmp_root/coverage-catalog.json" --policy "$FIXTURES/policy.json"
expect_exit 3 "$tmp_root/no-eligible.json" "$tmp_root/no-eligible.err" selector recommend \
  --task "$tmp_root/no-eligible-task.json" --catalog "$tmp_root/coverage-catalog.json" --policy "$FIXTURES/policy.json"
expect_exit 3 "$tmp_root/low-confidence.json" "$tmp_root/low-confidence.err" selector recommend \
  --task "$tmp_root/low-confidence-task.json" --catalog "$tmp_root/coverage-catalog.json" --policy "$FIXTURES/policy.json"
expect_exit 3 "$tmp_root/missing-estimate.json" "$tmp_root/missing-estimate.err" selector recommend \
  --task "$tmp_root/missing-estimate-task.json" --catalog "$tmp_root/coverage-catalog.json" --policy "$FIXTURES/policy.json"
expect_exit 3 "$tmp_root/off.json" "$tmp_root/off.err" selector recommend \
  --task "$tmp_root/task.json" --catalog "$FIXTURES/catalog.json" --policy "$tmp_root/policy-off.json"

/usr/bin/python3 - "$tmp_root/invalid-pin.json" "$tmp_root/unknown-pin.json" "$tmp_root/no-eligible.json" \
  "$tmp_root/low-confidence.json" "$tmp_root/missing-estimate.json" "$tmp_root/off.json" <<'PY'
import json
import sys

invalid_pin, unknown_pin, no_eligible, low_confidence, missing_estimate, off = [
    json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]
]
assert invalid_pin["status"] == "needs_override" and invalid_pin["overrideEvidence"]["reasonCode"] == "OVERRIDE_INELIGIBLE"
assert unknown_pin["status"] == "needs_override" and unknown_pin["overrideEvidence"]["reasonCode"] == "OVERRIDE_UNKNOWN_CANDIDATE"
assert no_eligible["status"] == "needs_override" and no_eligible["recommendation"] is None
assert low_confidence["status"] == "needs_override"
assert missing_estimate["status"] == "needs_override"
assert off["status"] == "off" and off["recommendation"] is None
PY

selector recommend --task "$tmp_root/task.json" --catalog "$FIXTURES/catalog.json" \
  --policy "$tmp_root/policy-auto.json" >"$tmp_root/policy-auto.json.out"
/usr/bin/python3 - "$tmp_root/policy-auto.json.out" "$tmp_root/decision-a.json" <<'PY'
import json
import sys

auto, regular = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert auto["recommendation"]["candidateId"] == regular["recommendation"]["candidateId"]
assert auto["authority"]["dispatchPerformed"] is False
assert auto["authority"]["graphMutated"] is False
assert auto["authority"]["executionSettingsChanged"] is False
assert "dry-run only" in auto["reasons"][0]
PY

expect_exit 2 "$tmp_root/invalid.out" "$tmp_root/stale.err" selector recommend \
  --task "$tmp_root/task.json" --catalog "$tmp_root/stale-catalog.json" --policy "$FIXTURES/policy.json"
grep -q 'CATALOG_STALE' "$tmp_root/stale.err" || fail "stale catalog did not fail closed"

for invalid_catalog in duplicate-catalog.json bad-probability-catalog.json; do
  expect_exit 2 "$tmp_root/invalid.out" "$tmp_root/invalid.err" selector validate --kind catalog "$tmp_root/$invalid_catalog"
done
for invalid_policy in bad-tie-policy.json bad-authority-policy.json bad-risk-policy.json bad-recovery-policy.json; do
  expect_exit 2 "$tmp_root/invalid.out" "$tmp_root/invalid.err" selector validate --kind policy "$tmp_root/$invalid_policy"
done
expect_exit 2 "$tmp_root/invalid.out" "$tmp_root/invalid.err" selector validate --kind task "$tmp_root/extra-task.json"

# The default catalog and policy resolve only from OPERATOR_DIR/model-selection.
selector recommend --task "$tmp_root/task.json" >"$tmp_root/defaults.json"
/usr/bin/python3 - "$tmp_root/defaults.json" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["recommendation"]["candidateId"] == "steady-balanced"
PY

expect_exit 2 "$tmp_root/invalid-baseline.out" "$tmp_root/invalid-baseline.err" selector replay \
  --tasks "$FIXTURES/tasks.jsonl" --outcomes "$FIXTURES/outcomes.jsonl" \
  --catalog "$FIXTURES/catalog.json" --policy "$FIXTURES/policy.json" \
  --baseline-candidate not-in-catalog
grep -q 'INVALID_REFERENCE' "$tmp_root/invalid-baseline.err" || fail "unknown fixed baseline did not fail closed"

selector replay --tasks "$FIXTURES/tasks.jsonl" --outcomes "$FIXTURES/outcomes.jsonl" \
  --catalog "$FIXTURES/catalog.json" --policy "$FIXTURES/policy.json" \
  --baseline-candidate baseline-cheap >"$tmp_root/replay.json"

/usr/bin/python3 - "$tmp_root/replay.json" "$FIXTURES/tasks.jsonl" "$FIXTURES/catalog.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
tasks = [json.loads(line) for line in open(sys.argv[2], encoding="utf-8") if line.strip()]
catalog = json.load(open(sys.argv[3], encoding="utf-8"))
replay_1_task = next(task for task in tasks if task["taskId"] == "replay-1")
baseline = next(candidate for candidate in catalog["candidates"] if candidate["candidateId"] == "baseline-cheap")
baseline_estimate = next(estimate for estimate in baseline["estimates"] if estimate["taskClass"] == "bounded-code")
assert replay_1_task["qualityFloorBps"] > baseline_estimate["qualityBps"]
assert report["schemaVersion"] == "operator.model-selection-replay/v1"
replay_1 = next(case for case in report["cases"] if case["taskId"] == "replay-1")
assert replay_1["adaptive"]["candidateId"] == "steady-balanced"
assert replay_1["baseline"] == {
    "status": "fixed",
    "candidateId": "baseline-cheap",
    "outcomeId": "outcome-r1-baseline",
}
assert report["adaptive"]["acceptedOutcomeRate"] == {"accepted": 4, "known": 4, "rateBps": 10000}
assert report["adaptive"]["tokenTelemetry"] == {"reported": 3, "unknown": 1, "totalTokens": 4500}
assert report["adaptive"]["acceptedOutcomesPerToken"]["perMillionTokens"] == 666
assert report["adaptive"]["medianTotalTokensPerAcceptedTask"] == 1500
assert report["baseline"]["acceptedOutcomeRate"] == {"accepted": 2, "known": 4, "rateBps": 5000}
assert report["baseline"]["tokenTelemetry"] == {"reported": 4, "unknown": 0, "totalTokens": 15000}
assert report["baseline"]["acceptedOutcomesPerToken"]["perMillionTokens"] == 133
assert report["baseline"]["medianTotalTokensPerAcceptedTask"] == 2750
assert report["comparison"] == {
    "acceptedOutcomeRateDeltaBps": 5000,
    "acceptedOutcomesPerMillionTokensDelta": 533,
    "medianTotalTokensPerAcceptedTaskDelta": -1250,
}
PY

grep -v '"outcomeId":"outcome-r1-baseline"' "$FIXTURES/outcomes.jsonl" >"$tmp_root/outcomes-missing-baseline.jsonl"
selector replay --tasks "$FIXTURES/tasks.jsonl" --outcomes "$tmp_root/outcomes-missing-baseline.jsonl" \
  --catalog "$FIXTURES/catalog.json" --policy "$FIXTURES/policy.json" \
  --baseline-candidate baseline-cheap >"$tmp_root/replay-missing-baseline.json"
/usr/bin/python3 - "$tmp_root/replay-missing-baseline.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
replay_1 = next(case for case in report["cases"] if case["taskId"] == "replay-1")
assert replay_1["baseline"] == {
    "status": "fixed",
    "candidateId": "baseline-cheap",
    "outcomeId": None,
}
assert report["baseline"]["selected"] == 4
assert report["baseline"]["abstained"] == 0
assert report["baseline"]["missingOutcomes"] == 1
PY

printf 'operator model selector smoke: PASS\n'
