---
name: operator-feedback
description: Capture Agent Operator Kit feedback from Cursor. Use when collecting testing notes, browser or mobile annotations, screenshots, videos, UX observations, and raw product feedback as FB-* intake without dispatching implementation agents.
---

# Operator Feedback

Use this skill as Cursor's feedback mode for an installed Agent Operator Kit
project.

Feedback is not execution. Do not create implementation task packets, dispatch
lanes, collect lane work, merge code, or send text directly into tmux panes.
The `operator-planner` skill promotes feedback into roadmap work; the
`operator` skill executes approved work.

## Start Routine

1. Resolve the Operator Kit project:
   - walk upward until `operator.config.env` is found;
   - if needed, check the scoped project-root layout `code/*/operator.config.env`;
   - if needed, check sibling worktrees for the canonical project.
2. Read `operator.config.env` and `AGENTS.md`.
3. Prefer project-local scripts:

```bash
bash scripts/operator-feedback.sh init
bash scripts/operator-feedback.sh detect
bash scripts/operator-roadmap.sh status
```

4. Write all captures, annotations, and local feedback state under
   `OPERATOR_DIR`, never the app repo.

If Operator Kit is not installed, explain that feedback mode needs an installed
project or a target project path.

## Feedback Work

Capture and classify:

- browser annotations;
- mobile screenshots and screen recordings;
- simulator or TestFlight observations;
- verbal testing notes;
- design and UX observations from `design-agent`, UX Auditor (`ux-auditor`), or
  `user-journey`;
- evidence links and reproduction context.

Feedback intake items should include source, status, screen, target, evidence,
coordinates or testID, type, severity, priority, comment, expected behavior,
owner lane, related roadmap item, and related task.

Classify feedback as bug, UI polish, UX/product decision, backend/API issue,
data issue, release/TestFlight issue, or roadmap idea.

## Commands

Use project-local commands:

```bash
bash scripts/operator-feedback.sh init
bash scripts/operator-feedback.sh detect
bash scripts/operator-feedback.sh start <slug> "<title>"
bash scripts/operator-feedback.sh capture-sim <slug> --note "<short observation>"
bash scripts/operator-feedback.sh record-sim-start <slug>
bash scripts/operator-feedback.sh record-sim-stop <slug>
bash scripts/operator-feedback.sh review <slug>
bash scripts/operator-feedback.sh triage <slug>
```

Use `triage` to convert review annotations into `FB-*` files under:

```text
OPERATOR_DIR/roadmap/inbox/
```

Do not promote feedback to roadmap unless the user explicitly asks; otherwise
handoff to `operator-planner`.
