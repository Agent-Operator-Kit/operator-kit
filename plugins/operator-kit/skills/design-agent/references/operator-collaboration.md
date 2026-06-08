# Operator Collaboration

Use this when `$design-agent` and `$operator` are used together.

## Role Split

```text
$design-agent = UX/design-system reasoning and task content
$operator = lane safety, dispatch, collection, integration review
```

## Flow

1. `$operator` detects the project and runs:

   ```bash
   bash scripts/operator-status.sh
   bash scripts/operator-summary.sh
   bash scripts/operator-memory.sh status
   ```

2. `$design-agent` inspects UI/design-system context and drafts the task packet.
3. `$operator` creates task folders under `$OPERATOR_DIR` using `operator-task.sh`.
4. `$operator` writes/places task packet under `$OPERATOR_DIR/tasks/<slug>/tasks/` and adds design facts worth carrying across lanes to `$OPERATOR_DIR/tasks/<slug>/memory.md`.
5. Temporary design artifacts go under `$OPERATOR_DIR/tasks/<slug>/work/`.
6. `$operator` dispatches the safe lane, using `--with-memory` when prior design context matters.
7. `$operator` collects output.
8. `$design-agent` reviews output and packages next feedback.

## Task Packet Types

### Design-System Extraction

Expected durable output, if accepted:

```text
design-system/
design-system-recommendation.md
design-system-adoption-plan.md
drift-report.md
```

Temporary extraction notes, alternate proposals, screenshots, and generated
previews stay under `$OPERATOR_DIR/tasks/<slug>/work/`.

### UX Consistency Review

Expected temporary output:

```text
$OPERATOR_DIR/tasks/<slug>/work/design-agent-review.md
$OPERATOR_DIR/tasks/<slug>/work/ux-consistency-report.md
$OPERATOR_DIR/tasks/<slug>/work/next-task-recommendations.md
```

### Design Mockup

Expected temporary output:

```text
$OPERATOR_DIR/tasks/<slug>/work/design-options/
$OPERATOR_DIR/tasks/<slug>/work/design-options/<option>/index.html
$OPERATOR_DIR/tasks/<slug>/work/design-options/<option>/README.md
$OPERATOR_DIR/tasks/<slug>/work/images/
```

### UI Implementation

Expected output:

```text
production UI code changes
implementation notes
validation results
```

## Guardrails

- `$design-agent` does not dispatch directly when `$operator` is available.
- `$operator` does not decide product taste or starter choice.
- Do not create design and UI lanes until the project needs that complexity.
- Do not let design and UI lanes edit the same files at the same time.
- Keep raw task state in `$OPERATOR_DIR`.
- Keep temporary design files under `$OPERATOR_DIR/tasks/<slug>/work/`.
- Keep generated operator memory under `$OPERATOR_DIR`; do not commit memory packs.
- Commit durable design-system decisions only when the user is ready.
