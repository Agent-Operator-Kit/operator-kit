# Codex Operator Skill

Use the Codex Desktop `$operator` skill after Agent Operator Kit is installed in a promoted project.

The setup skill and the runtime skill have different jobs:

```text
operator-workflow -> setup, bootstrap, repair
operator-feedback -> feedback intake in an installed project
operator-planner  -> roadmap/backlog planning in an installed project
UX Auditor ($ux-auditor) -> scored UX assessment in an installed project
user-journey      -> persona, ICP, journey, blueprint, and storyboard artifacts
operator          -> execution in an installed project
```

## Install Globally

From this kit repo:

```bash
bash scripts/codex-skills-install.sh
```

This installs or refreshes every bundled Codex Desktop skill under `skills/codex/`, including `$operator`, `operator-workflow`, `$operator-feedback`, `$operator-planner`, `$design-agent`, `$ux-auditor`, `$user-journey`, and `$incubation`.

To fast-forward the kit source first, then refresh skills:

```bash
bash scripts/operator-sync.sh --skip-project
```

Restart or reopen Codex Desktop so the skill list refreshes.

Codex skills are not background daemons. Invoke the skill explicitly with `$operator`, or use language that clearly refers to Operator Kit lanes, task packets, dispatch, collection, or handoffs.

To keep Operator Kit as the default for a Codex project/session, say:

```text
Always use $operator for this project unless I explicitly ask for feedback, planning, design, UX audit, journey mapping, setup, or non-operator work.
```

`CODEX.md` and `AGENTS.md` carry the same routing convention for installed
projects, while `$operator-feedback`, `$operator-planner`, and `$design-agent`
remain the deliberate modes for observation, planning, and design work.
Use UX Auditor (`$ux-auditor`) for scored UX assessment and `$user-journey`
for journey artifacts before execution work is dispatched.

## Operator Feedback And Planner Companions

Install `$operator-feedback` and `$operator-planner` when you want explicit
feedback and planning modes before `$operator` execution.

From this kit repo:

```bash
bash scripts/codex-skills-install.sh --skill operator-feedback --skill operator-planner
```

Use the skills together:

```text
Use $operator-feedback with $design-agent. Capture these annotations.
Use $operator-feedback. Start a mobile feedback review for simulator testing.
Use $operator-planner. Review the feedback inbox and propose now/next/later.
Use $operator-planner. Promote the top feedback group into roadmap candidates.
Use $operator-planner. Draft a PR trace note for RM-0007 and FB-0014.
Use $operator. Execute the approved RM-0007 mobile-ui task.
```

Role split:

```text
$operator-feedback -> evidence capture, classification, FB-* intake
$operator-planner  -> roadmap, prioritization, ready-for-execution planning
$operator          -> task creation, lane safety, dispatch, collection, integration review
```

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

## Optional UX Auditor And User Journey Companions

Install UX Auditor (`$ux-auditor`) and User Journey (`$user-journey`) when you
want scored UX assessment or journey artifacts before `$operator` execution.

From this kit repo:

```bash
bash scripts/codex-skills-install.sh --skill ux-auditor --skill user-journey
```

Use the skills together:

```text
Use $ux-auditor. Score this onboarding flow against persona, ICP, and journey risk.
Use $user-journey. Map the first-value journey and service blueprint.
Use $user-journey with $ux-auditor. Build the artifact, then audit the flow.
Use $ux-auditor with $operator. Convert the highest-risk findings into a lane-ready task.
```

Role split:

```text
UX Auditor ($ux-auditor) -> scored UX assessment and prioritized recommendations
$user-journey            -> persona, ICP, journey map, service blueprint, storyboard artifacts
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

## Codex Main Operator With Cursor Lanes

Cursor support does not require changing the core operator model. The important
decision is which surface owns integration for the project or session.

When Codex Desktop is the main operator, keep the `operator` lane Codex-led and
use Cursor as worker lanes:

```text
OPERATOR_LANES='
operator|Codex Desktop|app|main|
cursor|Cursor CLI|app-cursor|cursor/operator|cursor agent
ui|Claude Code|app-ui|claude/ui|claude --dangerously-skip-permissions --permission-mode bypassPermissions
'
```

For a web app plus agent/API split, Cursor worker lanes can be named by scope:

```text
OPERATOR_LANES='
operator|Codex Desktop|app|main|
web|Cursor CLI|app-web|cursor/web|cursor agent
agents-api|Cursor CLI|app-agents-api|cursor/agents-api|cursor agent
'
```

If a project was bootstrapped with the Cursor profile, the lane map starts with
`operator|Cursor IDE|...`. That is correct for Cursor-first projects, but Codex
should call out the cockpit mismatch before dispatching implementation work as
the main operator. Either operate from Codex in status/review mode, or make the
lane map explicitly Codex-led before Codex starts integrating worker output.

Local Cursor CLI lanes still use the same task packet, dispatch, collect, and
review flow:

```bash
bash scripts/operator-dispatch.sh --with-memory cursor "$OPERATOR_DIR/tasks/<slug>/tasks/cursor.md"
bash scripts/operator-collect.sh cursor <slug>
```

Cursor Cloud Agents are different: they are remote branch workers and cannot
rely on local `OPERATOR_DIR`, tmux, local memory, simulators, or device state.
Put the task packet, relevant memory, validation commands, and handoff
requirements directly into the Cloud Agent prompt or PR context.

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
scripts/operator-memory.sh
scripts/operator-roadmap.sh
scripts/operator-feedback.sh
scripts/operator-upgrade.sh
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
Use $operator. Dispatch the auth task to backend with memory.
Use $operator. Collect backend result for auth-001 and tell me if it is ready to integrate.
Use $operator. Search operator memory for auth migration notes.
Use $operator. Review the ui lane diff and recommend whether to merge.
Use $operator --upgrade.
Use $operator /upgrade dry run.
Use $operator. Update to latest version from git.
```

## Upgrade Command

`$operator --upgrade`, `$operator /upgrade`, and natural-language upgrade
requests should run:

```bash
bash scripts/operator-upgrade.sh
```

This refreshes bundled Codex Desktop skills, discovers installed Operator Kit
projects under `~/Projects`, updates each project, and runs checks. Use:

```bash
bash scripts/operator-upgrade.sh --dry-run
bash scripts/operator-upgrade.sh --target /path/to/project
bash scripts/operator-upgrade.sh --projects-root /path/to/projects
bash <(curl -fsSL https://raw.githubusercontent.com/Agent-Operator-Kit/operator-kit/main/scripts/operator-upgrade.sh)
```

## Memory

The `$operator` skill should use Operator Memory Router for cross-lane context
that should survive chat compaction:

```bash
bash scripts/operator-memory.sh status
bash scripts/operator-memory.sh search <query>
bash scripts/operator-memory.sh promote project "<durable fact>"
bash scripts/operator-memory.sh promote task <slug> "<feature-track fact>"
bash scripts/operator-dispatch.sh --with-memory <lane> "$OPERATOR_DIR/tasks/<slug>/tasks/<lane>.md"
```

Task creation creates `OPERATOR_DIR/tasks/<slug>/memory.md`. Collection writes
a distilled episode under `OPERATOR_DIR/memory/episodes/`. The operator should
promote only relevant facts; raw captures and handoffs stay as evidence.

## Local Roadmap And Feedback

The `$operator` skill can use local roadmap and feedback scripts when planning
state should stay outside the app repo:

```bash
bash scripts/operator-roadmap.sh status
bash scripts/operator-roadmap.sh ready
bash scripts/operator-feedback.sh detect
bash scripts/operator-feedback.sh start mobile-feedback-20260522 "Mobile feedback intake"
bash scripts/operator-feedback.sh capture-sim mobile-feedback-20260522 --note "Coach input overlaps"
bash scripts/operator-feedback.sh review mobile-feedback-20260522
bash scripts/operator-feedback.sh triage mobile-feedback-20260522
```

Use `$operator-feedback` for intake and `$operator-planner` for triage and
prioritization. `$operator` should still create task folders, check lane safety,
dispatch, collect, and integrate.

## Working Files

The `$operator` skill should keep temporary artifacts under the task:

```text
OPERATOR_DIR/tasks/<slug>/work/
```

Use this for scratch markdown, review READMEs, redesign proposals, HTML
prototypes, screenshots, generated images, exported assets, PDFs, and other
temporary files. Promote files into the repo only when they become durable
source, evergreen docs, or accepted design-system material.

## Updating Operator Kit

Use this when a project already has Operator Kit installed but may be behind the latest kit source:

```text
Use $operator. Update to latest version from git.
```

Codex should:

1. Detect the installed project.
2. Pull the latest local kit source when it is clean, or clone/fetch the public source.
3. Prefer `scripts/operator-sync.sh` for the full one-command path.
4. Refresh bundled Codex Desktop skills with `scripts/codex-skills-install.sh`.
5. Run `scripts/operator-update.sh` against the project.
6. Run syntax, status, summary, and git status checks.
7. Run `scripts/operator-memory.sh status` and `scripts/operator-roadmap.sh status`.
8. Summarize updated files, installed missing files, preserved project-specific files, validation results, memory/roadmap status, and follow-up.

The update must preserve:

- `operator.config.env`
- existing `AGENTS.md`, `CODEX.md`, and `CLAUDE.md`
- existing `.claude/*` and `.cursor/*`
- task packets, handoffs, captures, task working files, and transient operator state
- application source code

The update refreshes evergreen scripts and installs missing templates only.

## Operating Rules

- Prefer `scripts/operator-*.sh` over raw tmux commands.
- Keep task packets, captures, handoffs, working files, and transient notes under `OPERATOR_DIR`.
- Check git status before dispatch, collection, or integration.
- Do not let two lanes share a branch.
- Do not let two lanes edit the same files at the same time.
- Do not merge worker branches into the stable branch without operator review.
- Do not commit raw handoffs, task packets, pane captures, task working files, or secrets.
