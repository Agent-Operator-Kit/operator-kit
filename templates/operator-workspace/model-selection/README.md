# Model Selection Workspace

This optional project-local directory stores user-owned model-selection data.
It is outside the repository so provider availability, local capability names,
policy choices, and outcome evidence can change without rewriting Operator Kit
source.

## Safety boundary

Advisory model selection does not dispatch work, mutate the local dependency
graph, change lane ownership, alter task packets, or apply a model/reasoning
setting. The human or Operator remains responsible for any execution choice.
`policy-auto` is dry-run only in v1.

Never put credentials, API keys, private prompts, transcripts, authority keys,
leases, fences, or provider-console exports in this directory. A catalog may
name a local credential capability, but it must not contain secret material.

## Starter files

- `catalog.example.json` is deliberately stale, unavailable, and disabled.
- `policy.example.json` uses `mode: "off"` and grants no execution authority.

Copy the examples to `catalog.json` and `policy.json` only after replacing the
placeholder values with reviewed project data. Enabling a candidate requires
all of the following:

1. Set an intentional catalog validity window.
2. Set `enabled: true` and `availability: "available"` only for a verified
   local capability.
3. Supply non-null quality, confidence, retry, escalation, latency, and cost
   estimates for every supported task class.
4. Verify capability, tool, modality, context, data-class, lane, host, and risk
   declarations.
5. Set policy mode to `recommend` only after the catalog and policy are
   reviewed together.

From the installed project, run this read-only checklist at any time:

```bash
bash scripts/operator-model-select.sh setup-guide
```

If structured task and outcome receipts already exist, ask for a reviewable
starting point with:

```bash
bash scripts/operator-model-select.sh suggest-from-history
```

The command reads `tasks.jsonl`, `outcomes.jsonl`, and an optional live
`catalog.json` from this directory by default. It writes nothing. Missing
defaults are reported as onboarding inputs, while explicitly passed missing or
invalid files fail closed. Candidate IDs can only be resolved to exact provider,
model, profile, and reasoning settings through the catalog.

The suggestion uses a minimum of three known-acceptance outcomes per candidate
and task class before producing an evidence-ranked shortlist. It preserves
unknown telemetry, redacts lane commands to digests plus explicit model and
reasoning flags, leaves every policy hint in `off` mode, and lists the remaining
human decisions. Raw chats, Markdown handoffs, and arbitrary project files are
not mined by the deterministic command; convert only verified observations into
the structured contracts.

An exact catalog candidate represents one provider model plus one exact
reasoning setting. Adding another reasoning setting means adding another stable
candidate ID. Task demand and policy remain provider-neutral: they use semantic
profiles, capabilities, risk classes, data classes, and opaque candidate IDs.

## Contracts

All v1 documents use:

```json
{"schemaVersion":"operator.model-selection/v1"}
```

The evergreen schemas live in
`schemas/operator-model-selection/v1/`. Objects are strict except for the
bounded scalar `reasoningSetting.parameters` extension point. A stdlib runtime
validator can enforce the same shapes without loading a JSON Schema library.

Catalog estimates use required nullable fields. `null` means unknown and makes
the candidate ineligible when policy requires that estimate. Numeric zero is a
real observed or estimated zero and must never stand in for missing data.

Outcome token, latency, and cost telemetry uses explicit tagged values:

```json
{"status":"reported","value":123}
{"status":"unknown","reason":"provider did not report this metric"}
```

Token usage uses the same `reported`/`unknown` distinction, with individual
token counts present only when reported.

## Selection contract

The v1 policy requires hard filtering for availability, capabilities, tools,
modalities, context, data classes, lane, host, risk, quality, user override,
and budgets. Missing required evidence fails closed.

Expected total tokens include retry and escalation risk:

```text
firstAttemptTokens
+ ceil(retryProbabilityBps * retryTokens / 10000)
+ ceil(escalationProbabilityBps * escalationTokens / 10000)
```

Eligible candidates are Pareto-filtered on quality, expected total tokens,
latency, and cost. The deterministic tie-break order is expected total tokens,
continuity, latency, cost, then lexical candidate ID.

Decision receipts include canonical input digests, a deterministic selection
fingerprint, constraint evidence, frontier/fallback order, rejection codes, and
an authority block proving the result is advisory. Outcome receipts are for
offline evaluation only and never update policy automatically. Suggestion
receipts use `operator.model-selection-suggestion/v1` and are also advisory,
read-only, and non-learning.
