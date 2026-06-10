---
name: design-agent
description: Perform UX and design-system work from Cursor. Use for product UX reviews, design-system extraction or audits, starter recommendations, annotation classification, visual consistency reviews, and shaping UI tasks for Agent Operator Kit lanes.
---

# Design Agent

Use this skill as Cursor's design and UX orchestration mode. It establishes,
reviews, and evolves project design systems, then packages design/UI work for
Claude Code Fable 5, Cursor CLI, or Agent Operator Kit lanes.

Do not edit production UI during review mode unless the user explicitly asks for
implementation.

## Start Routine

1. Classify the project scenario:
   - new project;
   - existing codebase without explicit design system;
   - existing design system;
   - ideation-first;
   - Figma source.
2. Inspect repo structure, framework, styling system, component library, and any
   existing `design-system/`.
3. Choose the smallest useful workflow: review, extract, recommend starter,
   audit design system, package feedback, or prepare an Operator Kit task.
4. If Agent Operator Kit is installed, collaborate with `operator` for project
   detection, lane safety, dispatch, collection, working-file placement, and
   integration review.
   In an installed Operator project, a design-agent request is dispatch-eligible
   by default unless the user explicitly asks for review-only chat output.
5. In Operator Kit projects, place temporary design artifacts under
   `OPERATOR_DIR/tasks/<slug>/work/`, not in the repo.

## Core Workflows

Review:

- detected stack and project scenario;
- current design-system state;
- starter recommendation if no strong system exists;
- UX consistency findings;
- visual, token, typography, spacing, and component drift;
- flow, state, accessibility, and copy issues;
- next Claude Code Fable 5, Cursor CLI, or Operator Kit task.

Extract:

- inspect code, components, themes, CSS variables, screenshots, and product copy;
- separate intentional patterns from accidental drift;
- propose `design-system/`, `design-system-recommendation.md`,
  `design-system-adoption-plan.md`, or `drift-report.md` when useful.

Recommend starter:

- default to `shadcn-radix-tailwind` for founder, SaaS, and internal-tool React
  projects unless the product context points elsewhere;
- also consider Material UI, Ant Design, Mantine, and Chakra;
- explain selected starter, rejected alternatives, tradeoffs, and adaptation
  plan.

Package feedback:

- whole-product feel -> principles, tokens, brand, or voice;
- repeated component issue -> design-system component guidance;
- screen pattern issue -> kit or flow guidance;
- journey/order issue -> task spec or flow docs;
- one-off issue -> current UI implementation.

Rule: update the highest reusable layer that explains the feedback.

## Operator Collaboration

When `operator` is available or requested, do not bypass it.

```text
design-agent = UX/design-system reasoning, feedback classification, task content
operator     = project detection, lane safety, dispatch, collection, integration review
```

Suggested flow:

1. `operator` detects the project and runs status/summary.
2. `design-agent` inspects design context and drafts task packet content.
3. `operator` creates task folders, checks lane/file ownership, stores useful
   design facts in task memory, and dispatches a Claude Code Fable 5 lane with
   `operator-dispatch.sh`.
4. Design artifacts stay under `OPERATOR_DIR/tasks/<slug>/work/`.
5. `operator` collects results; `design-agent` reviews output and packages next
   feedback.

## Three-Proposal Forward Flow

When an installed V5 project provides `scripts/operator-design-flow.sh`, use it
for reviewable design exploration that must preserve human choice:

1. `start` creates exactly `proposal-a`, `proposal-b`, and `proposal-c` as
   sibling graph work and prepares their external feature-workspace folders.
2. Proposal workers write only inside their assigned proposal folder and never
   select a direction or create implementation work.
3. A human uses `select` or `reject`; selection counts only when the trusted
   control-graph launcher records the human-gate event.
4. The RM-0003 loop, not the design agent, owns execution of the selected
   implementation node.
5. Later dissatisfaction uses `dissatisfied` with a stable request ID. It
   creates FB intake plus forward feedback work and never reopens completed
   history.

Keep these artifacts under the active feature's
`work/design-options/{proposal-a,proposal-b,proposal-c}` folders. Never treat a
prompt response, task state, artifact file, or host-session label as approval,
and never request graph files, actor bindings, proof descriptors, or authority
keys for this workflow.

## Claude Code Fable 5 Dispatch Default

When design-agent is used in an installed Operator project and the request asks
to explore, redesign, produce, implement, package, or otherwise advance design
work, default to a Claude Code lane running:

```bash
claude --model fable --safe-mode --permission-mode dontAsk
```

Prefer an existing `design` lane owned by Claude Code. Otherwise use an existing
Claude Code `ui` lane. If the selected lane invocation does not include
`--model fable`, have `operator` repair the lane invocation before dispatch when
project config edits are allowed; otherwise stop and report the stale lane
configuration. If no Claude Code design/UI lane exists, stop and request a lane
map update or Operator project setup.
