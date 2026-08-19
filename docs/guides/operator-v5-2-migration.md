# Updating to Operator V5.2

V5.2 keeps the V5.1 local dependency graph and adds optional, advisory model
selection. The selector is installed but off: it does not choose a model for a
lane or chat, dispatch work, create provider credentials, or learn online.

## From V5.1

Run the normal latest update:

```bash
bash scripts/operator-sync.sh --channel latest --target /path/to/project
```

The compatible update advances `OPERATOR_KIT_VERSION` from `5.1` to `5.2` and
adds missing inert starter files. Existing project-owned model-selection files
are preserved byte-for-byte.

## From V4 or signed V5

First complete the reviewed local-graph migration:

```bash
bash scripts/operator-v5-1-migrate.sh plan
bash scripts/operator-v5-1-migrate.sh apply \
  --authorize MIGRATE_TO_V5_1_LOCAL_GRAPH
```

Then run the latest update once more. The first step handles the graph change;
the compatible update then advances the marker to V5.2.

## Optional model inputs

Run:

```bash
bash scripts/operator-model-select.sh setup-guide
```

Before opting in, the user must review and provide:

1. Every permitted provider/model ID paired with one exact reasoning setting.
2. Verified availability, hosts, lanes, tools, modalities, context windows,
   data classes, credential capability names, and maximum risk class.
3. Per-task-class quality, confidence, first-attempt tokens, retry and
   escalation risk, latency, and cost estimates. Unknown evidence stays `null`.
4. Allowed profiles, quality/risk floors, data rules, budgets, and override
   policy.
5. User preferences, continuity needs, candidate pins, and override reasons.

Keep secrets outside Operator. The catalog may name a credential capability but
must never contain an API key or token.

For existing V5.2 projects, Operator can first inspect the current lane map and
any structured previous-run receipts:

```bash
bash scripts/operator-model-select.sh suggest-from-history
```

The command writes nothing and keeps the draft policy mode `off`. If the
default `tasks.jsonl`, `outcomes.jsonl`, or live catalog is absent, it returns a
`needs_input` onboarding receipt. With sufficient evidence, it produces a
candidate shortlist and preserves observed task quality floors as reviewable
hints. The user must still confirm provider/model identities, reasoning,
availability, risk/data rules, budgets, and preferences. Operator does not mine
raw chats or handoffs for telemetry.

## Opt in

Copy the inert examples to `catalog.json` and `policy.json`, replace every
placeholder, validate both files, and keep policy mode `off` until review is
complete. Changing mode to `recommend` enables advisory receipts only. The user
or Operator still chooses whether to follow them.

## Rollback

Set policy mode to `off` or stop invoking `operator-model-select.sh`. No graph,
lane, chat, or provider state needs repair because V5.2 never applies the
recommendation automatically.
