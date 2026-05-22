---
name: product-manager
description: "Compatibility alias for older Operator Kit prompts. Prefer $operator-feedback for feedback intake and $operator-planner for roadmap/backlog planning; never dispatch or integrate code from this skill."
---

# Product Manager Compatibility Alias

This skill is kept for existing prompts that still say `$product-manager`.
Prefer the explicit mode skills:

```text
$operator-feedback = capture evidence, classify feedback, write FB-* intake
$operator-planner  = prioritize, group, promote to roadmap/backlog
$operator          = create tasks, dispatch lanes, collect, integrate
```

When invoked as `$product-manager`:

- behave like `$operator-planner` for backlog, roadmap, prioritization,
  rationale, and ready-for-execution planning;
- direct raw testing notes, screenshots, annotation capture, and mobile review
  setup to `$operator-feedback`;
- do not dispatch lanes, collect lane work, merge code, or send text directly
  into tmux panes.

Use the project-local scripts:

```bash
bash scripts/operator-roadmap.sh status
bash scripts/operator-roadmap.sh list
bash scripts/operator-roadmap.sh ready
bash scripts/operator-roadmap.sh pr-note RM-0001 --feedback FB-0001 --task task-slug
bash scripts/operator-feedback.sh triage mobile-feedback-20260522
```

For new workflow docs and prompts, use `$operator-feedback` and
`$operator-planner` instead of `$product-manager`.
