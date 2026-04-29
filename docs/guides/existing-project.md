# Existing Project Setup

1. Clone this kit.
2. Run the bootstrap script against your repo.
3. Edit `operator.config.env`.
4. Start tmux.
5. Create a smoke task.
6. Dispatch to a worker lane.
7. Collect a handoff.
8. Confirm generated state lands under `OPERATOR_DIR`, not the repo.

```bash
bash scripts/operator-bootstrap.sh /path/to/repo
cd /path/to/repo
bash scripts/operator-tmux.sh start
bash scripts/operator-task.sh smoke-001 "Smoke task"
bash scripts/operator-status.sh
```
