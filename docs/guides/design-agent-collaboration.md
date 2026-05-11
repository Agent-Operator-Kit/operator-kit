# Design Agent Collaboration

Design Agent is an optional Codex Desktop skill for UX review, design-system extraction, starter recommendation, annotation feedback classification, and preparing design/UI tasks for Claude Code or Agent Operator Kit lanes.

It composes with `$operator` instead of replacing it.

```text
$design-agent = design/UX intelligence and task shaping
$operator = lane safety, dispatch, collection, integration review
```

## Install The Skill

From the Operator Kit source repo:

```bash
bash scripts/codex-skills-install.sh --skill design-agent
```

The runtime `$operator` skill and all bundled Codex Desktop skills can also be installed or refreshed with:

```bash
bash scripts/codex-skills-install.sh
```

Restart Codex Desktop after installing or updating skills.

## Typical Requests

```text
Use $design-agent. Do a comprehensive UX and consistency review of this project.
Use $design-agent. Extract a design system from this existing codebase.
Use $design-agent. Recommend a design-system starter for this project.
Use $design-agent with $operator. Package my annotations into a design follow-up task.
Use $design-agent with $operator. Prepare and dispatch a design-system extraction task.
```

## Operator-Aware Flow

When a project has Agent Operator Kit installed:

1. `$operator` detects the project and checks lane status.
2. `$design-agent` inspects the UI, design-system, and product context.
3. `$design-agent` drafts task packet content and acceptance criteria.
4. `$operator` creates the task folder, checks lane/file ownership, and dispatches.
5. `$operator` collects output.
6. `$design-agent` reviews the output and classifies follow-up feedback.

## Lane Recommendations

Start simple:

```text
Codex review + Claude Code Opus direct edits + design-system/
```

Add lanes only when the project needs them:

```text
ui|Claude Code|app-ui|claude/ui|claude --model opus --dangerously-skip-permissions --permission-mode bypassPermissions
design|Claude Code|app-design|claude/design|claude --model opus --dangerously-skip-permissions --permission-mode bypassPermissions
```

Use a `design` lane when the project benefits from reviewable mockups or design handoffs before production UI implementation.

## Incubation Handoff

When design work starts from a not-yet-promoted idea, use `$incubation` first to capture the thesis, assumptions, and promotion brief:

```text
Use $incubation with $design-agent. Turn this product thesis into design-system starting assumptions.
```

After promotion, use `$operator` for project setup, lane safety, dispatch, and collection.
