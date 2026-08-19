---
name: design-agent
description: "Use for product UX and design-system work in Codex Desktop projects: comprehensive UX and consistency reviews, code-first design-system extraction, starter recommendation, design-system audits, annotation feedback classification, and preparing Claude Code or Agent Operator Kit design/UI tasks."
---

# Design Agent

Use this skill as Codex Desktop's design/UX orchestration layer. It establishes, reviews, and evolves project design systems, then packages design/UI work for Claude Code Fable 5 or Agent Operator Kit lanes.

Claude Code Fable 5 is the preferred executor for design exploration, design-system extraction, and production design/UI edits. Codex is the review, annotation, task-shaping, and design-system memory surface.

## Start Routine

1. Classify the project scenario:
   - new project,
   - existing codebase without explicit design system,
   - existing design system,
   - ideation-first,
   - Figma source.
2. Inspect the repo structure and detect framework, styling system, component library, and existing `design-system/`.
3. Choose the smallest useful workflow: review, extract, recommend starter, audit design system, package feedback, or prepare Operator Kit task.
4. Do not edit production UI during review mode unless the user explicitly asks for implementation.
5. When Agent Operator Kit is installed or `$operator` is requested, collaborate with `$operator` for status checks, lane safety, dispatch, collection, working-file placement, and integration review.
   In an installed Operator project, a `$design-agent` request is dispatch-eligible by default unless the user explicitly asks for review-only chat output.
6. In Operator Kit projects, put temporary design artifacts under `$OPERATOR_DIR/tasks/<slug>/work/`, not in the repo.

## Core Workflows

### Review

Use when the user asks for a UX, design consistency, or design-system drift review.

Produce a concise report covering:

- detected stack and project scenario,
- current design-system state,
- starter recommendation if no strong system exists,
- UX consistency findings,
- visual/token/type/spacing drift,
- component inconsistencies,
- flow and state issues,
- accessibility/copy basics,
- next Claude Code or Operator Kit task.

### Extract

Use for existing codebases without a clear design system.

Inspect code, components, themes, CSS variables, screenshots or previews when available, and product copy. Separate intentional patterns from drift. Produce or propose:

```text
design-system/
design-system-recommendation.md
design-system-adoption-plan.md
drift-report.md
```

### Recommend Starter

Prefer the curated starter shelf before going custom:

- `shadcn-radix-tailwind`: default for founder/SaaS/internal-tool React projects.
- `material-ui`: broad apps aligned with Material Design.
- `ant-design`: dense enterprise dashboards, tables, forms, workflows.
- `mantine`: pragmatic SaaS React apps.
- `chakra-ui`: accessibility/component-system reference.

Always explain selected starter, rejected alternatives, tradeoffs, and adaptation plan.

### Audit Design System

Use when `design-system/` already exists. Check whether Claude Code can use it without extra chat-only context:

- `README.md` explains product context and file map.
- tokens have semantic names and usage comments.
- brand voice and anti-patterns are present.
- caveats and provenance are explicit.
- forkable full-screen kits exist.
- components document states, usage, and anti-patterns.

### Package Feedback

Use after Codex web preview annotations or user feedback. Classify feedback before creating follow-up work:

| Feedback | Target |
| --- | --- |
| Whole-product feel | `design-system/principles.md`, `tokens/*`, `brand/voice.md` |
| Repeated component issue | `design-system/components/*` |
| Screen pattern issue | `design-system/kits/*` |
| Journey/order issue | task spec or flow docs |
| One-off issue | current UI implementation |

Rule: update the highest reusable layer that explains the feedback.

## Temporary Design Artifacts

When working inside an Operator Kit project, all temporary design files belong
under the task working folder:

```text
OPERATOR_DIR/tasks/<slug>/work/
```

Use it for review READMEs, redesign options, HTML prototypes, screenshots,
generated images, exported assets, PDFs, and exploratory markdown. Do not place
these files in the repo unless the operator intentionally promotes them into
source, `design-system/`, or evergreen docs.

## Operator Collaboration

When `$operator` is available or requested, do not bypass it.

Use this split:

```text
$design-agent = UX/design-system reasoning, feedback classification, task content
$operator = project detection, lane safety, dispatch, collection, integration review
```

Suggested flow:

1. `$operator` detects the project and runs status/summary.
2. `$design-agent` inspects design context and drafts task packet content.
3. `$operator` creates task folders under `$OPERATOR_DIR`, checks lane/file ownership, stores cross-lane design facts in task memory when useful, and dispatches a Claude Code Fable 5 lane with `operator-dispatch.sh`.
4. `$design-agent` writes or asks lanes to write temporary design artifacts under `$OPERATOR_DIR/tasks/<slug>/work/`.
5. `$operator` collects the result.
6. `$design-agent` reviews output and packages next feedback.

## Claude Code Fable 5 Dispatch Default

When `$design-agent` is used in an installed Operator project and the request
asks to explore, redesign, produce, implement, package, or otherwise advance
design work, default to a Claude Code lane running:

```bash
claude --model fable --safe-mode --permission-mode dontAsk
```

Use this routing:

1. Prefer an existing `design` lane whose owner is Claude Code.
2. Otherwise use an existing Claude Code `ui` lane.
3. If the selected Claude Code lane invocation does not include
   `--model fable`, have `$operator` repair the lane invocation before dispatch
   when project config edits are allowed; otherwise stop and report the stale
   lane configuration.
4. If no Claude Code design/UI lane exists, stop and ask for a lane-map update
   or Operator project setup rather than running ad hoc edits in the source
   checkout.

Use `$OPERATOR_DIR/tasks/<slug>/work/` for explorations, HTML prototypes,
screenshots, generated images, PDFs, and proposal READMEs. Promote only accepted
durable artifacts into source, `design-system/`, or evergreen docs.

Do not create design/UI lanes everywhere by default. Recommend:

- direct Claude Code Fable 5 for early projects,
- `ui` lane only for straightforward implementation,
- `design` + `ui` lanes when a reviewable design mockup/handoff is worthwhile.

## Three-Proposal Review Flow

For reviewable design exploration, create `proposal-a`, `proposal-b`, and
`proposal-c` under the active feature's `work/design-options/` folder. Proposal
workers never select a direction. Record implementation dependencies in the
feature's local graph with approval `pending`; only an explicit human choice
changes it to `approved`. The graph remains advisory and dispatch stays with the
operator.

## References

Load only what the task needs:

- `references/workflows.md`: scenario selection and output contracts.
- `references/review-rubric.md`: comprehensive UX/design consistency review criteria.
- `references/starter-selection.md`: starter shelf and selection rules.
- `references/operator-collaboration.md`: Agent Operator Kit task-shaping details.
