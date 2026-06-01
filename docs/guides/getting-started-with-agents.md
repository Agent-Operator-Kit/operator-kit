# Getting Started

Agent Operator Kit is intended to be installed by an agent, not by a human following a long checklist.

Use this page when you want to open a fresh Codex, Claude Code, or Cursor session and ask it to set up the operator workflow end to end.

## Minimal Prompt

Open the agent in the target repo and paste this:

```text
Set up Agent Operator Kit for the current repo.

Use this source kit:
git@github.com:Agent-Operator-Kit/operator-kit.git

First clone or read the kit, then follow its agent-run bootstrap guide:
templates/prompts/agent-run-bootstrap.md
docs/guides/agent-run-bootstrap.md

Treat the current working directory as the target project repo.

Requirements:
- inspect the repo first
- propose the lane map before creating worktrees
- install the scripts/templates
- install Codex, Claude Code, and Cursor project assets when relevant
- install Operator Memory Router and verify memory status
- initialize the local Operator roadmap and feedback workspace
- explain how to install bundled Codex Desktop skills when relevant
- create the external operator workspace outside the repo
- create or verify worktrees without overwriting existing work
- start or inspect tmux
- create a smoke task
- run the status, summary, and memory checks
- report installed files, OPERATOR_DIR, lane map, memory status, smoke results, git status, and whether the repo is ready to commit

Guardrails:
- do not rewrite git history
- do not force-push
- do not commit secrets, raw handoffs, task packets, pane captures, task working files, memory packs, or transient notes
- do not deploy or run production builds during setup
```

## Codex

Start Codex in or near the target repo and paste the minimal prompt above, or use this shorter variant:

```text
Set up Agent Operator Kit for this project using:
git@github.com:Agent-Operator-Kit/operator-kit.git

Use the agent-run bootstrap flow. Inspect first, propose the lane map, install the scripts/templates and Operator Memory Router, create the external operator workspace, create or verify worktrees, start tmux, run a smoke task, and report whether the repo is ready to commit.

Keep generated task packets, handoffs, pane captures, task working files, and transient notes outside the repo.
```

For the full prompt, use:

```text
templates/prompts/agent-run-bootstrap.md
```

For Codex skill-style guidance, use:

```text
skills/codex/operator/SKILL.md
skills/codex/operator-workflow/SKILL.md
skills/codex/operator-feedback/SKILL.md
skills/codex/operator-planner/SKILL.md
skills/codex/design-agent/SKILL.md
skills/codex/ux-auditor/SKILL.md
skills/codex/user-journey/SKILL.md
skills/codex/incubation/SKILL.md
```

Use `operator-workflow` for setup and repair. After the kit is installed, install or refresh the bundled Codex Desktop skills globally:

```bash
bash scripts/codex-skills-install.sh
```

To update from the latest kit source first:

```bash
bash scripts/operator-sync.sh --skip-project
```

To refresh this Codex Desktop instance and every installed Operator Kit project
on the machine:

```bash
bash scripts/operator-upgrade.sh
```

Restart or reopen Codex Desktop, then operate installed projects with prompts like:

```text
Use $operator. Show project status.
Use $operator. Create a backend task for auth scaffolding.
Use $operator. Dispatch the backend task with memory.
Use $operator. Collect backend result for auth-001 and tell me if it is ready to integrate.
Use $operator. Update to latest version from git.
Use $operator-feedback with $design-agent. Capture these annotations as feedback.
Use $operator-planner. Review local feedback and propose the next lane schedule.
Use $incubation with $operator. Prepare this idea for promotion into an Operator Kit project.
Use $design-agent with $operator. Prepare a UX follow-up task for the UI lane.
Use $ux-auditor. Score this onboarding flow against the target persona and ICP.
Use $user-journey. Map the first-value journey and service blueprint.
```

The `$operator` skill detects `operator.config.env` and the required `scripts/operator-*.sh` files. If the kit is partially installed or missing, it reports what is missing instead of dispatching unsafe work.

Full guide:

```text
docs/guides/codex-operator-skill.md
```

## Claude Code

Start Claude Code in or near the target repo and paste:

```text
Set up Agent Operator Kit for this project using:
git@github.com:Agent-Operator-Kit/operator-kit.git

Use the agent-run bootstrap flow. Inspect first, propose the lane map, install the scripts/templates and Operator Memory Router, create the external operator workspace, create or verify worktrees, start tmux, run a smoke task, and report whether the repo is ready to commit.

Install the Claude Code project assets too:
- .claude/commands/operator-bootstrap.md
- .claude/commands/operator-status.md
- .claude/agents/operator-workflow.md

Keep generated task packets, handoffs, pane captures, task working files, memory packs, and transient notes outside the repo.
```

For Claude Code, the reusable assets are project slash commands and a project subagent. Agent Operator Kit stores those as templates so bootstrap can install them into the target repo.

After installation, Claude Code users can run:

```text
/operator-status
```

or:

```text
/operator-bootstrap <absolute path to repo>
```

They can also explicitly invoke the project subagent:

```text
Use the operator-workflow subagent to inspect this repo and set up Agent Operator Kit.
```

## Cursor

Start Cursor Agent or Cursor CLI in or near the target repo and paste:

```text
Install or initialize Agent Operator Kit for this project from:
https://github.com/Agent-Operator-Kit/operator-kit.git

Use Cursor as the frontend operator surface. Inspect first, detect whether
Operator Kit is already installed, then install, repair, or upgrade as needed.
Configure the lane map from the lanes I describe below, create or verify
worktrees, start or inspect tmux, run a smoke task, and report whether the repo
is ready to commit.

Lane requirements:
- operator: Cursor IDE on the stable branch
- web: web app lane
- agents-api: optional lane for agent/API integration work

Install the Cursor project assets too:
- .cursor/rules/operator-workflow.mdc
- .cursor/skills/operator-workflow/SKILL.md
- .cursor/skills/operator/SKILL.md
- .cursor/skills/operator-planner/SKILL.md
- .cursor/skills/operator-feedback/SKILL.md
- .cursor/skills/design-agent/SKILL.md
- .cursor/skills/ux-auditor/SKILL.md
- .cursor/skills/user-journey/SKILL.md
- .cursor/skills/incubation/SKILL.md
- .cursor/environment.json.example

Keep generated task packets, handoffs, pane captures, task working files, memory packs, and transient notes outside the repo.
```

That prompt is intentionally install-or-upgrade. The agent should classify the
project as installed, partial, or missing:

- installed: run `operator-sync.sh` to refresh scripts/templates and keep config/state.
- partial: repair from the kit source without overwriting `operator.config.env` or `OPERATOR_DIR`.
- missing: run `operator-sync.sh --bootstrap-if-missing`, then write the requested lane map.

For the full Cursor prompt, use:

```text
templates/prompts/cursor-agent-bootstrap.md
```

After installation, Cursor uses:

```text
.cursor/rules/operator-workflow.mdc
.cursor/skills/operator-workflow/SKILL.md
.cursor/skills/operator/SKILL.md
.cursor/skills/operator-planner/SKILL.md
.cursor/skills/operator-feedback/SKILL.md
.cursor/skills/design-agent/SKILL.md
.cursor/skills/ux-auditor/SKILL.md
.cursor/skills/user-journey/SKILL.md
.cursor/skills/incubation/SKILL.md
```

Invoke the Cursor skills explicitly:

```text
Use the operator skill. Execute the approved backend task.
Use the operator-planner skill. Prioritize the feedback inbox.
Use the operator-feedback skill. Capture these testing notes.
Use the design-agent skill with operator. Shape a UI lane task.
Use the UX Auditor skill. Score this product flow.
Use the user-journey skill. Map this first-value journey.
Use the incubation skill. Frame this idea and capture the next experiment.
```

To keep Operator Kit as the default in Cursor, tell the agent:

```text
Always use the operator skill for this project unless I explicitly ask for feedback, planning, design, UX audit, journey mapping, setup, or non-operator work.
```

Cursor Cloud Agents, formerly Background Agents, should be treated as remote
branch workers. Put the full task packet in the Cloud Agent prompt and require
the final response or PR description to include the handoff.

For Cursor-first environments without Codex, bootstrap with the Cursor profile:

```bash
bash /path/to/operator-kit/scripts/operator-sync.sh --target /path/to/repo --bootstrap-if-missing --bootstrap-profile cursor --skip-skills
```

This generates a default lane map with Cursor IDE as the operator, Cursor CLI as
the local worker lane, and Claude Code as the UI lane when available. Review
`operator.config.env` before starting workers; some machines expose the local
agent command as `cursor agent`, while others provide `cursor-agent`.

## What The Agent Should Return

The setup agent should finish with:

- installed files
- `OPERATOR_DIR`
- lane map
- memory status
- tmux session name
- smoke task path
- validation results
- repo `git status`
- whether the repo is ready to commit

It should not make deployments, production builds, provider-console changes, force-pushes, or destructive git operations during setup.
