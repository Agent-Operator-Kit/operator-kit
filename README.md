# Agent Operator Kit

Agent Operator Kit is a lightweight operating model for coordinating coding agents across isolated git worktrees using tmux, external task handoffs, task working files, and an operator-owned integration flow.

It is designed for teams or solo builders who want Codex, Claude Code, and similar agents to work in parallel without polluting the codebase with transient task packets, raw handoffs, pane captures, mockups, screenshots, or session notes.

Website:

```text
https://agent-operator-kit.github.io/operator-kit/
```

## Core Idea

- One human or primary agent acts as the operator and integrator.
- Worker agents run in named lanes such as `backend`, `ui`, `release`, or `product`.
- Each lane has its own git worktree and branch.
- tmux keeps long-running agents visible and recoverable.
- Task packets, handoffs, and temporary working files live outside the repo in an operator workspace.
- Local roadmap, backlog, feedback, and prioritization live outside the repo under `OPERATOR_DIR/roadmap`.
- The repo keeps evergreen docs, reusable scripts, source code, and lightweight PR/commit trace references.

## Layout

Recommended project layout:

```text
~/Projects/acme/
  code/
    app/              # canonical repo worktree
    app-backend/      # optional worker worktree
    app-ui/           # optional worker worktree
  operator/
    README.md
    roadmap/
      items/*.md
      inbox/
      views/*.md
    tasks/
      <slug>/
        00-operator-brief.md
        memory.md
        tasks/*.md
        handoffs/*.md
        work/
          README.md
          feedback/
            captures/
            annotations.json
          *.html
          images/
    captures/
    memory/
      project.md
      episodes/*.md
      packs/
```

Recommended repo layout after installation:

```text
.cursor/
  rules/
    operator-workflow.mdc
  skills/
    operator-workflow/
      SKILL.md
  environment.json.example
.claude/
  commands/
    operator-bootstrap.md
    operator-status.md
  agents/
    operator-workflow.md
scripts/
  operator-lib.sh
  operator-tmux.sh
  operator-status.sh
  operator-task.sh
  operator-dispatch.sh
  operator-collect.sh
  operator-summary.sh
  operator-memory.sh
  operator-roadmap.sh
  operator-feedback.sh
  operator-update.sh
  operator-sync.sh
  operator-upgrade.sh

AGENTS.md
operator.config.env
```

## AI-Agent Setup

The intended setup path is to let an AI agent install the kit. You give Codex,
Claude Code, Cursor, or another coding agent the target repo and the source kit;
the agent inspects the project, proposes lanes, installs scripts/templates,
creates the external operator workspace, runs smoke checks, and reports what is
ready to commit.

Use this when you are inside the target project repo:

```text
Set up Agent Operator Kit for the current repo.

Use this source kit:
git@github.com:Agent-Operator-Kit/operator-kit.git

First clone or read the kit, then follow its agent-run bootstrap guide:
templates/prompts/agent-run-bootstrap.md
docs/guides/agent-run-bootstrap.md

Treat the current working directory as the target project repo.
```

The agent should:

- inspect git status, default branch, remotes, stack, docs, and validation commands first
- propose the lane map before creating worktrees
- install reusable scripts, repo docs, Codex skills, Claude Code assets, and Cursor assets when relevant
- keep task packets, handoffs, captures, memory, and task working files under `OPERATOR_DIR`
- run `bash -n scripts/*.sh`, status, summary, memory, and smoke checks
- report installed files, `OPERATOR_DIR`, lane map, memory status, smoke results, git status, and whether the repo is ready to commit

The full prompt is maintained here:

```text
templates/prompts/agent-run-bootstrap.md
```

## Getting Started

Agent Operator Kit is optimized for agent-run setup. Open Codex, Claude Code, or Cursor in the target repo and paste:

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

Full copy/paste prompt:

```text
templates/prompts/agent-run-bootstrap.md
```

Cursor agent install/init prompt:

```text
Install or initialize Agent Operator Kit for this project from:
https://github.com/Agent-Operator-Kit/operator-kit.git

Use Cursor as the operator cockpit. Detect whether Operator Kit is already
installed. If it is installed, upgrade/refresh it. If it is missing, install it
with the Cursor bootstrap profile. Configure these lanes:
- operator: Cursor IDE on the stable branch
- web: web app lane
- agents-api: optional lane for agent/API integration work

Always use the operator skill for this project unless I explicitly ask for
feedback, planning, design, UX audit, journey mapping, setup, or non-operator work.
```

The agent should inspect first, classify the project as installed, partial, or
missing, then run `operator-sync.sh` to refresh or install. If the user supplies
lane requirements in the prompt, the agent should write `operator.config.env`
for that lane map instead of leaving the default profile untouched.

Getting started guide:

```text
docs/guides/getting-started-with-agents.md
```

Full bootstrap guide:

```text
docs/guides/agent-run-bootstrap.md
```

Cursor operator guide:

```text
docs/guides/cursor-operator-workflow.md
```

GitHub Pages guide:

```text
docs/guides/github-pages.md
```

Codex-specific reusable guidance:

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

Companion skill guides:

```text
docs/guides/design-agent-collaboration.md
docs/guides/incubation-collaboration.md
docs/concepts/operator-memory.md
docs/concepts/operator-roadmap.md
```

Install or refresh every bundled Codex Desktop skill from this kit:

```bash
bash scripts/codex-skills-install.sh
bash scripts/codex-skills-install.sh --latest
```

Use `skills/codex/operator/SKILL.md` as the global Codex Desktop `$operator` skill for execution in installed projects. Use `skills/codex/operator-workflow/SKILL.md` for setup, repair, and bootstrap guidance.

Use `skills/codex/operator-feedback/SKILL.md` for feedback intake and `skills/codex/operator-planner/SKILL.md` for roadmap/backlog planning.

Use `skills/codex/design-agent/SKILL.md` as the optional global Codex Desktop `$design-agent` companion skill for UX consistency reviews, code-first design-system extraction, starter recommendation, annotation feedback classification, and preparing Claude Code or Operator Kit design/UI tasks.

Use `skills/codex/ux-auditor/SKILL.md` as the optional global Codex Desktop UX Auditor (`$ux-auditor`) companion skill for scored UX audits, persona/ICP fit assessment, journey risk analysis, and prioritized recommendations.

Use `skills/codex/user-journey/SKILL.md` as the optional global Codex Desktop `$user-journey` companion skill for persona, ICP, journey map, service blueprint, storyboard, Canvas, and HTML journey artifacts.

Use `skills/codex/incubation/SKILL.md` as the optional global Codex Desktop `$incubation` companion skill for product idea framing, durable idea-file capture, promotion readiness, and handoff into promoted Operator Kit projects.

Claude Code reusable assets:

```text
templates/claude/commands/operator-bootstrap.md
templates/claude/commands/operator-status.md
templates/claude/agents/operator-workflow.md
skills/claude-code/operator-workflow/SKILL.md
```

Cursor reusable assets:

```text
templates/cursor/rules/operator-workflow.mdc
templates/cursor/skills/operator-workflow/SKILL.md
templates/cursor/skills/operator/SKILL.md
templates/cursor/skills/operator-planner/SKILL.md
templates/cursor/skills/operator-feedback/SKILL.md
templates/cursor/skills/design-agent/SKILL.md
templates/cursor/skills/incubation/SKILL.md
templates/cursor/skills/ux-auditor/SKILL.md
templates/cursor/skills/user-journey/SKILL.md
templates/cursor/environment.json.example
templates/prompts/cursor-agent-bootstrap.md
skills/cursor/operator-workflow/SKILL.md
skills/cursor/operator/SKILL.md
skills/cursor/operator-planner/SKILL.md
skills/cursor/operator-feedback/SKILL.md
skills/cursor/design-agent/SKILL.md
skills/cursor/incubation/SKILL.md
skills/cursor/ux-auditor/SKILL.md
skills/cursor/user-journey/SKILL.md
docs/guides/cursor-operator-workflow.md
```

Operator Kit is the operating layer: lane map, task packets, worktrees, tmux
sessions, feedback intake, roadmap promotion, memory routing, handoffs, and
integration review. The operator cockpit depends on the available stack:

- With Cursor available, Cursor Composer or Agent is the operator cockpit.
- With Codex Desktop available, Codex `$operator-*` skills can be the cockpit.
- With both, you can mix: Cursor as operator, Codex CLI or Claude Code as
  worker lanes, or vice versa.
- With Claude Code available, Claude can fill UI or scoped implementation
  lanes regardless of which IDE owns the operator.

The bootstrap profiles align with these setups: `--profile default` for a
Codex-led setup, `--profile cursor` for a Cursor-led setup. In every case the
external `OPERATOR_DIR`, scripts, lanes, and memory router stay the same.

For Cursor-first environments without Codex, bootstrap with the Cursor profile:

```bash
bash scripts/operator-sync.sh --target /path/to/your/repo --bootstrap-if-missing --bootstrap-profile cursor --skip-skills
```

This generates a lane map with Cursor IDE as operator, Cursor CLI as a local
worker lane, and Claude Code as an optional UI lane. Review `operator.config.env`
before starting workers.

Use Cursor subagents for temporary specialist work such as review, research,
debugging, and validation. Use Operator Kit lanes for durable worktree, branch,
and process boundaries.

Invoke Cursor modes deliberately:

```text
Use the operator skill. Dispatch the approved backend task.
Use the operator-planner skill. Promote ready feedback into roadmap items.
Use the operator-feedback skill. Capture these testing notes as FB-* intake.
Use the design-agent skill with operator. Shape this UI issue into a lane task.
Use the UX Auditor skill. Score this onboarding flow against the persona and ICP.
Use the user-journey skill. Map the first-value journey.
Use the incubation skill. Frame this idea and capture the next experiment.
```

For a Cursor project/session where execution should default to Operator Kit,
say: "Always use the operator skill for this project unless I explicitly ask
for feedback, planning, design, UX audit, journey mapping, incubation, setup, or non-operator work." Codex Desktop uses
the same convention with `$operator`, `$operator-planner`, `$operator-feedback`,
`$design-agent`, `$ux-auditor`, `$user-journey`, and `$incubation`.

For an existing project:

```bash
git clone git@github.com:Agent-Operator-Kit/operator-kit.git
cd operator-kit
bash scripts/operator-sync.sh --target /path/to/your/repo
```

Or, from inside an existing Operator Kit project, run the remote entry point:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-sync.sh)
```

For a repo that does not have Operator Kit yet, bootstrap intentionally:

```bash
bash scripts/operator-sync.sh --target /path/to/your/repo --bootstrap-if-missing
```

## Configuration

The generated `operator.config.env` file is plain shell configuration so agents can inspect and edit it without extra tooling.

Example:

```bash
PROJECT_NAME="acme"
PROJECT_ROOT="$HOME/Projects/acme"
CODE_DIR="$PROJECT_ROOT/code"
OPERATOR_DIR="$PROJECT_ROOT/operator"
TMUX_SESSION="acme"
DEFAULT_BRANCH="main"

OPERATOR_LANES='
operator|Codex Desktop|app|main|
backend|Codex CLI|app-backend|codex/backend|codex --dangerously-bypass-approvals-and-sandbox
ui|Claude Code|app-ui|claude/ui|claude --dangerously-skip-permissions --permission-mode bypassPermissions
'
```

Lane format:

```text
lane_id|owner|worktree_directory|branch|agent_invocation
```

## Commands

```bash
bash scripts/operator-tmux.sh start
bash scripts/operator-tmux.sh attach
bash scripts/operator-tmux.sh start-workers
bash scripts/operator-status.sh
bash scripts/operator-task.sh <slug> "<title>"
bash scripts/operator-dispatch.sh [--no-enter] [--with-memory] <lane> <task-file>
bash scripts/operator-collect.sh <lane> <slug>
bash scripts/operator-summary.sh
bash scripts/operator-memory.sh status
bash scripts/operator-memory.sh search <query>
bash scripts/operator-memory.sh promote project "<fact>"
bash scripts/operator-memory.sh promote task <slug> "<fact>"
bash scripts/operator-roadmap.sh status
bash scripts/operator-feedback.sh detect
bash scripts/operator-update.sh [--source <kit-repo-or-url>] [--target <repo>]
bash scripts/codex-skills-install.sh [--latest]
bash scripts/operator-sync.sh [--target <repo>]
bash scripts/operator-upgrade.sh [--dry-run] [--projects-root <path>] [--target <repo>]
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-upgrade.sh)
```

## Upgrade Everything

Use the upgrade command when you want one operation to refresh this Codex
Desktop instance and every installed Operator Kit project on the machine:

```bash
bash scripts/operator-upgrade.sh
```

Preview first:

```bash
bash scripts/operator-upgrade.sh --dry-run
```

The command refreshes bundled Codex Desktop skills, scans `~/Projects` for
installed projects by finding `operator.config.env`, updates each project from
the latest kit source, and runs project checks. Use `--target <repo>` to update
one project or `--projects-root <path>` to scan a different folder.

On a machine without a local kit checkout:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-upgrade.sh)
```

In Codex Desktop, the `$operator` skill understands:

```text
$operator --upgrade
$operator /upgrade
```

The upgrade flow preserves project-specific config, source code, handoffs,
task packets, task working files, memory, captures, and existing project docs.

## Operator Memory

Operator memory is a small file-first router for context that should survive lane changes, session compaction, and future handoffs without bloating every prompt.

It uses four layers:

- `AGENTS.md` for evergreen repo operating rules.
- `OPERATOR_DIR/memory/project.md` for durable project facts and decisions.
- `OPERATOR_DIR/tasks/<slug>/memory.md` for feature-track memory shared across lanes working on the same task.
- `OPERATOR_DIR/memory/episodes/*.md` for distilled lane handoffs.

Dispatch remains explicit. Use `--with-memory` when a lane should receive a retrieved context pack:

```bash
bash scripts/operator-dispatch.sh --with-memory backend "$OPERATOR_DIR/tasks/auth-001/tasks/backend.md"
```

Collection automatically writes an episode memory file from the raw pane handoff. Raw captures remain evidence; concise facts should be promoted into project or task memory only when they will help future work.

## Working Files

Every task folder includes `OPERATOR_DIR/tasks/<slug>/work/` for temporary artifacts: exploratory markdown, redesign proposals, HTML prototypes, screenshots, generated images, exported assets, PDFs, and review READMEs.

Keep those files out of the repo by default. Promote an artifact into source, `design-system/`, or evergreen docs only when the operator intentionally decides it should become durable project material.

## Local Roadmap And Feedback

Operator Kit keeps roadmap, backlog, prioritization, and raw feedback outside
the app repo by default:

```text
OPERATOR_DIR/roadmap/items/
OPERATOR_DIR/roadmap/inbox/
OPERATOR_DIR/roadmap/views/
```

Use lightweight IDs in PRs or commits for traceability:

```markdown
Roadmap: RM-0007
Feedback: FB-0014, FB-0015
Operator task: mobile-feedback-20260522
Why: short rationale
Validation: commands or manual checks
```

The feedback workflow can capture iOS Simulator screenshots/videos into an
Operator task and open a local browser review UI for annotation:

```bash
bash scripts/operator-feedback.sh start mobile-feedback-20260522 "Mobile feedback intake"
bash scripts/operator-feedback.sh capture-sim mobile-feedback-20260522 --note "Coach input overlaps"
bash scripts/operator-feedback.sh review mobile-feedback-20260522
bash scripts/operator-feedback.sh triage mobile-feedback-20260522
```

Use `$operator-feedback` to capture feedback intake, then `$operator-planner`
to triage, prioritize local roadmap items, and shape ready-for-execution plans.
`$operator` still owns task creation, dispatch, collection, and integration
review.

## Codex Desktop `$operator` Skill

For Codex Desktop, install or refresh every bundled skill globally:

```bash
bash scripts/codex-skills-install.sh
```

To update from the latest git source first:

```bash
bash scripts/operator-sync.sh
```

Then open or restart Codex Desktop and use natural-language operator requests:

```text
Use $operator. Show project status.
Use $operator. Start tmux lanes.
Use $operator. Create a backend task for auth scaffolding.
Use $operator. Dispatch this task to the ui lane.
Use $operator. Collect backend lane result for auth-001 and tell me if it is ready to integrate.
Use $operator. Summarize blockers across all lanes.
Use $operator. Update to latest version from git.
```

## Operator Feedback, Planning, And Execution Skills

The install script also refreshes explicit companion mode skills:

```bash
bash scripts/codex-skills-install.sh --skill operator-feedback --skill operator-planner
```

Then open or restart Codex Desktop and use:

```text
Use $operator-feedback with $design-agent. Capture these annotations.
Use $operator-feedback. Start a mobile feedback review for today's simulator testing.
Use $operator-planner. Review the feedback inbox and propose now/next/later.
Use $operator-planner. Promote the top feedback group into roadmap candidates.
Use $operator-planner. Draft a PR trace note for RM-0007 and FB-0014.
Use $operator. Execute the approved RM-0007 mobile-ui task.
```

The mode split is:

```text
$operator-feedback = capture evidence, classify feedback, write FB-* intake
$operator-planner  = prioritize, group, promote to roadmap/backlog
$operator          = create tasks, dispatch lanes, collect, integrate
```

## Optional Codex Desktop `$design-agent` Skill

The install script also refreshes the companion `$design-agent` skill. Use it when you want Codex Desktop to help with UX/design-system workflows before dispatching Claude Code or Operator Kit lanes:

```bash
bash scripts/codex-skills-install.sh --skill design-agent
```

Then open or restart Codex Desktop and use:

```text
Use $design-agent. Do a comprehensive UX and consistency review of this project.
Use $design-agent. Extract a design system from this codebase.
Use $design-agent. Recommend a design-system starter.
Use $design-agent with $operator. Package my annotations and dispatch a follow-up task.
```

`$design-agent` owns design/UX reasoning and task content. `$operator` owns project detection, lane safety, dispatch, collection, and integration review.

## Optional Codex Desktop UX Auditor And User Journey Skills

The install script also refreshes the companion UX Auditor (`$ux-auditor`) and
User Journey (`$user-journey`) skills. Use them when you want a scored
product-experience audit or journey artifacts before shaping implementation
work:

```bash
bash scripts/codex-skills-install.sh --skill ux-auditor --skill user-journey
```

Then open or restart Codex Desktop and use:

```text
Use $ux-auditor. Score this onboarding flow against the target persona and ICP.
Use $user-journey. Map the first-value journey for this product flow.
Use $user-journey with $ux-auditor. Create the journey map, then audit the flow.
Use $ux-auditor with $operator. Audit this flow and prepare lane-ready follow-ups.
```

UX Auditor (`$ux-auditor`) owns scored UX assessment and recommendations.
User Journey (`$user-journey`) owns persona, ICP, journey map, service
blueprint, and storyboard artifacts.
`$operator` owns project detection, lane safety, dispatch, collection, and
integration review.

## Optional Codex Desktop `$incubation` Skill

The install script also refreshes the companion `$incubation` skill. Use it when you want Codex Desktop to manage lightweight idea work before creating a real Operator Kit project:

```bash
bash scripts/codex-skills-install.sh --skill incubation
```

Then open or restart Codex Desktop and use:

```text
Use $incubation. Frame this idea and capture the next experiment.
Use $incubation. Review promotion readiness for this idea.
Use $incubation with $operator. Prepare this idea for promotion into an Operator Kit project.
Use $incubation with $design-agent. Turn this thesis into design-system starting assumptions.
```

`$incubation` owns idea framing, critique, durable markdown capture, and promotion readiness. `$operator` owns setup and operation after an idea is promoted into `/Users/norbert/Projects/<product-slug>/code/app`.

Do not initialize Agent Operator Kit inside `/Users/norbert/Incubation`.

The skill detects Operator Kit by walking upward from the current directory and looking for `operator.config.env` plus the required `scripts/operator-*.sh` files. If Codex starts inside a worker lane, it also checks sibling worktrees for a canonical repo with `operator.config.env`.

- `installed`: config and scripts exist, and `operator-status.sh` runs.
- `partial`: some files exist, but required scripts/config are missing or broken.
- `not-installed`: no reliable Operator Kit signals were found.

When installed, `$operator` reads `operator.config.env`, reads `AGENTS.md`, runs status, summary, and memory checks, and operates through the project-local scripts. When partial or missing, it reports what is missing and avoids unsafe dispatch/collect actions.

For updates, `scripts/operator-sync.sh` can refresh bundled Codex Desktop skills, detect the current Operator Kit project, update it from the latest kit source, and run validation checks. The lower-level `operator-update.sh` script refreshes evergreen `scripts/operator-*.sh` files, installs missing templates, preserves existing `operator.config.env`, `AGENTS.md`, `CODEX.md`, `CLAUDE.md`, `.claude/*`, and `.cursor/*`, then prints a changed/preserved summary.

## Rules

- Do not let two agents share the same branch.
- Do not let two agents edit the same file at the same time.
- Do not merge worker branches into `main` without operator review.
- After a user authorizes a feature track, keep dispatching necessary lane
  follow-ups until the feature is completed, integrated, validated, or blocked.
- Pause for user input before destructive cleanup, credential/provider changes,
  production deploys, release submissions, live-money enablement, or product
  decisions that cannot be safely inferred.
- Do not commit raw handoffs, task packets, pane captures, task working files, or transient session notes.
- Keep generated operator state under `OPERATOR_DIR`.
- Distill durable facts into operator memory or evergreen repo docs.

## Status

This is an initial public version. The shell scripts are intentionally small and inspectable. A richer CLI can wrap the same model later.
