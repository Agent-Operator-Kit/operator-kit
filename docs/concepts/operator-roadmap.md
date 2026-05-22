# Operator Roadmap Layer

Operator Kit now treats roadmap, backlog, and feedback planning as local
operator state by default. The app repo should not become the working tracker.

The model is:

```text
OPERATOR_DIR/roadmap = local planning source of truth
OPERATOR_DIR/tasks = execution packets, handoffs, and working files
app repo PRs/commits = lightweight trace references only
future team mode = separate planning repo or tracker
```

This keeps the code repo focused while preserving a reviewable planning loop for
solo work and a migration path for multi-developer work.

## Why Local First

For a solo builder, roadmap and feedback state changes constantly while testing.
Committing every backlog item, prioritization note, screenshot annotation, and
draft roadmap idea into the app repo adds noise. But losing the rationale is
also bad.

The compromise:

- keep local planning and feedback under `OPERATOR_DIR/roadmap`
- keep raw execution evidence under `OPERATOR_DIR/tasks/<slug>/work`
- reference IDs in PRs or commits when code changes land
- later promote the planning ledger to a separate repo or tracker when more
  people join

## Layout

```text
OPERATOR_DIR/
  roadmap/
    README.md
    items/
      RM-0001-mobile-coach-chat-polish.md
    inbox/
      FB-0001-coach-chat-input-overlap.md
    views/
      ready.md
      blocked.md
      now-next-later.md
      shipped.md
  tasks/
    mobile-feedback-20260522/
      work/
        feedback/
          captures/
          annotations.json
          annotations.md
          backlog.md
          roadmap.md
```

## Traceability

The code repo should carry only enough trace context to answer why a change
exists:

```markdown
Roadmap: RM-0007
Feedback: FB-0014, FB-0015
Operator task: mobile-feedback-20260522
Why: short rationale
Validation: commands, screenshots, simulator checks, or manual checks
```

Raw handoffs, task packets, captures, feedback annotations, and local roadmap
views stay outside the repo.

## Roadmap Items

Roadmap items live under `OPERATOR_DIR/roadmap/items`.

Fields:

- `ID`
- `type`
- `status`
- `priority`
- `impact`
- `effort`
- `confidence`
- `areas`
- `source feedback`
- `related operator tasks`
- `related PRs/commits`
- `problem`
- `rationale`
- `acceptance criteria`
- `dispatch plan`
- `progress`

Statuses:

```text
idea -> candidate -> planned -> ready -> dispatched -> in-review -> shipped
                    \-> parked
                    \-> blocked
                    \-> superseded
```

Mark an item `ready` only when it has acceptance criteria, lane ownership, and a
dispatch plan that `$operator` can safely turn into task packets.

## Feedback Items

Feedback items live under `OPERATOR_DIR/roadmap/inbox`.

Fields:

- `ID`
- `source`
- `status`
- `screen`
- `target`
- `evidence`
- `coordinates`
- `testID`
- `type`
- `severity`
- `priority`
- `comment`
- `expected`
- `owner lane`
- `related roadmap`
- `related task`

Feedback should be triaged before dispatch. `$operator-feedback` classifies it
as bug, UI polish, UX/product decision, backend/API issue, data issue, release
issue, or roadmap idea; `$operator-planner` decides what should be promoted or
prioritized.

## Mobile Feedback Closed Loop

Native mobile does not provide a DOM for Codex Browser annotation. The closest
generic equivalent is:

```text
screenshot/video + screen + coordinates or testID + comment
```

The v1 loop:

1. `$operator` creates a feedback task:
   ```bash
   bash scripts/operator-feedback.sh start mobile-feedback-20260522 "Mobile feedback intake"
   ```
2. The human tests in simulator or TestFlight.
3. Captures land under the task:
   ```bash
   bash scripts/operator-feedback.sh capture-sim mobile-feedback-20260522 --note "Coach input overlaps"
   ```
4. The review UI opens in Codex Browser:
   ```bash
   bash scripts/operator-feedback.sh review mobile-feedback-20260522
   ```
5. The human clicks screenshots and adds comments, type, severity, expected
   behavior, owner lane, and optional `testID`.
6. The annotations are triaged:
   ```bash
   bash scripts/operator-feedback.sh triage mobile-feedback-20260522
   ```
7. `$operator-planner` groups feedback into roadmap/backlog items and prepares
   ready-for-execution plans.
8. `$operator` creates task packets, checks lane safety, and dispatches only
   scoped, ready work.

## Mode Skills

Use explicit mode skills so the user does not have to repeat intent guardrails:

```text
$operator-feedback = capture evidence, classify feedback, write FB-* intake
$operator-planner  = prioritize, group, promote to roadmap/backlog
$operator          = create tasks, dispatch lanes, collect, integrate
```

Typical requests:

```text
Use $operator-feedback with $design-agent. Capture these annotations.
Use $operator-feedback. Start a mobile feedback review for simulator testing.
Use $operator-planner. Review mobile feedback and propose now/next/later.
Use $operator-planner. Promote the top feedback group into roadmap candidates.
Use $operator-planner. Draft a PR trace note for RM-0007 and FB-0014.
Use $operator. Execute the approved RM-0007 mobile-ui task.
```

`$operator-feedback` should not promote feedback directly into implementation.
`$operator-planner` may draft ready-for-execution plans, but should not dispatch,
collect, merge, or send text directly into tmux panes.

## Multi-Developer Path

When more people join, keep the app repo clean and promote planning to a shared
surface:

```text
app repo = source code and PR trace IDs
planning repo/tracker = shared roadmap and backlog
local OPERATOR_DIR = each operator's execution workspace
```

Good shared options:

- private `project-ops` git repo
- Linear/Jira/GitHub Issues/Projects
- a lightweight internal planning service

The local file contracts should remain close to the shared format so sync can be
added later without changing how agents reason about roadmap items.

## Commands

```bash
bash scripts/operator-roadmap.sh init
bash scripts/operator-roadmap.sh add "Coach chat polish" --type bug --priority P1 --areas mobile
bash scripts/operator-roadmap.sh list
bash scripts/operator-roadmap.sh status
bash scripts/operator-roadmap.sh ready
bash scripts/operator-roadmap.sh link-task RM-0001 mobile-chat-polish-001
bash scripts/operator-roadmap.sh pr-note RM-0001 --feedback FB-0001 --task mobile-chat-polish-001

bash scripts/operator-feedback.sh detect
bash scripts/operator-feedback.sh start mobile-feedback-20260522 "Mobile feedback intake"
bash scripts/operator-feedback.sh capture-sim mobile-feedback-20260522 --note "Coach input overlap"
bash scripts/operator-feedback.sh review mobile-feedback-20260522
bash scripts/operator-feedback.sh triage mobile-feedback-20260522
```

## Guardrails

- Do not commit raw feedback, task packets, handoffs, captures, or local planning
  views into the app repo.
- Do not dispatch feedback directly; triage it first.
- Do not mark roadmap items ready without acceptance criteria and lane ownership.
- Do not let `$operator-planner` bypass `$operator` lane checks.
- Use PR/commit trace references for code-level rationale.
- Promote to a shared planning repo/tracker when collaboration requires it.
