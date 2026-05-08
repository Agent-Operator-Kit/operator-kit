---
name: design-agent
description: Use for product UX and design-system work in Codex Desktop projects: comprehensive UX and consistency reviews, code-first design-system extraction, starter recommendation, design-system audits, annotation feedback classification, and preparing Claude Code or Agent Operator Kit design/UI tasks.
---

# Design Agent

Use this skill as Codex Desktop's design/UX orchestration layer. It establishes, reviews, and evolves project design systems, then packages design/UI work for Claude Code Opus or Agent Operator Kit lanes.

Claude Code Opus is the preferred executor for production design/UI edits. Codex is the review, annotation, task-shaping, and design-system memory surface.

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
5. When Agent Operator Kit is installed or `$operator` is requested, collaborate with `$operator` for status checks, lane safety, dispatch, collection, and integration review.

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
3. `$operator` creates task folders under `$OPERATOR_DIR`, checks lane/file ownership, and dispatches with `operator-dispatch.sh`.
4. `$operator` collects the result.
5. `$design-agent` reviews output and packages next feedback.

Do not create design/UI lanes everywhere by default. Recommend:

- direct Claude Code Opus for early projects,
- `ui` lane only for straightforward implementation,
- `design` + `ui` lanes when a reviewable design mockup/handoff is worthwhile.

## References

Load only what the task needs:

- `references/workflows.md`: scenario selection and output contracts.
- `references/review-rubric.md`: comprehensive UX/design consistency review criteria.
- `references/starter-selection.md`: starter shelf and selection rules.
- `references/operator-collaboration.md`: Agent Operator Kit task-shaping details.

