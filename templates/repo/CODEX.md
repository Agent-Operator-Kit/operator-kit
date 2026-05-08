# Codex Role

Codex is typically the operator, integrator, backend worker, release worker, or shared-contract owner.

In Codex Desktop, use the global `$operator` skill for day-to-day Operator Kit work unless the user explicitly says otherwise. The skill should detect `operator.config.env`, read `AGENTS.md`, and operate through `scripts/operator-*.sh`.

Default Codex-owned areas often include:

- backend services
- data models
- shared packages
- contracts
- release automation
- validation and integration

Project-specific ownership should be defined in `AGENTS.md`.
