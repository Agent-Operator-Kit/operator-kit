# Cursor Operator Workflow

Use this guide when Cursor is the primary operator IDE for an Agent Operator Kit
project.

Operator Kit is an operating layer that integrates with the coding surfaces you
have. When Cursor is available, Cursor Composer or Agent makes a natural
operator cockpit; when Codex is available, Codex Desktop can be the cockpit
instead; when both are available, pick per project. The lane map, task packets,
worktrees, tmux sessions, feedback intake, roadmap promotion, memory router,
handoffs, and integration review stay the same regardless of which IDE owns the
operator role.

This guide focuses on the Cursor cockpit setup.

## Cursor-First Shape

The preferred first-time UX is agent-run install: open Cursor Agent in the
target repo and point it at the kit URL.

```text
Install or initialize Agent Operator Kit for this project from:
https://github.com/Agent-Operator-Kit/operator-kit.git

Use Cursor as the operator cockpit. Detect whether Operator Kit is already
installed. If it is installed, upgrade/refresh it. If it is missing, install it
with the Cursor bootstrap profile. Configure these lanes:
- operator: Cursor IDE on the stable branch
- web: web app lane
- agents-api: optional lane for agent/API integration work

Always use the operator skill for this project unless I explicitly ask for
feedback, planning, design, UX audit, journey mapping, setup, or non-operator work.
```

The agent should inspect first, detect installed/partial/missing state, then run
the appropriate install or refresh path. If the lane requirements are clear, it
can write `operator.config.env`; otherwise it should propose the lane map before
creating worktrees.

For teams without Codex, the underlying command is the Cursor profile:

```bash
bash scripts/operator-sync.sh --target /path/to/repo --bootstrap-if-missing --bootstrap-profile cursor --skip-skills
```

or:

```bash
bash scripts/operator-bootstrap.sh --profile cursor /path/to/repo
```

The generated lane map starts with:

```text
operator|Cursor IDE|app|main|
cursor|Cursor CLI|app-cursor|cursor/operator|cursor agent
ui|Claude Code|app-ui|claude/ui|claude --dangerously-skip-permissions --permission-mode bypassPermissions
```

Review `operator.config.env` before creating worktrees or starting workers. Some
machines expose the local agent as `cursor agent`; others provide
`cursor-agent`.

For a web app plus agent/API lane, a typical Cursor lane map is:

```text
OPERATOR_LANES='
operator|Cursor IDE|app|main|
web|Cursor CLI|app-web|cursor/web|cursor agent
agents-api|Cursor CLI|app-agents-api|cursor/agents-api|cursor agent
'
```

## Cursor Primitives

- `AGENTS.md` carries portable baseline instructions for all agents.
- `.cursor/rules/*.mdc` carries persistent Cursor project policy.
- `.cursor/skills/*/SKILL.md` carries reusable operator procedures.
- `.cursor/agents/*.md` can define specialist subagents for review, research,
  validation, debugging, and release checks.
- Cursor CLI can run in a tmux lane for durable local work.
- Cursor Cloud Agents, formerly Background Agents, are remote branch workers and do not share local
  `OPERATOR_DIR`, tmux, or simulators.

Treat subagents as temporary specialist contexts. Treat operator lanes as
durable worktree, branch, and process boundaries.

## Explicit Cursor Skills

Installed projects include Cursor-native skills that mirror the Codex operator
modes:

```text
operator          -> execution, task packets, dispatch, collect, integration
operator-feedback -> feedback intake and FB-* capture
operator-planner  -> roadmap/backlog planning and ready-for-execution plans
design-agent      -> UX/design-system review and UI task shaping
ux-auditor        -> scored UX audits and prioritized recommendations
user-journey      -> persona, ICP, journey map, blueprint, and storyboard artifacts
incubation        -> idea framing, critique, durable idea files, promotion readiness
operator-workflow -> setup, bootstrap, repair, upgrade, and general operations
```

Invoke them deliberately in Cursor Agent:

```text
Use the operator skill. Run status and summary, then create a task packet for the backend lane.
Use the operator-planner skill. Review feedback and propose now/next/later.
Use the operator-feedback skill. Capture these simulator notes as FB-* intake.
Use the design-agent skill with operator. Review the UI and prepare a lane-ready task.
Use the ux-auditor skill. Score this onboarding flow against the persona and ICP.
Use the user-journey skill. Map the first-value journey.
Use the incubation skill. Frame this idea and prepare the next experiment.
```

To make operator mode the default for a project or session, say:

```text
Always use the operator skill for this project unless I explicitly ask for feedback, planning, design, UX audit, journey mapping, incubation, setup, or non-operator work.
```

The installed always-applied Cursor rule records the routing convention, so new
Cursor chats in the same project should prefer the operator skill for execution
requests.

## Local Operating Loop

Start from the operator lane in Cursor:

```bash
bash scripts/operator-status.sh
bash scripts/operator-summary.sh
bash scripts/operator-memory.sh status
bash scripts/operator-roadmap.sh status
```

Create task state outside the repo:

```bash
bash scripts/operator-task.sh auth-001 "Auth scaffolding"
```

Write lane-specific task packets under:

```text
OPERATOR_DIR/tasks/auth-001/tasks/
```

Dispatch to a local tmux lane when appropriate:

```bash
bash scripts/operator-dispatch.sh --with-memory cursor "$OPERATOR_DIR/tasks/auth-001/tasks/cursor.md"
```

Collect the result as an external handoff:

```bash
bash scripts/operator-collect.sh cursor auth-001
```

Then review the worker branch from Cursor, run validation, and integrate only
approved source changes into the stable branch.

## Feedback To Execution

Cursor-first projects use the same script-backed mode split as Codex projects:

```text
Feedback   -> bash scripts/operator-feedback.sh ...
Planning   -> bash scripts/operator-roadmap.sh ...
Execution  -> bash scripts/operator-task.sh / dispatch / collect / summary
```

Feedback is observation. Planning decides what becomes work. Execution starts
only after the operator has a scoped task packet and lane ownership.

## Cloud Agents

Use Cursor Cloud Agents for isolated remote branch work: documentation cleanup,
small refactors, focused bug fixes, and tests. Do not assume they can see local
operator state. Put the task packet, relevant memory, validation commands, and
handoff requirements directly in the prompt or PR description.

Use `.cursor/environment.json.example` as the starting point for Cloud Agent
setup, then adapt it to the target project before saving `.cursor/environment.json`.

## Model Selection

Choose GPT-5.5 or another Cursor model through Cursor's configured model picker,
CLI support, or company policy. Do not hard-code model flags in the lane map
unless the local Cursor CLI documents and supports them.

## Upgrade

Cursor-only machines can skip Codex Desktop skill refresh:

```bash
bash scripts/operator-upgrade.sh --skip-skills
```

For one project:

```bash
bash scripts/operator-sync.sh --target /path/to/repo --skip-skills
```
