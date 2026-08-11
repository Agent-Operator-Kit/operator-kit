# External Operator Workspace

Operator state should live outside the repo. Some of it is temporary, but the
workspace as a whole is durable and must not be treated as disposable.

This includes:

- task packets
- pane captures
- agent handoffs
- task working files
- raw status snapshots
- local screenshots
- temporary notes
- append-only V5 graph history, projections, binding records, and fence tombstones
- host-session records and external-effect ledgers
- migration checksum manifests

Recommended layout:

```text
operator/
  README.md
  tasks/
    <slug>/
      00-operator-brief.md
      memory.md
      tasks/
      handoffs/
      work/
  captures/
  memory/
  authority/        # public trust anchor only
  graph/            # durable append-only execution history
  host/             # private sessions, handoffs, and effect fences
  loop/             # private heartbeat state
  migrations/       # lossless legacy inventories and checksums
```

The codebase should contain evergreen docs and reusable scripts only. If a fact
from a handoff becomes durable, distill it into a maintained doc instead of
committing the raw handoff.

Back up `OPERATOR_DIR` consistently with the repository revision and public
trust anchor. Stop graph/loop/host writers before backup or restore. Recovery
must restore graph journal, projection, definition, bindings, authority anchor,
host effect ledgers, roadmap, memory, and migration manifests as one reviewed
set, then run `operator-graph replay check`. Never generate replacement keys,
reset fences, or reconstruct graph truth from V4 files during recovery.

Private authority and proof keys are not backup members because they must never
enter `OPERATOR_DIR`; recover them through the approved control-plane/keychain
process. Until keychain/broker and signed bindings are restored, mutations fail
closed.
