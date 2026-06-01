# Agent-Run Install Or Initialize Prompt

Install, initialize, or upgrade Agent Operator Kit for this project.

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
- Initialize the local Operator roadmap and feedback workspace.
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
  - `.cursor/skills/operator/SKILL.md`
  - `.cursor/skills/operator-planner/SKILL.md`
  - `.cursor/skills/operator-feedback/SKILL.md`
  - `.cursor/skills/design-agent/SKILL.md`
  - `.cursor/skills/ux-auditor/SKILL.md`
  - `.cursor/skills/user-journey/SKILL.md`
  - `.cursor/skills/incubation/SKILL.md`
  - `.cursor/environment.json.example`
- Create the external operator workspace beside the project root unless I specify another path.

Lane requirements:

```text
<describe the lanes this project needs. If omitted, infer a conservative lane
map from the repo and ask before creating worktrees.>
```

Required behavior:

1. Inspect the repo first: git status, default branch, remotes, package manager, validation commands, and current docs.
2. Detect install state:
   - installed: `operator.config.env` exists and `scripts/operator-status.sh` runs;
   - partial: some Operator Kit files exist but required scripts/config are missing or status fails;
   - missing: no reliable Operator Kit files exist.
3. If installed, run an upgrade/refresh with `scripts/operator-sync.sh` from the installed project or source kit; do not re-bootstrap.
4. If partial, repair by syncing from the source kit while preserving existing `operator.config.env`, `OPERATOR_DIR`, handoffs, tasks, memory, roadmap, docs, and source code.
5. If missing, run `operator-sync.sh --bootstrap-if-missing` from the source kit or remote entry point.
6. Propose a lane map before creating worktrees unless the user already supplied explicit lane requirements.
7. Use conservative defaults:
   - `operator`: current repo worktree on the stable branch
   - `backend`: Codex CLI on `codex/backend`
   - `ui`: Claude Code on `claude/ui`
   - `release`: Codex CLI only if the project has release work
   - `product`: Codex CLI only if product or research work is useful
   - for Cursor-first environments without Codex, use `--profile cursor` and prefer Cursor IDE as operator, Cursor CLI as a local worker, and Claude Code as an optional UI lane
8. In V2, refresh the system map and lane recommendation:
   - `bash scripts/operator-system-map.sh refresh`
   - `bash scripts/operator-recommend-lanes.sh`
   - use this output to refine the lane map; do not create every role as a permanent lane
9. After install/update, edit `operator.config.env` so paths, branches, lane owners, and agent invocations match this project.
10. Create missing lane worktrees from the stable branch, but do not overwrite existing worktrees.
11. Start the tmux session.
12. Create a smoke task under the external operator workspace.
13. Dispatch with `--no-enter` to one lane if safe, then collect a smoke handoff.
14. Run script checks:
    - `bash -n scripts/*.sh`
    - `bash scripts/operator-status.sh`
    - `bash scripts/operator-summary.sh`
    - `bash scripts/operator-memory.sh status`
    - `bash scripts/operator-roadmap.sh status`
    - `bash scripts/operator-catalog.sh list roles`
    - `bash scripts/operator-plan-batch.sh`
15. Confirm generated task, handoff, and memory files landed under `OPERATOR_DIR`, not inside the repo.
16. Confirm `scripts/operator-memory.sh`, `scripts/operator-roadmap.sh`, `scripts/operator-feedback.sh`, `scripts/operator-catalog.sh`, `scripts/operator-system-map.sh`, `scripts/operator-recommend-lanes.sh`, `scripts/operator-plan-batch.sh`, `scripts/operator-update.sh`, `scripts/operator-sync.sh`, and `scripts/operator-upgrade.sh` are installed for future safe refreshes.
17. Confirm `AGENTS.md` points Codex users to the global `$operator` skill when available.
18. Show git status and list intended repo changes.

If starting from only the GitHub URL, clone the kit or use the remote entry
point, then run:

```bash
bash scripts/operator-sync.sh --target /path/to/repo --bootstrap-if-missing
```

or, when remote shell execution is allowed:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-sync.sh) --target /path/to/repo --bootstrap-if-missing
```

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
