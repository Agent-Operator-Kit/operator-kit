# Bootstrap Existing Project Prompt

Set up Agent Operator Kit for this existing project.

Goals:

- Use git worktrees for isolated agent lanes.
- Use tmux for long-running Codex and Claude workers.
- Keep task packets, handoffs, captures, task working files, and transient operator notes outside the repo.
- Keep only reusable scripts and evergreen docs inside the repo.
- Generate or update `AGENTS.md`.
- If Codex Desktop is relevant, explain the global `$operator` runtime skill install.
- Create an external operator workspace beside the project unless I specify another path.

Start by inspecting the repo, detecting the default branch and validation commands, then propose a lane map before making broad changes.

For a complete agent-run setup prompt, use `templates/prompts/agent-run-bootstrap.md`.
