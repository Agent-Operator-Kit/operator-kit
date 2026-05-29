---
name: user-journey
description: Create persona, ICP, journey map, service blueprint, storyboard, and Canvas or HTML journey artifacts. Use when the user asks to map a user journey, define persona or ICP, create journey artifacts, storyboard a flow, visualize a UX transition, or prepare artifacts for a UX audit.
---

# User Journey

Use this skill to produce user-journey artifacts for product/design work. It can
stand alone or feed `ux-auditor`.

## Start Routine

1. Identify the product area and scenario.
2. Define one primary actor per journey. If there are multiple actors, create
   separate maps or clearly mark primary versus secondary roles.
3. Capture or infer:
   - persona;
   - ideal customer profile (ICP), for B2B or enterprise products;
   - scenario and goal;
   - current touchpoints;
   - first-value moment;
   - success metric.
4. Inspect available evidence: screenshots, UI code, copy, Figma, prior notes,
   analytics, support feedback, or operator task memory.
5. Choose the smallest useful artifact set.

## Artifact Types

Use a journey map when the team needs to understand the user's frontstage
experience.

Use a service blueprint when frontstage friction depends on hidden system,
process, data, or ownership work.

Use a storyboard when stakeholders need a screen-by-screen narrative.

Use Canvas when the artifact should be reviewed beside the app or chat. Use
standalone HTML when the artifact should be shared outside Cursor or used as a
lightweight prototype.

## Default Artifact Set

For a substantial flow review, produce:

- persona and ICP;
- scenario and success metric;
- journey map with stages, actions, thoughts, feelings, touchpoints, pain points,
  and opportunities;
- service-blueprint strip with frontstage UI, backstage work, evidence needed,
  failure modes, and design response;
- storyboard frames for key moments;
- recommendation for Canvas, HTML, or implementation task.

## Journey Map Template

```markdown
# [Flow] User Journey

Actor:
Scenario:
First-value moment:
Success metric:

| Stage | User action | Thought | Feeling | Touchpoint | Pain point | Opportunity |
| --- | --- | --- | --- | --- | --- | --- |
| ... | ... | ... | ... | ... | ... | ... |
```

## Service Blueprint Template

```markdown
| Stage | Frontstage UI | Backstage work | Evidence needed | Failure mode | Design response |
| --- | --- | --- | --- | --- | --- |
| ... | ... | ... | ... | ... | ... |
```

## Quality Bar

- One journey equals one primary persona and one scenario.
- Avoid generic personas; include role, goal, anxiety, and first-value moment.
- For B2B products, include buyer/user split and ICP context.
- Opportunities must be actionable, not observations.
- If confidence is low, mark assumptions and suggest research needed.

## Operator Collaboration

When Agent Operator Kit is installed:

1. Let `operator` handle project detection, lane safety, dispatch, and collection.
2. Store temporary journey artifacts under `OPERATOR_DIR/tasks/<slug>/work/`.
3. Promote only concise reusable facts into task memory.
