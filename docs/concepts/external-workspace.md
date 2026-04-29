# External Operator Workspace

Generated operator state should live outside the repo.

This includes:

- task packets
- pane captures
- agent handoffs
- raw status snapshots
- local screenshots
- temporary notes

Recommended layout:

```text
operator/
  README.md
  tasks/
    <slug>/
      00-operator-brief.md
      tasks/
      handoffs/
  captures/
```

The codebase should contain evergreen docs and reusable scripts only. If a fact from a handoff becomes durable, distill it into a maintained doc instead of committing the raw handoff.
