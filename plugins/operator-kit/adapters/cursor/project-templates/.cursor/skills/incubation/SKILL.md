---
name: incubation
description: Manage lightweight idea incubation from Cursor. Use when creating or refining product ideas, critiquing assumptions, capturing learnings into durable idea files, reviewing or prioritizing ideas, archiving ideas, or promoting an idea into an Agent Operator Kit project.
---

# Incubation

Use this skill to keep ideation lightweight while preserving durable context.
Treat chat as the working surface and the idea folder as the source of truth.

## Workspace Model

Default root:

```text
~/Incubation/
  _templates/idea/
  _ops/
  ideas/<slug>/
```

Each idea folder should usually contain:

- `README.md`
- `framing.md`
- `thesis.md`
- `customer.md`
- `market.md`
- `experiments.md`
- `decision-log.md`
- `promotion-brief.md`
- `archive.md`

Do not initialize Agent Operator Kit inside Incubation. Reserve Operator Kit for
promoted projects under a project workspace such as:

```text
~/Projects/<product-slug>/
  code/
    app/
  operator/
```

## Resolve The Active Idea

1. If the working directory is inside `ideas/<slug>/`, use that slug.
2. If the user names an idea or path, use the matching `ideas/<slug>/`.
3. If the user asks to create a new idea, slugify the name, create
   `ideas/<slug>/`, and copy files from `_templates/idea/` when present.
4. If multiple ideas match or no idea is clear, ask one concise question.

## Framing Gate

When the user introduces a new idea, rough thought, pivot, or material change in
direction, run a framing pass before deciding next steps.

Provide:

- Clearer one-liner: sharpen the idea into one sentence.
- Current frame: target user, painful job, alternatives, wedge, and why now.
- Hidden assumptions: what must be true.
- Contrarian critique: the strongest case against the idea.
- Clarifying questions: up to three only if answers would materially change the
  next move.
- Preliminary next move: the smallest useful experiment or evidence step.

Do not jump to implementation, promotion, or a large research plan before this
framing pass.

## Capture Routine

Before the final response, if the session produced meaningful learning, update
the active idea files without waiting for a close prompt.

Prefer compact edits:

- `README.md`: current thesis, status, next experiment, open questions.
- `framing.md`: clarified frame, assumptions, critique, open questions.
- `decision-log.md`: dated decisions, rejected paths, rationale.
- `experiments.md`: next experiment, backlog, results.
- `promotion-brief.md`: promotion status, MVP, risks, checklist, conviction.
- `_ops/review-board.md`: idea status, conviction, or next experiment.

Preserve useful prior thinking; do not overwrite decisions unless explicitly
correcting them.

## Promotion Workflow

When the user asks to promote an idea:

1. Finalize the active idea's `promotion-brief.md`.
2. Create or prepare the promoted project workspace only after explicit
   promotion.
3. Copy or summarize incubation context into the promoted project; avoid dragging
   every scratch note forward.
4. Update `_ops/promoted.md` when present.
5. Initialize Agent Operator Kit only in the promoted repo when the user asks for
   setup or promotion explicitly includes setup.

Do not commit, push, deploy, or initialize production infrastructure unless the
user explicitly asks.

## Operator Collaboration

When `operator` is available or the user wants to promote an idea into an
Operator Kit project, use this split:

```text
incubation   = idea framing, durable idea files, promotion readiness
operator     = promoted-project setup, lane safety, dispatch, integration review
design-agent = UX/design-system review and UI task shaping
```

Suggested requests:

```text
/incubation Frame this idea and capture the next experiment.
/incubation Prepare this idea for promotion into an Operator Kit project.
/incubation with /operator Promote this idea, then set up Operator Kit in the promoted repo.
/incubation with /design-agent Turn this thesis into design-system starting assumptions.
```
