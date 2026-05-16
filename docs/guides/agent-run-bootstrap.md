# Agent-Run Bootstrap

Use this guide when you want Codex, Claude Code, or another coding agent to install Agent Operator Kit into a project for you.

The agent should do the setup, but it should still move deliberately:

1. inspect the target repo
2. explain the inferred project layout
3. propose the lane map
4. install the kit
5. verify the scripts and external workspace
6. report the exact status
7. commit only after setup is validated and approved, unless the user explicitly asks it to commit

## Prompt

Copy this into the agent session from the target project or from the parent folder that contains the target project.

```text
Set up Agent Operator Kit for this project.

Source kit:
git@github.com:Agent-Operator-Kit/operator-kit.git

Target project:
<absolute path to the project repo>

Goals:
- Use git worktrees for isolated agent lanes.
- Use tmux for persistent Codex/Claude worker lanes.
- Keep task packets, handoffs, captures, and transient operator notes outside the repo.
- Install Operator Memory Router for compact project, task, and lane episode context.
- Keep only reusable scripts and evergreen docs inside the repo.
- Generate or update AGENTS.md, CODEX.md, CLAUDE.md, and operator.config.env as needed.
- If Codex Desktop is relevant, explain how to install bundled global skills with scripts/codex-skills-install.sh; do not write to ~/.codex unless I explicitly ask.
- Install Claude Code project assets when using Claude Code:
  - .claude/commands/operator-bootstrap.md
  - .claude/commands/operator-status.md
  - .claude/agents/operator-workflow.md
- Install Cursor project assets when using Cursor:
  - .cursor/rules/operator-workflow.mdc
  - .cursor/skills/operator-workflow/SKILL.md
  - .cursor/environment.json.example
- Create the external operator workspace beside the project root unless I specify another path.

Required behavior:
1. Inspect the repo first: git status, default branch, remotes, package manager, validation commands, and current docs.
2. Propose a lane map before creating worktrees. Use conservative defaults:
   - operator: current repo worktree on the stable branch
   - backend: Codex CLI on codex/backend
   - ui: Claude Code on claude/ui
   - release: Codex CLI on staging or codex/release only if the project has release work
   - product: Codex CLI on codex/product only if product/research work is useful
3. After I approve or if the lane map is obvious, clone/install the kit if needed and run its bootstrap script.
4. Edit operator.config.env so paths, branches, lane owners, and agent invocations match this project.
5. Create missing lane worktrees from the stable branch, but do not overwrite existing worktrees.
6. Start the tmux session.
7. Create a smoke task under the external operator workspace.
8. Dispatch with --no-enter to one lane if safe, then collect a smoke handoff.
9. Run script checks:
   - bash -n scripts/*.sh
   - bash scripts/operator-status.sh
   - bash scripts/operator-summary.sh
   - bash scripts/operator-memory.sh status
10. Confirm generated task, handoff, and memory files landed under OPERATOR_DIR, not inside the repo.
11. Confirm scripts/operator-memory.sh, scripts/operator-update.sh, and scripts/operator-sync.sh are installed for future safe refreshes.
12. Confirm AGENTS.md points Codex users to the global $operator skill when available.
13. Show git status and list intended repo changes.

Guardrails:
- Do not rewrite git history.
- Do not force-push.
- Do not commit secrets, raw handoffs, task packets, pane captures, memory packs, or transient notes.
- Do not let two agents share the same branch.
- Do not let two agents edit the same file at the same time.
- Ask before starting destructive commands, deployments, production builds, or provider-console changes.

Final response:
- Summarize installed files.
- Show OPERATOR_DIR.
- Show lane map.
- Show smoke-test results.
- Show Codex Desktop $operator skill install instructions when relevant.
- Show remaining manual steps, if any.
- Say whether the repo is ready to commit.
```

## Expected Agent Actions

The agent should normally run:

```bash
git clone git@github.com:Agent-Operator-Kit/operator-kit.git /tmp/operator-kit
bash /tmp/operator-kit/scripts/operator-bootstrap.sh /path/to/project
cd /path/to/project
bash -n scripts/*.sh
bash scripts/operator-status.sh
bash scripts/operator-task.sh setup-smoke-001 "Setup smoke"
bash scripts/operator-memory.sh status
bash scripts/operator-tmux.sh start
bash scripts/operator-summary.sh
```

If worktrees are part of the approved lane map, the agent should create them with commands like:

```bash
git worktree add ../app-backend -b codex/backend main
git worktree add ../app-ui -b claude/ui main
```

The exact names should come from `operator.config.env`.

## Success Criteria

- `operator.config.env` matches the target project.
- `scripts/operator-*.sh` are installed in the repo.
- `scripts/operator-memory.sh status` works.
- `AGENTS.md` documents the operating model.
- Claude Code command/subagent templates are installed under `.claude/` when relevant.
- Cursor rules, skill, and environment example are installed under `.cursor/` when relevant.
- `OPERATOR_DIR` exists outside the repo.
- smoke task output appears under `OPERATOR_DIR/tasks/<slug>`.
- no raw task packets or handoffs are tracked by git.
- `bash scripts/operator-status.sh` works.
