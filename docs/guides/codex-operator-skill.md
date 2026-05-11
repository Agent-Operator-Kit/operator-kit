# Codex Operator Skill

Use the Codex Desktop `$operator` skill after Agent Operator Kit is installed in a promoted project.

The setup skill and the runtime skill have different jobs:

```text
operator-workflow -> setup, bootstrap, repair
operator          -> daily operation in an installed project
```

## Install Globally

From this kit repo:

```bash
bash scripts/codex-skills-install.sh
```

This installs or refreshes every bundled Codex Desktop skill under `skills/codex/`, including `$operator`, `operator-workflow`, `$design-agent`, and `$incubation`.

To fast-forward the kit source first, then refresh skills:

```bash
bash scripts/codex-skills-install.sh --latest
```

Restart or reopen Codex Desktop so the skill list refreshes.

Codex skills are not background daemons. Invoke the skill explicitly with `$operator`, or use language that clearly refers to Operator Kit lanes, task packets, dispatch, collection, or handoffs.

## Optional Design Agent Companion

Install `$design-agent` when you want Codex Desktop to help with UX consistency reviews, code-first design-system extraction, curated starter recommendation, web annotation feedback classification, and preparing design/UI task packets for Claude Code or Operator Kit lanes.

From this kit repo:

```bash
bash scripts/codex-skills-install.sh --skill design-agent
```

Use the skills together:

```text
Use $design-agent with $operator. Do a comprehensive UX and consistency review of this project.
Use $design-agent with $operator. Extract a design system and prepare a UI lane task.
Use $design-agent with $operator. Package my annotations into a design follow-up task.
```

Role split:

```text
$design-agent -> UX/design-system reasoning and task content
$operator     -> lane safety, dispatch, collection, integration review
```

## Optional Incubation Companion

Install `$incubation` when you want Codex Desktop to manage product ideas before they become Operator Kit projects.

From this kit repo:

```bash
bash scripts/codex-skills-install.sh --skill incubation
```

Use the skills together:

```text
Use $incubation. Frame this idea and capture the next experiment.
Use $incubation. Review promotion readiness for this idea.
Use $incubation with $operator. Prepare this idea for promotion into an Operator Kit project.
Use $incubation with $design-agent. Turn this thesis into design-system starting assumptions.
```

Role split:

```text
$incubation  -> idea framing, durable idea files, promotion readiness
$operator    -> promoted-project setup, lane safety, dispatch, collection
$design-agent -> UX/design-system reasoning and task content
```

Do not initialize Agent Operator Kit inside `/Users/norbert/Incubation`; initialize it only after promotion into `/Users/norbert/Projects/<product-slug>/code/app`.

## Detection

The skill detects an Operator Kit project by walking upward from the current directory and checking for:

```text
operator.config.env
scripts/operator-status.sh
scripts/operator-tmux.sh
scripts/operator-task.sh
scripts/operator-dispatch.sh
scripts/operator-collect.sh
scripts/operator-summary.sh
```

If Codex starts inside a worker lane such as `code/app-backend`, the skill should also check sibling worktrees by walking upward and looking for immediate child directories with `operator.config.env`. If multiple candidate configs are found, it should ask which project root to operate.

It then reads `operator.config.env`, reads `AGENTS.md` if present, and runs:

```bash
bash scripts/operator-status.sh
bash scripts/operator-summary.sh
```

## User Experience

Installed project:

```text
Use $operator. Show project status.
```

Codex should report the project, `OPERATOR_DIR`, lane map, branch health, dirty worktrees, tmux windows, latest handoffs, blockers, and safe next moves.

Partial install:

```text
Use $operator. Show status.
```

Codex should list what it found and what is missing, then avoid dispatching or collecting until the install is repaired.

Not installed:

```text
Use $operator. Show status.
```

Codex should say Operator Kit is not installed from the current directory and offer to inspect the repo, propose a lane map, install the kit, or switch to another project path.

## Examples

```text
Use $operator. Start tmux lanes.
Use $operator. Summarize blockers across all lanes.
Use $operator. Create a backend task for auth scaffolding.
Use $operator. Dispatch the auth task to backend with --no-enter.
Use $operator. Collect backend result for auth-001 and tell me if it is ready to integrate.
Use $operator. Review the ui lane diff and recommend whether to merge.
Use $operator. Update to latest version from git.
```

## Updating Operator Kit

Use this when a project already has Operator Kit installed but may be behind the latest kit source:

```text
Use $operator. Update to latest version from git.
```

Codex should:

1. Detect the installed project.
2. Pull the latest local kit source when it is clean, or clone/fetch the public source.
3. Refresh bundled Codex Desktop skills with `scripts/codex-skills-install.sh`.
4. Run `scripts/operator-update.sh` against the project.
5. Run syntax, status, summary, and git status checks.
6. Summarize updated files, installed missing files, preserved project-specific files, validation results, and follow-up.

The update must preserve:

- `operator.config.env`
- existing `AGENTS.md`, `CODEX.md`, and `CLAUDE.md`
- existing `.claude/*` and `.cursor/*`
- task packets, handoffs, captures, and transient operator state
- application source code

The update refreshes evergreen scripts and installs missing templates only.

## Operating Rules

- Prefer `scripts/operator-*.sh` over raw tmux commands.
- Keep task packets, captures, handoffs, and transient notes under `OPERATOR_DIR`.
- Check git status before dispatch, collection, or integration.
- Do not let two lanes share a branch.
- Do not let two lanes edit the same files at the same time.
- Do not merge worker branches into the stable branch without operator review.
- Do not commit raw handoffs, task packets, pane captures, or secrets.
