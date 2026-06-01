# Operator V2

Operator V2 keeps the V1 worktree, tmux, task-packet, memory, roadmap, and
handoff model. It adds a richer planning layer so the operator can reason about
production systems as more than frontend and backend.

## Model

V2 separates four ideas:

- **Lane**: durable execution capacity with worktree, branch, tmux window, owner, and memory stream.
- **Role template**: specialist expertise that can run as a durable lane or an ephemeral overlay.
- **Architecture pattern**: approved package, repo, framework, contract style, and validation recipe.
- **Batch plan**: dependency-aware proposal for operator-approved parallel dispatch.

The goal is not hundreds of permanent lanes. The goal is a large catalog of
specialist templates and a smaller active lane pool selected for the project.

## Lane-Cutting Principles

Create or recommend a durable lane when the area has one or more of these
properties:

- long-lived ownership
- explicit API, provider, schema, prompt, deployment, or package contract
- high-risk domain such as auth, RLS, release, live money, or destructive data work
- distinct validation loop such as Maestro, Playwright, evals, provider fixtures, or release smoke
- high context density that benefits from stable memory

Use role overlays when the work needs specialist guidance but does not yet need a
dedicated worktree.

## Catalog

The project-local catalog lives under:

```text
OPERATOR_DIR/catalog/
  roles/
  patterns/
```

Treat it like an engineering design system:

- role templates define ownership, read-only areas, validation, and escalation
  gates
- patterns define approved packages, GitHub repos, solution approaches, and
  consistency rules
- new packages or architecture approaches should either follow the catalog or
  propose an addition before implementation

## System Map

`scripts/operator-system-map.sh refresh` writes `OPERATOR_DIR/system-map.md`.
It records current lanes, architecture docs, detected role candidates, and lane
recommendations.

The system map can use existing repo docs such as `ARCHITECTURE.md` or
`architecture.md` as input, but it stays local operator state by default.

## Batch Planning

Roadmap items can include:

- `Depends on`
- `Required roles`
- `Owner lane`
- `Contracts`
- `Parallel safe`
- `Approval gate`

`scripts/operator-plan-batch.sh` reads those fields and writes
`OPERATOR_DIR/roadmap/views/batch-plan.md`.

The output is an approval proposal, not an autopilot. It identifies:

- parallel dispatch candidates
- missing lane decisions
- approval gates
- dependency blockers
- serialized or conflict-prone work

V2 intentionally stops before fully autonomous dispatch.
