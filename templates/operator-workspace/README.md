# Operator Workspace

This directory stores local operator state for Agent Operator Kit.

Layout:

```text
tasks/<slug>/00-operator-brief.md
tasks/<slug>/memory.md
tasks/<slug>/tasks/*.md
tasks/<slug>/handoffs/*.md
tasks/<slug>/work/
captures/
memory/project.md
memory/episodes/*.md
memory/packs/
```

This directory is outside the repo by design. It is safe to delete and recreate unless you intentionally keep local task history.

Use `memory/project.md` for durable project facts and `tasks/<slug>/memory.md` for feature-track facts that should move across lanes. Episode files are distilled from collected handoffs.

Use `tasks/<slug>/work/` for temporary artifacts such as exploratory markdown, redesign options, HTML prototypes, screenshots, generated images, exported assets, PDFs, and review READMEs.

Do not push raw handoffs, task packets, pane captures, task working files, memory packs, or transient notes to the project repository.

From the project repo or kit source, refresh this machine's Codex skills and
installed Operator Kit projects with:

```bash
bash scripts/operator-upgrade.sh
```
