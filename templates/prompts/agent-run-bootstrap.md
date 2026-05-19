# Agent-Run Bootstrap Prompt

Set up Agent Operator Kit for this project.

Source kit:

```text
git@github.com:Agent-Operator-Kit/operator-kit.git
```

Target project:

```text
<absolute path to the project repo>
```

Goals:

- Use git worktrees for isolated agent lanes.
- Use tmux for persistent Codex/Claude worker lanes.
- Keep task packets, handoffs, captures, task working files, and transient operator notes outside the repo.
- Install Operator Memory Router for compact project, task, and lane episode context.
- Keep only reusable scripts and evergreen docs inside the repo.
- Generate or update `AGENTS.md`, `CODEX.md`, `CLAUDE.md`, and `operator.config.env` as needed.
- If Codex Desktop is relevant, explain how to install bundled global skills with `scripts/codex-skills-install.sh`; do not write to `~/.codex` unless I explicitly ask.
- Install Claude Code project assets when using Claude Code:
  - `.claude/commands/operator-bootstrap.md`
  - `.claude/commands/operator-status.md`
  - `.claude/agents/operator-workflow.md`
- Install Cursor project assets when using Cursor:
  - `.cursor/rules/operator-workflow.mdc`
  - `.cursor/skills/operator-workflow/SKILL.md`
  - `.cursor/environment.json.example`
- Create the external operator workspace beside the project root unless I specify another path.

Required behavior:

1. Inspect the repo first: git status, default branch, remotes, package manager, validation commands, and current docs.
2. Propose a lane map before creating worktrees.
3. Use conservative defaults:
   - `operator`: current repo worktree on the stable branch
   - `backend`: Codex CLI on `codex/backend`
   - `ui`: Claude Code on `claude/ui`
   - `release`: Codex CLI only if the project has release work
   - `product`: Codex CLI only if product or research work is useful
4. After approval, or if the lane map is obvious, clone/install the kit and run its bootstrap script.
5. Edit `operator.config.env` so paths, branches, lane owners, and agent invocations match this project.
6. Create missing lane worktrees from the stable branch, but do not overwrite existing worktrees.
7. Start the tmux session.
8. Create a smoke task under the external operator workspace.
9. Dispatch with `--no-enter` to one lane if safe, then collect a smoke handoff.
10. Run script checks:
    - `bash -n scripts/*.sh`
    - `bash scripts/operator-status.sh`
    - `bash scripts/operator-summary.sh`
    - `bash scripts/operator-memory.sh status`
11. Confirm generated task, handoff, and memory files landed under `OPERATOR_DIR`, not inside the repo.
12. Confirm `scripts/operator-memory.sh`, `scripts/operator-update.sh`, `scripts/operator-sync.sh`, and `scripts/operator-upgrade.sh` are installed for future safe refreshes.
13. Confirm `AGENTS.md` points Codex users to the global `$operator` skill when available.
14. Show git status and list intended repo changes.

Guardrails:

- Do not rewrite git history.
- Do not force-push.
- Do not commit secrets, raw handoffs, task packets, pane captures, task working files, memory packs, or transient notes.
- Do not let two agents share the same branch.
- Do not let two agents edit the same file at the same time.
- Ask before starting destructive commands, deployments, production builds, or provider-console changes.

Final response:

- Summarize installed files.
- Show `OPERATOR_DIR`.
- Show lane map.
- Show smoke-test results.
- Show Codex Desktop `$operator` skill install instructions when relevant.
- Show remaining manual steps, if any.
- Say whether the repo is ready to commit.
