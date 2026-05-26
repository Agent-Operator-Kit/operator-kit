# Cursor Agent Install Or Initialize Prompt

Install, initialize, or upgrade Agent Operator Kit for this project using Cursor.

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
- Cursor Cloud Agents, formerly Background Agents, only for isolated remote branch tasks
- Codex is optional; if Codex is unavailable, use the Cursor bootstrap profile and make Cursor CLI / Claude Code the local worker lanes

Lane requirements:

```text
<describe the lanes this project needs, for example:
operator: Cursor IDE on the stable branch
web: web app lane
agents-api: optional lane for agent/API integration work>
```

Required setup:

1. Inspect the repo first: git status, default branch, remotes, package manager, validation commands, and current docs.
2. Detect install state:
   - installed: `operator.config.env` exists and `scripts/operator-status.sh` runs;
   - partial: some Operator Kit files exist but required scripts/config are missing or status fails;
   - missing: no reliable Operator Kit files exist.
3. If installed, upgrade/refresh from the source kit with `scripts/operator-sync.sh` or the source kit's `scripts/operator-sync.sh`; do not re-bootstrap.
4. If partial, repair by syncing from the source kit; preserve existing `operator.config.env`, `OPERATOR_DIR`, task packets, handoffs, memory, roadmap, and source code.
5. If missing, install with `operator-sync.sh --bootstrap-if-missing --bootstrap-profile cursor --skip-skills`.
6. Convert the lane requirements above into `operator.config.env`. If the user already specified lanes, write them after install/update; otherwise propose the lane map before creating worktrees.
7. Install Cursor project assets:
   - `.cursor/rules/operator-workflow.mdc`
   - `.cursor/skills/operator-workflow/SKILL.md`
   - `.cursor/skills/operator/SKILL.md`
   - `.cursor/skills/operator-planner/SKILL.md`
   - `.cursor/skills/operator-feedback/SKILL.md`
   - `.cursor/skills/design-agent/SKILL.md`
   - `.cursor/environment.json.example`
8. Create missing lane worktrees from the stable branch, but do not overwrite existing worktrees.
9. Start or inspect tmux.
10. Create a smoke task under the external operator workspace.
11. Run:
   - `bash -n scripts/*.sh`
   - `bash scripts/operator-status.sh`
   - `bash scripts/operator-summary.sh`
   - `bash scripts/operator-memory.sh status`
12. Confirm generated task, handoff, and memory files landed under `OPERATOR_DIR`, not inside the repo.

Cursor-first lane defaults when Codex is unavailable:

```text
operator|Cursor IDE|app|main|
cursor|Cursor CLI|app-cursor|cursor/operator|cursor agent
ui|Claude Code|app-ui|claude/ui|claude --dangerously-skip-permissions --permission-mode bypassPermissions
```

Use:

```bash
bash scripts/operator-bootstrap.sh --profile cursor /path/to/repo
```

or:

```bash
bash scripts/operator-sync.sh --target /path/to/repo --bootstrap-if-missing --bootstrap-profile cursor --skip-skills
```

When starting from only the GitHub URL, first clone or otherwise obtain the kit
source, then run its `scripts/operator-sync.sh` against the target repo. If a
remote shell entry point is allowed, this is also acceptable:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-sync.sh) --target /path/to/repo --bootstrap-if-missing --bootstrap-profile cursor --skip-skills
```

Example Cursor lane map for a web app plus agent/API work:

```text
OPERATOR_LANES='
operator|Cursor IDE|app|main|
web|Cursor CLI|app-web|cursor/web|cursor agent
agents-api|Cursor CLI|app-agents-api|cursor/agents-api|cursor agent
'
```

If the local machine exposes Cursor Agent as `cursor-agent` instead of `cursor
agent`, update the lane invocation accordingly. Select GPT-5.5 through Cursor's
configured model picker or company policy; do not invent unsupported CLI model
flags.

Cursor Cloud Agent policy:

- Treat Cloud Agents as remote branch workers, not local tmux lanes.
- Put full task packets and relevant memory context in their prompt because they may not have local operator state.
- Require a final handoff in the response, branch commits, or pull request description.
- Do not use Cloud Agents for deploys, provider consoles, local simulators, or local-device validation unless the environment is explicitly configured.

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
