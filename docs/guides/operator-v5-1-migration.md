# Migrating Operator V4 or signed V5 to V5.1

V5.1 replaces the signed global control graph with local dependency graphs
inside feature sessions. Updating the project installs the V5.1 tools but does
not silently reinterpret existing state or change the version marker.

## Plan

```bash
bash scripts/operator-v5-1-migrate.sh plan
```

The plan reports the source version, feature graphs to initialize, signed V5
directories to archive, and the exact authorization required for apply. It
performs no writes.

## Apply

```bash
bash scripts/operator-v5-1-migrate.sh apply \
  --authorize MIGRATE_TO_V5_1_LOCAL_GRAPH
```

For V4 projects, apply initializes an empty `graph.json` for each existing
feature session and changes `OPERATOR_KIT_VERSION` to `5.1`.

For signed V5 projects, apply additionally moves `authority/`, `graph/`,
`host/`, and `loop/` beneath:

```text
OPERATOR_DIR/archive/signed-v5/<UTC timestamp>/
```

It never reads, changes, or deletes macOS Keychain or Linux Secret Service
entries. Those credentials are inert after the signed runtime is removed. Keep
them if rollback is plausible; clean them up separately only after deciding the
archived edition is no longer needed.

After apply, rerun the latest update once. Projects already marked `5.1` then
remove obsolete signed-runtime scripts and schemas from the installed repo:

```bash
bash scripts/operator-update.sh --channel latest --target /path/to/project
```

The migration manifest is written to:

```text
OPERATOR_DIR/migrations/to-v5.1-local-graph.json
```

## Validate

```bash
bash scripts/operator-status.sh
bash scripts/operator-graph.sh status
bash scripts/operator-graph.sh validate
bash scripts/operator-graph.sh frontier --capacity 4
```

Expected status includes `Operator Kit version: 5.1` and `no credentials
required`.

## Rollback

The signed implementation is preserved at Git tag
`v5.0-signed-control-plane`. A rollback is a reviewed operation: restore that
source version together with the matching archived Operator directories. Never
export private Keychain material into the repository or Operator workspace.
