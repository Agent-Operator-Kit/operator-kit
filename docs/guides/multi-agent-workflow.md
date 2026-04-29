# Multi-Agent Workflow

1. Operator creates a task folder.
2. Operator writes lane-specific task packets.
3. Operator dispatches packets into tmux lanes.
4. Worker agents execute within their worktree and branch.
5. Operator collects handoffs.
6. Operator reviews diffs and validation.
7. Operator integrates approved changes into the stable branch.

Example:

```bash
task_dir="$(bash scripts/operator-task.sh ui-polish-001 "Polish dashboard")"
$EDITOR "$task_dir/tasks/ui.md"
bash scripts/operator-dispatch.sh ui "$task_dir/tasks/ui.md"
bash scripts/operator-collect.sh ui ui-polish-001
bash scripts/operator-summary.sh
```
