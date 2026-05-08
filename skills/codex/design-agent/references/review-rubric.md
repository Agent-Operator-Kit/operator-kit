# UX And Consistency Review Rubric

Use this for comprehensive project reviews.

## Project Context

- What product is this?
- Who is the primary user?
- What workflow is the UI optimized for?
- Is this SaaS/internal tool, consumer app, content site, marketplace, or agentic workflow?

## Design-System State

- Is there a `design-system/` folder?
- Are tokens semantic and documented?
- Are voice, caveats, anti-patterns, and provenance present?
- Are there forkable full-screen kits?
- Are components documented with usage, states, and anti-patterns?

## Visual Consistency

- Color usage and raw hex drift.
- Typography scale and hierarchy.
- Spacing/radii/elevation consistency.
- Density across similar surfaces.
- Icon style and button patterns.
- Repeated card/table/form patterns.

## UX Consistency

- Navigation model.
- Primary action placement.
- Empty/loading/error/success states.
- Form and validation behavior.
- Information hierarchy.
- Decision points and flow order.
- Reversibility, confirmation, and destructive actions.

## Copy And Voice

- Tone consistency.
- Button and empty-state copy.
- Casing.
- Avoided words or product language drift.
- Placeholder/filler copy.

## Accessibility Basics

- Keyboard-visible affordances.
- Label clarity.
- Contrast risks.
- Focus/hover/disabled states.
- Semantic structure.

## Output Shape

Lead with findings, then fixes:

```markdown
# Design Agent Review

## Summary

## Detected Stack

## Design-System State

## High-Priority Findings

## UX Flow Findings

## Visual Consistency Findings

## Design-System Opportunities

## Recommended Starter / Foundation

## Next Claude Code Task

## Operator Kit Recommendation
```
