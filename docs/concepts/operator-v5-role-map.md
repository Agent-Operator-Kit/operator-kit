# Operator V5 Project Role Map

Status: RM-0002 contract for the V5 architecture baseline.

The project role map is the machine-readable boundary between durable project
lanes, reusable role templates, temporary feature instances, and the host
runners that execute them. These are separate types. A role name is not a lane,
a host session is not an owner, and a feature instance does not become durable
project topology.

The project-local source of truth is:

```text
$OPERATOR_DIR/catalog/role-map.json
```

## Commands

```bash
bash scripts/operator-role-map.sh init [--json]
bash scripts/operator-role-map.sh show [--json]
bash scripts/operator-role-map.sh validate [--json]
```

`init` derives every durable lane's `id`, `tool`, `worktree`, and `branch` from
`OPERATOR_LANES`. It also derives host-runner records from the configured tool
values and refreshes role-template records from `$OPERATOR_DIR/catalog/roles`.
It never rewrites `operator.config.env` or catalog role Markdown.

The committed starter is the expected output of `init` for the canonical V5
example, not an independent topology source. In that example, the operator
uses branch `codex/operator-v5-integration` and worktree
`operator-kit-v5-integration`; design flow uses branch
`codex/v5-rm-0006-design-flow`.

When a role map already exists, `init` preserves project-curated
`roleTemplateIds`, authority records, extra metadata, and `featureInstances`.
Derived configuration fields still win. Lanes removed from `OPERATOR_LANES`
are removed from `durableLanes`, and newly configured lanes receive the
project-specific defaults below when their IDs are recognized.

`show --json` emits the deterministic stored document. `validate --json` emits
a small result object and exits nonzero when the contract is invalid.

## Types

The root object has `kind: operator-role-map`, `schemaVersion: 1`, and four
typed arrays.

### Durable lane

A durable lane is long-lived project topology and unique ownership:

```json
{
  "kind": "durable-lane",
  "id": "scheduler",
  "tool": "Codex CLI",
  "hostRunnerId": "codex-cli",
  "worktree": "operator-kit-v5-rm-0004-scheduler",
  "branch": "codex/v5-rm-0004-scheduler",
  "roleTemplateIds": ["api-contracts", "evals-testing"],
  "authority": {"manageQueue": false, "integrate": false}
}
```

Lane IDs, branches, and worktrees must be unique. Durable lane IDs are
normalized lowercase kebab-case. Branches must pass Git's branch-ref validation
and cannot be option-like, absolute-like, backslash-separated, padded, or
control-character-bearing. Worktree values are normalized lowercase kebab-case
names for direct relative children of `CODE_DIR`; absolute paths, traversal,
slashes, backslashes, symlink escapes, and option-like names are rejected.

Branch and worktree ownership is also unique across temporary feature
instances. The `operator` durable lane must be the sole lane with either
queue-management or integration authority.

### Role template

A role template is reusable specialist guidance, not exclusive ownership:

```json
{
  "kind": "role-template",
  "id": "api-contracts",
  "catalogRef": "roles/api-contracts.md"
}
```

Every role template must resolve to a catalog Markdown file whose `- ID:` value
matches its filename. A template can be assigned to many durable lanes and can
be instantiated many times when ownership surfaces do not conflict.

This object plus the durable lane's `roleTemplateIds` reference is the V5
`lane-template` contract: it describes reusable lane capability without
claiming a branch, worktree, graph scope, or host session. Only a
`feature-instance` turns that reusable template into temporary ownership.

### Feature instance

A feature instance is temporary, feature-scoped execution ownership created
from one role template:

```json
{
  "kind": "feature-instance",
  "id": "api-contracts@FS-0003",
  "featureId": "FS-0003",
  "durableLaneId": "role-map",
  "roleTemplateId": "api-contracts",
  "hostRunnerId": "codex-cli",
  "worktree": "operator-kit-v5-fs-0003-api-contracts",
  "branch": "codex/v5-fs-0003-api-contracts"
}
```

Feature instances reference, but never replace, durable lanes, role templates,
or host runners. An empty `featureInstances` array is valid. When instances are
recorded, their IDs, branches, and worktrees must be unique and every reference
must resolve. Instance and feature IDs use normalized alphanumeric segments
separated by single `.`, `-`, or `@` characters. Instance branches and
worktrees follow the same safe branch/worktree rules as durable lanes.

The selected role must also appear in the selected durable lane's
`roleTemplateIds`. A catalog role cannot be attached to a feature instance
through a lane that was not assigned that role.

### Host runner

A host runner identifies an execution surface derived from the tool field in
`OPERATOR_LANES`:

```json
{
  "kind": "host-runner",
  "id": "codex-cli",
  "tool": "Codex CLI"
}
```

Host runners execute assigned graph scope. They do not acquire queue,
integration, branch, or worktree authority merely because a host can continue
running autonomously.

## Project-Specific V5 Defaults

The starter template assigns roles as follows:

| Durable lane | Role templates |
| --- | --- |
| `operator` | none; sole queue and integration authority |
| `lanes` | `high-risk-operations`, `evals-testing` |
| `role-map` | `api-contracts`, `evals-testing` |
| `control-graph` | `api-contracts`, `data-storage`, `observability`, `evals-testing` |
| `scheduler` | `api-contracts`, `evals-testing` |
| `loop-runner` | `llm-runtime`, `observability`, `evals-testing` |
| `host-adapters` | `llm-runtime`, `evals-testing` |
| `design-flow` | `design-system`, `evals-testing` |

These assignments seed a new role map only. Editing a lane's
`roleTemplateIds` is a supported project customization, provided every ID
resolves to the local catalog and the rest of the contract validates.

## Failure Rules

Validation fails closed for malformed JSON or types, unsafe or non-normalized
IDs and topology values, invalid Git refs, paths outside `CODE_DIR`, stale
derived lane fields, duplicate IDs, duplicate branch/worktree ownership,
missing, unknown, or lane-unassigned roles, broken references, non-boolean
authority, a missing operator authority, or any second queue manager or
integrator.

`init` builds and validates the complete candidate in memory before atomically
replacing `role-map.json`, so invalid configuration or preserved customization
does not partially rewrite the prior map. With `--json`, malformed preserved
arrays, elements, and role values produce a structured
`{"valid": false, "error": "..."}` result with a nonzero exit and no Python
traceback; the existing file remains byte-for-byte unchanged.

## Integration Follow-Up

RM-0002 intentionally does not update shared installers or update registries.
Integration must add `scripts/operator-role-map.sh` and
`templates/operator-workspace/catalog/role-map.json` to the shared bootstrap,
update, sync, and packaging surfaces after the V5 feature branches land.
