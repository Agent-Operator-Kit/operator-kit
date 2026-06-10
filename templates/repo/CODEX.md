# Codex Role

Codex is typically the operator, integrator, backend worker, release worker, or shared-contract owner.

In Codex Desktop, use the global `$operator` skill for day-to-day Operator Kit work unless the user explicitly says otherwise. The skill should detect `operator.config.env`, read `AGENTS.md`, and operate through `scripts/operator-*.sh`.

Operator Kit V2 adds `OPERATOR_DIR/system-map.md`, `OPERATOR_DIR/catalog/`, and
`scripts/operator-plan-batch.sh`. Use them before broad roadmap execution so
lane choices, role templates, approved architecture patterns, dependencies, and
approval gates are explicit.

Operator Kit V4 adds feature sessions under
`OPERATOR_DIR/features/<FS-id-slug>/`. Treat one Codex or Cursor project as the
operator cockpit, bind execution chats to the active feature session when
available, and spawn feature-specific lane instances from reusable role
templates. Role templates are not mutexes: conflicts are decided by touched
files, contracts, surfaces, branches, worktrees, and shared resources. The
operator owns the merge plan and final cohesion for the feature session, and
unblocked discovery or design work can continue while implementation is blocked.

If the user says to always use operator for this project or session, treat
`$operator` as the default for future execution requests in this Codex chat and
related project chats. Still use `$operator-feedback` for observation-only
feedback, `$operator-planner` for prioritization and roadmap planning, and
`$design-agent` for UX/design-system work, UX Auditor (`$ux-auditor`) for scored UX
assessment, `$user-journey` for journey artifacts, and `$incubation` for idea
incubation unless the user asks for execution.

Default Codex-owned areas often include:

- backend services
- data models
- shared packages
- contracts
- release automation
- validation and integration

Project-specific ownership should be defined in `AGENTS.md`.
