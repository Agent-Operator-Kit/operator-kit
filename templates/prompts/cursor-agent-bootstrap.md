# Cursor Agent Bootstrap Prompt

Set up Agent Operator Kit for this project using Cursor.

Source kit:

```text
git@github.com:Agent-Operator-Kit/operator-kit.git
```

Target project:

```text
<absolute path to the project repo>
```

Use Cursor as the frontend operator surface. Keep the standard Agent Operator Kit model:

- local worktrees for local agents
- tmux for persistent local lanes
- `OPERATOR_DIR` outside the repo for local task packets, handoffs, and task working files
- Operator Memory Router for compact local project, task, and episode context
- Cursor rules/skills for persistent Cursor guidance
- Cursor Background Agents only for isolated remote branch tasks

Required setup:

1. Inspect the repo first: git status, default branch, remotes, package manager, validation commands, and current docs.
2. Propose a lane map before creating worktrees.
3. Install Agent Operator Kit scripts and templates.
4. Install Cursor project assets:
   - `.cursor/rules/operator-workflow.mdc`
   - `.cursor/skills/operator-workflow/SKILL.md`
   - `.cursor/environment.json.example`
5. Edit `operator.config.env` so paths, branches, lane owners, and agent invocations match this project.
6. Create missing lane worktrees from the stable branch, but do not overwrite existing worktrees.
7. Start or inspect tmux.
8. Create a smoke task under the external operator workspace.
9. Run:
   - `bash -n scripts/*.sh`
   - `bash scripts/operator-status.sh`
   - `bash scripts/operator-summary.sh`
   - `bash scripts/operator-memory.sh status`
10. Confirm generated task, handoff, and memory files landed under `OPERATOR_DIR`, not inside the repo.

Cursor Background Agent policy:

- Treat Background Agents as remote branch workers, not local tmux lanes.
- Put full task packets and relevant memory context in their prompt because they may not have local operator state.
- Require a final handoff in the response, branch commits, or pull request description.
- Do not use Background Agents for deploys, provider consoles, local simulators, or local-device validation unless the environment is explicitly configured.

Guardrails:

- Do not rewrite git history.
- Do not force-push.
- Do not commit secrets, raw handoffs, task packets, pane captures, task working files, memory packs, or transient notes.
- Do not let two agents share the same branch.
- Do not let two agents edit the same file at the same time.
- Ask before destructive commands, deployments, production builds, or provider-console changes.

Final response:

- Summarize installed files.
- Show `OPERATOR_DIR`.
- Show lane map.
- Show Cursor assets installed.
- Show smoke-test results.
- Show remaining manual steps, if any.
- Say whether the repo is ready to commit.
