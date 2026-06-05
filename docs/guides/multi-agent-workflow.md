# Multi-Agent Workflow

1. Operator creates a task folder.
2. Operator promotes or reviews task memory when prior lane context exists.
3. Operator writes lane-specific task packets and names where temporary working
   files should land under `OPERATOR_DIR/tasks/<slug>/work/`.
4. Operator dispatches packets into tmux lanes, using `--with-memory` when a
   lane needs retrieved context.
5. Worker agents execute within their worktree and branch.
6. Operator collects handoffs; collection generates a distilled episode memory
   file.
7. Operator reviews diffs, validation, working files, and memory candidates.
8. If a handoff implies a necessary follow-up in another lane, the operator
   dispatches it and keeps monitoring the feature track.
9. Operator integrates approved changes into the stable branch.

Once the user authorizes a feature track, the operator should keep dispatching
lane follow-ups until the feature is completed, integrated, validated, or
blocked. Pause for user input before destructive cleanup, credential/provider
changes, production deploys, release submissions, regulated or safety-critical
behavior, or product decisions that cannot be safely inferred.

Example:

```bash
task_dir="$(bash scripts/operator-task.sh ui-polish-001 "Polish dashboard")"
$EDITOR "$task_dir/tasks/ui.md"
bash scripts/operator-memory.sh promote task ui-polish-001 "Dashboard polish should preserve current chart density."
bash scripts/operator-dispatch.sh --with-memory ui "$task_dir/tasks/ui.md"
bash scripts/operator-collect.sh ui ui-polish-001
bash scripts/operator-summary.sh
```
