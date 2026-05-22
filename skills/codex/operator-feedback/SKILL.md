---
name: operator-feedback
description: "Use as Operator Kit feedback mode: capture testing notes, browser/mobile annotations, screenshots, videos, and UX observations into OPERATOR_DIR as structured FB-* intake without creating implementation tasks or dispatching agents."
---

# Operator Feedback

Use this skill when the user is testing the product, annotating UI, collecting
mobile simulator feedback, or giving raw observations that should become local
Operator feedback.

This is feedback mode:

```text
$operator-feedback = capture evidence, classify feedback, write FB-* intake
$operator-planner  = prioritize, group, promote to roadmap/backlog
$operator          = create tasks, dispatch lanes, collect, integrate
```

Feedback is not execution. Do not create implementation task packets, dispatch
lanes, collect lane work, merge code, or send text directly into tmux panes.

## Start Routine

1. Detect the Operator Kit project the same way `$operator` does:
   - walk upward for `operator.config.env`;
   - if needed, check sibling worktrees for the canonical project.
2. Read `operator.config.env` and `AGENTS.md`.
3. Prefer project-local scripts:
   - `bash scripts/operator-feedback.sh init`
   - `bash scripts/operator-feedback.sh detect`
   - `bash scripts/operator-roadmap.sh status` when available
4. Write all captures and annotations under `OPERATOR_DIR`, never the app repo.

If Operator Kit is not installed, explain that feedback mode needs an installed
project or a target project path.

## What This Skill Owns

Capture and classify:

- browser annotations;
- mobile screenshots and screen recordings;
- simulator or TestFlight observations;
- verbal testing notes;
- design/UX observations from `$design-agent`;
- evidence links and reproduction context.

Create or update feedback intake items with this contract:

- `ID`
- `source`
- `status`
- `screen`
- `target`
- `evidence`
- `coordinates`
- `testID`
- `type`
- `severity`
- `priority`
- `comment`
- `expected`
- `owner lane`
- `related roadmap`
- `related task`

Classify feedback as one of:

- bug
- UI polish
- UX/product decision
- backend/API issue
- data issue
- release/TestFlight issue
- roadmap idea

## Commands

Use project-local commands:

```bash
bash scripts/operator-feedback.sh init
bash scripts/operator-feedback.sh detect
bash scripts/operator-feedback.sh start mobile-feedback-20260522 "Mobile feedback intake"
bash scripts/operator-feedback.sh capture-sim mobile-feedback-20260522 --note "Coach reply overflow"
bash scripts/operator-feedback.sh record-sim-start mobile-feedback-20260522
bash scripts/operator-feedback.sh record-sim-stop mobile-feedback-20260522
bash scripts/operator-feedback.sh review mobile-feedback-20260522
bash scripts/operator-feedback.sh triage mobile-feedback-20260522
```

Use `triage` to convert annotation UI output into `FB-*` files under:

```text
OPERATOR_DIR/roadmap/inbox/
```

Do not use `operator-roadmap.sh add` from feedback mode unless the user
explicitly asks to promote feedback; prefer handing that to `$operator-planner`.

## Browser And Mobile Evidence

Browser feedback:

```text
DOM element + screenshot + comment
```

Mobile feedback:

```text
screenshot/video + screen + coordinates or testID + comment
```

For mobile v1, use the simulator capture/review loop:

```bash
bash scripts/operator-feedback.sh start <slug> "<title>"
bash scripts/operator-feedback.sh capture-sim <slug> --note "<short observation>"
bash scripts/operator-feedback.sh review <slug>
bash scripts/operator-feedback.sh triage <slug>
```

## Design-Agent Collaboration

When the feedback is visual, UX, design-system, or annotation-heavy, compose
with `$design-agent`:

```text
Use $operator-feedback with $design-agent. Capture these annotations.
Use $operator-feedback with $design-agent. Classify this UI feedback from the browser review.
Use $operator-feedback with $design-agent. Review these mobile screenshots and create FB-* intake.
```

Let `$design-agent` own UX/design classification. Keep this skill responsible
for feedback evidence, local files, IDs, and intake summaries.

## Output Style

Lead with:

- captured feedback count;
- highest-severity items;
- duplicates or themes;
- owner-lane hints;
- evidence paths;
- recommended `$operator-planner` follow-up.

Never imply that feedback has been scheduled or dispatched unless `$operator`
actually created and dispatched an execution task.
