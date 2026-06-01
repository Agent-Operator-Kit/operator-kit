# Operator Roadmap

Local roadmap, backlog, prioritization, and feedback planning live here.

V2 roadmap items can also describe dependency and dispatch metadata so the
operator can propose an approved parallel batch before creating task packets:

- `Depends on`: comma-separated `RM-*` IDs that must be shipped first.
- `Required roles`: catalog role templates needed for the work.
- `Owner lane`: concrete lane to receive the task packet.
- `Contracts`: API, file, provider, data, or architecture contracts touched.
- `Parallel safe`: `yes` or `no`.
- `Approval gate`: `none`, `release`, `provider-console`, `secrets`, `migration`, `live-money`, or another explicit human gate.

This workspace is outside the app repo by design. Keep raw feedback, triage
notes, local priority views, and dispatch planning here. Link code changes back
with lightweight roadmap, feedback, and operator task IDs in PRs or commits.

## Layout

- `items/`: roadmap and backlog items (`RM-*`).
- `inbox/`: raw or triaged feedback items (`FB-*`).
- `views/`: generated or curated planning views.

## Trace Format

```markdown
Roadmap: RM-0007
Feedback: FB-0014, FB-0015
Operator task: mobile-feedback-20260522
Why: short rationale
Validation: commands, screenshots, simulator checks, or manual checks
```
