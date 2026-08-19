# Advisory model selection

Operator Kit includes an optional, standalone model selector for evaluating one
task against a project-local catalog and policy. V5.2 installation only makes the
command, contracts, and inert examples available. It does not enable model
selection or connect it to task creation, the local graph, dispatch, lanes,
chats, provider settings, or model execution.

The selector has advisory authority only. A human or Operator must decide
whether to use a recommendation. The v1 `policy-auto` mode is also dry-run only
and cannot apply settings.

## Installed files

Bootstrap and latest-channel update install or refresh:

```text
scripts/operator-model-select.sh
scripts/operator_model_selector.py
schemas/operator-model-selection/v1/*.schema.json
```

Bootstrap also installs these files only when they are missing:

```text
OPERATOR_DIR/model-selection/README.md
OPERATOR_DIR/model-selection/catalog.example.json
OPERATOR_DIR/model-selection/policy.example.json
```

The examples are intentionally inert: the policy mode is `off`, and the
example candidate is disabled and unavailable. Installation never creates
`catalog.json` or `policy.json`, changes `operator.config.env`, generates a
decision, or invokes the selector.

## Onboarding guide

Fresh installs and V5.1-to-V5.2 updates point users to one read-only command:

```bash
bash scripts/operator-model-select.sh setup-guide
```

It lists the project-local files and the inputs a user must provide before
opting in: exact provider/model plus reasoning combinations, verified
availability and compatibility, task-class outcome estimates, policy floors and
limits, and user preferences or pins. The command writes nothing and never asks
for API keys. Credentials stay in the provider's normal secure configuration;
the catalog may contain only a non-secret capability name.

## Safe setup

Read `OPERATOR_DIR/model-selection/README.md` before creating live files. Copy
the examples to `catalog.json` and `policy.json` only after replacing every
placeholder with reviewed project data. Keep task and policy semantics
provider-neutral; exact provider/model IDs belong in catalog candidates.

Before changing policy mode from `off`:

1. Verify local availability and any named credential capability without
   putting credentials in the catalog.
2. Set an intentional catalog observation and validity window.
3. Calibrate non-null quality, confidence, token, retry, escalation, latency,
   and cost estimates for each supported task class.
4. Review capability, tool, modality, context, data, lane, host, risk, quality,
   and budget constraints together.
5. Validate both files explicitly.

Load the project paths into the current shell before expanding
`$OPERATOR_DIR` in file arguments:

```bash
source operator.config.env
bash scripts/operator-model-select.sh validate --kind catalog \
  "$OPERATOR_DIR/model-selection/catalog.json"
bash scripts/operator-model-select.sh validate --kind policy \
  "$OPERATOR_DIR/model-selection/policy.json"
```

Unknown telemetry must remain explicit `null` or `{"status":"unknown",...}`
according to the contract. Never substitute numeric zero for missing evidence.

## Commands and exits

```bash
bash scripts/operator-model-select.sh validate \
  --kind task|catalog|policy|decision|outcome FILE

bash scripts/operator-model-select.sh recommend \
  --task FILE [--catalog FILE] [--policy FILE]

bash scripts/operator-model-select.sh replay \
  --tasks FILE --outcomes FILE \
  [--catalog FILE] [--policy FILE] [--baseline-candidate ID]
```

When `--catalog` or `--policy` is omitted, the command reads
`OPERATOR_DIR/model-selection/catalog.json` and `policy.json`. JSON results go
to stdout and diagnostics go to stderr.

- Exit `0`: valid recommendation, validation, or replay.
- Exit `3`: valid `off` or `needs_override` result with no recommendation.
- Exit `2`: invalid usage, input, references, policy, telemetry, or I/O.

No command dispatches work or changes the model used by a lane or chat.

## Selection rule

Hard constraints and missing-evidence checks run before optimization. A user
pin is still subject to those constraints. Expected total tokens use integer
basis-point arithmetic and include one retry plus one escalation:

```text
firstAttemptTokens
+ ceil(retryProbabilityBps * retryTokens / 10000)
+ ceil(escalationProbabilityBps * escalationTokens / 10000)
```

Eligible candidates are Pareto-filtered over quality (higher is better),
expected total tokens, latency, and cost (lower is better). The remaining
frontier is ordered by expected total tokens, continuity, latency, cost, then
lexical candidate ID. Receipts include input digests, rejection evidence, the
frontier and fallbacks, tie-break evidence, and a deterministic fingerprint.

## Fixed-baseline replay

Replay evaluates adaptive recommendations against one configured fixed
candidate. The fixed candidate is an evaluation arm, not another adaptive
recommendation: after its catalog ID is validated, it is selected directly for
every replay task and is not subjected to adaptive quality, confidence,
profile, risk, or budget floors.

Observed outcomes are matched by `(taskId, candidateId)`. Retry and escalation
attempts are charged through the outcome's total reported tokens. A missing
fixed-candidate outcome remains a `fixed` case with `missingOutcomes`
incremented. Unknown telemetry is reported separately and is never treated as
zero. Compare accepted-outcome rate, accepted outcomes per reported token, and
median total tokens per accepted task together; a cheaper first attempt is not
an improvement if recovery makes the complete outcome worse.

## Preservation and rollback

Updates refresh the selector runtime and schemas from the selected channel.
Every existing file under `OPERATOR_DIR/model-selection/` is project-owned and
preserved byte-for-byte; only a missing README or example may be installed.
Live catalogs, policies, decisions, outcomes, and additional project files are
never refreshed from the kit.

The safest rollback is to stop invoking the standalone command or keep policy
mode `off`. If removal is required, remove only the installed selector wrapper,
Python runtime, and `schemas/operator-model-selection/` tree through a reviewed
project change. Preserve `OPERATOR_DIR/model-selection/` for recovery or audit.
No graph or dispatch state needs repair because S1 creates none.

## Future work

The following are explicitly outside S1 and must not be inferred from package
availability:

- real provider adapters and availability collection;
- representative-corpus calibration of quality, risk, retry, escalation,
  latency, and cost estimates;
- automatic application of recommendations to graph, task, dispatch, lane,
  chat, or provider behavior (S2);
- online policy learning or a fine-tuned routing model.
