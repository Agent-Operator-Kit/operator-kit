# External Operator Workspace

Operator state should normally live outside the repository so task packets,
handoffs, captures, planning data, and local feature graphs do not pollute source
history.

Recommended layout:

```text
operator/
  README.md
  features/
    <FS-id-slug>/
      status.json
      graph.json
      graph-events.jsonl
      tasks/
      handoffs/
      work/
  tasks/
  captures/
  memory/
  roadmap/
  catalog/
  archive/       # optional signed-V5 migration archive
  migrations/    # migration manifests
```

V5.2 graph files are ordinary local JSON. They contain no secrets and require
no Keychain or credential backup. Back up `OPERATOR_DIR` with the corresponding
repository revision when its planning history and handoffs matter.
