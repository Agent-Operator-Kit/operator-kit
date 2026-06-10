# Operator Plugin Mode Agent Chat Cheat Sheet

Use this one-pager when Operator Kit is available through an agent host and each
project is activated explicitly. Fresh machines should start with the GitHub
source. Existing machines should detect first, then update only after previewing
the change.

Source:

```text
https://github.com/Agent-Operator-Kit/operator-kit.git
```

Use `main` for stable installs. Use `codex/v3-integration` when testing the V3
plugin or adapter branch.

## Codex Desktop View

1. Install global plugin:

```text
Fresh machine: install the Operator Kit Codex plugin from
https://github.com/Agent-Operator-Kit/operator-kit.git. Use main for stable, or
codex/v3-integration for V3 testing. Run the plugin dry-run first, show the
changes, then install only if correct.
```

2. Create project foundation:

```text
operator install

Set up Operator for this project. If this is a new scoped workspace, propose
code/app plus operator. Inspect first, report the plan, and stop before
dispatch.
```

3. Confirm the project foundation report:

```text
Scoped layout: code/app plus operator, or detected repo root.
Lanes: owner lanes, worktrees, branches, and file boundaries.
Architecture: repos, modules, contracts, risks, and dependency edges.
System map: generated or refreshed before planning.
Role catalog: roles, approved patterns, validation recipes, and gates.
Validation: build, test, lint, smoke, and review commands.
Memory: project facts, task facts, and retrieval readiness.
Roadmap: inbox, RM-* status, blockers, and setup gaps.
```

4. Use the agent order:

```text
Incubate: use for rough ideas, thesis framing, customer, wedge, risks,
experiments, and promotion briefs.

Design agent: use for product shape, UX, UI systems, design reviews, design
lane guidance, and UI task packets.

Feedback: use while testing screens, mobile builds, annotations, screenshots,
or raw observations. Capture classified FB-* intake, not implementation.

Planner: use to group feedback, prioritize now/next/later, promote RM-* roadmap
items, assign owner lanes, and draft acceptance criteria.

Operator: use for setup, lane orchestration, dispatch preflight, task packets,
collect, review, integration loop, and memory updates.
```

5. Observe and execute loop:

```text
operator observe
status
what is blocked?
summarize roadmap

operator active
create the confirmed task packet.

operator dispatch
dispatch the approved lane task.
collect the lane handoff and review it.
```

6. Check, update, disable:

```text
Check whether Operator is installed and current. Report plugin availability,
project config, lane health, system map, memory, roadmap, and update path.
Preview updates first and preserve project-local state.

operator off
```

## Cursor Agent View

Cursor uses project rules, skills, and adapter assets rather than a hidden
Codex-style plugin.

1. Install Cursor assets:

```text
Fresh machine: initialize Agent Operator Kit from
https://github.com/Agent-Operator-Kit/operator-kit.git. Use main for stable, or
codex/v3-integration for V3 testing. Install Cursor rules, skills, and project
assets, then report changed files before any dispatch.
```

2. Create project foundation:

```text
Use the operator-workflow skill. Set up Operator for this project. If this is a
new scoped workspace, propose code/app plus operator. Inspect first, report the
plan, and stop before dispatch.
```

3. Confirm the project foundation report:

```text
Scoped layout: code/app plus operator, or detected repo root.
Lanes: owner lanes, worktrees, branches, and file boundaries.
Architecture: repos, modules, contracts, risks, and dependency edges.
System map: generated or refreshed before planning.
Role catalog: roles, approved patterns, validation recipes, and gates.
Validation: build, test, lint, smoke, and review commands.
Memory: project facts, task facts, and retrieval readiness.
Roadmap: inbox, RM-* status, blockers, and setup gaps.
```

4. Use the agent order:

```text
Incubate: use for rough ideas, thesis framing, customer, wedge, risks,
experiments, and promotion briefs.

Design agent: use for product shape, UX, UI systems, design reviews, design
lane guidance, and UI task packets.

Feedback: use while testing screens, mobile builds, annotations, screenshots,
or raw observations. Capture classified FB-* intake, not implementation.

Planner: use to group feedback, prioritize now/next/later, promote RM-* roadmap
items, assign owner lanes, and draft acceptance criteria.

Operator: use for setup, lane orchestration, dispatch preflight, task packets,
collect, review, integration loop, and memory updates.
```

5. Observe and execute loop:

```text
Use the operator skill for this project.
Check status, blockers, lanes, memory, roadmap, and setup gaps.

Create the confirmed task packet with acceptance criteria.
Do not dispatch until I confirm.

Dispatch the approved task, collect the handoff, inspect changed files, and
recommend whether it is ready to integrate.
```

6. Check, update, disable:

```text
Use the operator-workflow skill. Check whether Cursor Operator assets and
project-local Operator files are current. Report project config, lane health,
system map, memory, roadmap, and update path. Preview updates first and preserve
project-specific state.

Stop using Operator by default for now.
```

## Safety Line

Operator mode changes routing, not authority. Dispatch, collect, merge, push,
tag, release, destructive cleanup, provider-console changes, and credential
changes still require clear intent, a selected project, preflight, and review.
