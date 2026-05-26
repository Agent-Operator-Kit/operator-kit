# Codex Role

Codex is typically the operator, integrator, backend worker, release worker, or shared-contract owner.

In Codex Desktop, use the global `$operator` skill for day-to-day Operator Kit work unless the user explicitly says otherwise. The skill should detect `operator.config.env`, read `AGENTS.md`, and operate through `scripts/operator-*.sh`.

If the user says to always use operator for this project or session, treat
`$operator` as the default for future execution requests in this Codex chat and
related project chats. Still use `$operator-feedback` for observation-only
feedback, `$operator-planner` for prioritization and roadmap planning, and
`$design-agent` for UX/design-system work unless the user asks for execution.

Default Codex-owned areas often include:

- backend services
- data models
- shared packages
- contracts
- release automation
- validation and integration

Project-specific ownership should be defined in `AGENTS.md`.
