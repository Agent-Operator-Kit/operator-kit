---
name: incubation
description: "Manage lightweight idea incubation in Codex. Use when Codex is working inside an Incubation workspace or idea folder, creating a new idea, clarifying and critiquing a product/business idea, capturing chat learnings into durable markdown, reviewing/prioritizing ideas, archiving ideas, or promoting an idea into a dedicated project and later Agent Operator Kit setup."
---

# Incubation

Use this skill to keep ideation lightweight while preserving durable context. Treat chat as the working surface and the idea folder as the source of truth.

## Workspace Model

Default root:

```text
/Users/norbert/Incubation/
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

Do not initialize Agent Operator Kit inside Incubation. Reserve Operator Kit for promoted projects under:

```text
/Users/norbert/Projects/<product-slug>/
  code/
    app/
  operator/
```

## Resolve The Active Idea

1. If the working directory is inside `ideas/<slug>/`, use that slug.
2. If the user names an idea or path, use the matching `ideas/<slug>/`.
3. If the user asks to create a new idea, slugify the name, create `ideas/<slug>/`, and copy files from `_templates/idea/`.
4. If multiple ideas match or no idea is clear, ask one concise question.

## Start Routine

At the start of meaningful idea work:

1. Read `/Users/norbert/Incubation/AGENTS.md`.
2. Read the active idea's `README.md`, `framing.md`, `promotion-brief.md`, `decision-log.md`, and any obviously relevant file.
3. Keep initial context loading small. Read deeper files only when needed.

## Framing Gate

When the user introduces a new idea, rough thought, pivot, or material change in direction, run a framing pass before deciding next steps.

Provide a concise chat response with:

- Clearer one-liner: sharpen the idea into one sentence.
- Current frame: target user, painful job, existing alternatives, proposed wedge, and why now.
- Hidden assumptions: list the assumptions that must be true.
- Contrarian critique: make the strongest case against the idea, including why users might not care, why distribution may fail, or why incumbents could win.
- Clarifying questions: ask up to three high-leverage questions only if the answers would materially change the next move.
- Preliminary next move: propose the smallest useful next step, but label it preliminary until the framing is accepted or corrected.

Do not jump to implementation, promotion, or a large research plan before this framing pass. If the user gave enough context, proceed with explicit assumptions instead of blocking on questions.

## Capture Routine

Before the final response, if the session produced meaningful learning, update the active idea files without waiting for a close prompt.

Use these defaults:

- `README.md`: keep concise; update current thesis, status, next experiment, and open questions.
- `framing.md`: update the clarified frame, assumptions, contrarian critique, and open questions.
- `decision-log.md`: append dated decisions, rejected paths, and important rationale.
- `experiments.md`: update next experiment, backlog, or results.
- `promotion-brief.md`: update promotion status, MVP, risks, checklist, and conviction.
- `_ops/review-board.md`: update the row for the idea when status, conviction, or next experiment changes.
- `_ops/promoted.md` or `_ops/archived.md`: update only when promotion or archive actually happens.

Prefer compact edits over verbose notes. Preserve useful prior thinking; do not overwrite decisions unless explicitly correcting them.

## Exploration Style

Help the user move from vague idea to sharper operating hypothesis:

- Start high level, then go deeper when useful.
- Separate thesis, customer, market, distribution, product shape, risks, and next experiment.
- Convert ideation into falsifiable experiments quickly.
- Keep experiments smaller than full builds unless the user explicitly asks for implementation.
- Call out weak assumptions directly and propose the next evidence-gathering step.

## Promotion Workflow

When the user asks to promote an idea:

1. Finalize the active idea's `promotion-brief.md`.
2. Create `/Users/norbert/Projects/<product-slug>/code/app` and `/Users/norbert/Projects/<product-slug>/operator`.
3. Copy or summarize incubation context into the promoted project; avoid dragging every scratch note forward.
4. Update `_ops/promoted.md`.
5. Initialize Agent Operator Kit only in the promoted repo when the user asks for setup or when the target repo/app shell exists and promotion explicitly includes setup.

Do not commit, push, deploy, or initialize production infrastructure unless the user explicitly asks.

## Operator Collaboration

When `$operator` is available or the user wants to promote an idea into an Operator Kit project, use this split:

```text
$incubation = idea framing, durable idea files, promotion readiness
$operator = promoted-project setup, lane safety, dispatch, collection, integration review
$design-agent = UX/design-system review and UI task shaping
```

Suggested flow:

1. `$incubation` sharpens the idea and captures durable context in `/Users/norbert/Incubation/ideas/<slug>/`.
2. `$incubation` prepares or updates `promotion-brief.md`.
3. Only after explicit promotion, create or prepare `/Users/norbert/Projects/<product-slug>/code/app`.
4. `$operator` initializes or operates Agent Operator Kit in the promoted project repo, not in Incubation.
5. `$design-agent` can review UX/design-system direction before UI lanes are dispatched.

Suggested combined requests:

```text
Use $incubation. Frame this idea and capture the next experiment.
Use $incubation. Prepare this idea for promotion into an Operator Kit project.
Use $incubation with $operator. Promote this idea, then set up Operator Kit in the promoted repo.
Use $incubation with $design-agent. Turn this product thesis into design-system starting assumptions.
```
