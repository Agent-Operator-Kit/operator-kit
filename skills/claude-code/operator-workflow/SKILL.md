# Claude Code Operator Workflow Skill

Claude Code does not need a Codex-style skill loader to use Agent Operator Kit. Its reusable project-level mechanisms are:

- custom slash commands in `.claude/commands/`
- project subagents in `.claude/agents/`

This skill package describes how to install and use the Claude Code assets shipped with Agent Operator Kit.

## Install Into A Target Repo

Run the Agent Operator Kit bootstrap, or copy these templates into the target repo:

```text
templates/claude/commands/operator-bootstrap.md -> .claude/commands/operator-bootstrap.md
templates/claude/commands/operator-status.md -> .claude/commands/operator-status.md
templates/claude/agents/operator-workflow.md -> .claude/agents/operator-workflow.md
```

## Use In Claude Code

After installation, invoke:

```text
/operator-bootstrap /absolute/path/to/repo
```

or:

```text
/operator-status
```

You can also ask:

```text
Use the operator-workflow subagent to set up Agent Operator Kit for this repo.
```

## Sticky Operator Mode

Claude Code can expose sticky Operator behavior through slash commands,
subagents, and project instructions. Sticky mode means default routing, not
automatic execution:

```text
operator off       # normal Claude Code behavior
operator observe   # status, summaries, memory/roadmap reads, feedback/planning summaries
operator active    # observe plus feedback intake, planning, and task-packet creation
operator dispatch  # execution allowed only when the user clearly asks and preflight passes
```

Use `operator observe` as the safest default after setup. Natural phrases such
as `status`, `what is blocked?`, and `summarize lanes` may route through
Operator when exactly one Operator config is bound. Dispatch, collection,
source integration, push, tag, release, destructive cleanup, provider changes,
and credential changes still require explicit intent, a clear target, preflight,
and review.

## Workflow

1. Inspect the repo and git status.
2. Identify default branch, remotes, package manager, and validation commands.
3. Propose a lane map.
4. Install scripts/templates, including `scripts/operator-memory.sh`, `scripts/operator-roadmap.sh`, and `scripts/operator-feedback.sh`.
5. Create the external operator workspace, memory folders, and local roadmap/feedback workspace.
6. Create or verify worktrees.
7. Start tmux.
8. Create a smoke task.
9. Run status, summary, memory status, and roadmap status checks.
10. Report whether the repo is ready to commit.

## Memory

Use `scripts/operator-memory.sh` for cross-lane context that should survive
Claude Code compaction. Dispatch with `--with-memory` when a lane needs
retrieved project, task, or episode context. Promote only concise facts; raw
handoffs and captures remain evidence under `OPERATOR_DIR`.

## Roadmap And Feedback

Use `scripts/operator-roadmap.sh` and `scripts/operator-feedback.sh` for local
roadmap, backlog, feedback intake, screenshot/video annotations, and planning
views. Keep this state under `OPERATOR_DIR`, not in the app repo.

In Codex Desktop, the matching explicit modes are `$operator-feedback` for
intake, `$operator-planner` for planning, and `$operator` for execution.

## Operating Feature Tracks

Once the user authorizes a feature track, keep dispatching necessary follow-up
tasks to the appropriate lanes until the feature is completed, integrated,
validated, or blocked. Do not ask the user to approve every obvious
handoff-to-handoff transition.

Pause for user input before destructive cleanup, credential changes,
provider-console changes, production deploys, release submissions,
regulated, financial, or safety-critical behavior, or product decisions that
cannot be safely inferred.

## Guardrails

- Do not rewrite git history.
- Do not force-push.
- Do not commit raw task packets, handoffs, pane captures, task working files, or transient notes.
- Do not commit memory packs or generated operator memory.
- Do not commit secrets.
- Do not start deployments or production builds during setup.
