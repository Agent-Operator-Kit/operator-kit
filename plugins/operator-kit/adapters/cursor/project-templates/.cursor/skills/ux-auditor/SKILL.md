---
name: ux-auditor
description: UX Auditor scores and assesses product UX against persona, ICP, user journey, usability, and business fit. Use when reviewing a screen, flow, screenshot, prototype, Canvas, or design proposal and the user asks for a UX audit, UX review, product experience audit, persona fit, ICP fit, journey risks, score, assessment, or prioritized recommendations.
---

# UX Auditor

Use this skill to evaluate a product experience and produce a scored UX audit.
Do not implement UI changes during audit mode unless the user explicitly asks.

## Start Routine

1. Identify the object under review: screen, flow, screenshot, prototype, Canvas,
   code route, Figma frame, or written proposal.
2. Capture or infer:
   - primary persona;
   - ideal customer profile (ICP);
   - scenario and user goal;
   - first-value moment;
   - business or adoption outcome.
3. If any of these are unknown, state assumptions rather than blocking unless the
   missing detail would materially change the audit.
4. Inspect available evidence: screenshots, code, copy, design system, analytics,
   prior journey artifacts, or operator task memory.
5. Produce a scored assessment with findings and recommendations.

## Scorecard

Default weights total 100:

- Persona fit: 15
- ICP / business fit: 15
- Journey coherence: 20
- Activation and readiness clarity: 15
- Usability and accessibility: 15
- Evidence and measurement quality: 10
- Recommendation clarity: 10

Adjust weights only when the user gives a different rubric.

## Output Format

Lead with the score and verdict:

```markdown
## UX Audit

Overall: 72 / 100 — Promising but unclear at the transition point.

### Scorecard
- Persona fit: ...
- ICP / business fit: ...

### Highest-Risk Findings
1. [Severity] Finding grounded in evidence.
2. [Severity] Finding grounded in evidence.

### Recommendations
1. Change ...
2. Test ...

### Assumptions
- ...
```

## Finding Standards

- Ground each finding in visible UI, code, copy, workflow state, or stated user
  context.
- Tie recommendations to persona, ICP, or journey risk.
- Separate must-fix blockers from optional polish.
- If the problem is journey/order related, recommend a `user-journey` artifact.
- If the problem is implementation-ready, shape a task for `operator`.

## Operator Collaboration

When Agent Operator Kit is installed:

1. Let `operator` handle lane safety, dispatch, collection, and integration.
2. Put audit scratch work under `OPERATOR_DIR/tasks/<slug>/work/`.
3. Do not commit raw audit packets, screenshots, or temporary review files unless
   they are promoted into durable docs.
