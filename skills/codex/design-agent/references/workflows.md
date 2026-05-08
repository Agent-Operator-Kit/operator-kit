# Design Agent Workflows

## New Project

Use when there is no app or design system.

```text
brief + references
  -> choose curated starter
  -> optionally explore 2-3 foundation directions
  -> generate design-system/
  -> create 1-2 kits
  -> run Claude Code Opus UI task
  -> review in Codex
```

Outputs:

```text
design-system-recommendation.md
design-system/
design-system-adoption-plan.md
```

## Existing Codebase

Use when an app exists but no explicit design system exists.

```text
repo + components + CSS/theme + rendered screens
  -> code-first extraction
  -> identify intentional patterns vs drift
  -> select closest starter or custom base
  -> normalize into design-system/
  -> create adoption plan
```

Outputs:

```text
design-system-recommendation.md
design-system/
design-system-adoption-plan.md
drift-report.md
```

## Existing Design System

Use when tokens/components/docs already exist.

```text
existing design-system/
  -> audit for LLM-readiness
  -> add semantics, caveats, voice, anti-patterns
  -> add or improve kits
  -> validate Claude Code can use it
```

Outputs:

```text
design-system-audit.md
design-system-improvement-plan.md
```

## Ideation First

Use when product/UI direction is unclear.

```text
brief
  -> explore multiple directions
  -> include provisional foundation hypothesis when useful
  -> pick direction
  -> write ideation-handoff.md
  -> map onto design-system/ in production
```

The handoff preserves intent, not implementation. Placeholder color/type/copy should be reinterpreted inside the real design system.

## Figma Source

Use later when Figma is strongest source of truth.

Prefer one-way local mirror:

```text
Figma
  -> export tokens/styles/components/screens
  -> write local design-system/
  -> add missing why, voice, anti-patterns, caveats
  -> Claude Code reads local files only
```

Avoid live Figma dependency for ordinary design lane tasks.
