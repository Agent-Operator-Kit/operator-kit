# Bootstrap New Project Prompt

Create a new project and set up Agent Operator Kit from the beginning.

Goals:

- Initialize git.
- Suggest and use the scoped project layout:
  - `<project-root>/code/app` for the canonical repo worktree.
  - `<project-root>/code/<lane-worktree>` for permanent agent lanes.
  - `<project-root>/operator` for tasks, handoffs, memory, roadmap, and catalog.
- Ensure Operator Kit can be used when the chat is opened at `<project-root>` by
  resolving `code/*/operator.config.env`.
- Create a stable branch.
- Add reusable operator scripts and docs.
- Create an external operator workspace.
- Define initial lanes.
- Start tmux.
- Create a smoke task.
- If Codex Desktop is relevant, explain the global `$operator` runtime skill install.

Do not commit generated task packets, handoffs, task working files, or memory packs.
