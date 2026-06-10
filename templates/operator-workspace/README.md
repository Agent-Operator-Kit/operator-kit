# Operator Workspace

This directory stores local operator state for Agent Operator Kit.

Layout:

```text
tasks/<slug>/00-operator-brief.md
tasks/<slug>/memory.md
tasks/<slug>/tasks/*.md
tasks/<slug>/handoffs/*.md
tasks/<slug>/work/
tasks/<slug>/work/feedback/captures/
tasks/<slug>/work/feedback/annotations.json
features/<FS-id-slug>/feature.md
features/<FS-id-slug>/status.json
features/<FS-id-slug>/events.jsonl
features/<FS-id-slug>/memory.md
features/<FS-id-slug>/merge-plan.md
roadmap/items/*.md
roadmap/inbox/*.md
roadmap/views/*.md
system-map.md
catalog/roles/*.md
catalog/patterns/*.md
captures/
memory/project.md
memory/episodes/*.md
memory/packs/
```

This directory is outside the repo by design. It is safe to delete and recreate unless you intentionally keep local task history.

Use `memory/project.md` for durable project facts and `tasks/<slug>/memory.md` for feature-track facts that should move across lanes. Episode files are distilled from collected handoffs.

Use `tasks/<slug>/work/` for temporary artifacts such as exploratory markdown, redesign options, HTML prototypes, screenshots, generated images, exported assets, PDFs, and review READMEs.

Use `roadmap/` for local roadmap, backlog, feedback, prioritization, dispatch
readiness, blocked work, and recently shipped work. Link code changes back with
lightweight roadmap, feedback, and operator task IDs in PRs or commits.

Use `features/` for V4 feature-session state when one Codex or Cursor project
hosts multiple feature-focused chats. Feature sessions bind chat context to a
durable folder, duplicate role-template lane instances when surfaces allow it,
and keep merge plans, memory, handoffs, and working files together until the
feature is integrated, shipped, parked, blocked, closed, or archived.

Host adapters should enter feature-session work through:

```bash
bash scripts/operator-feature.sh open --tool codex --chat <host-chat-id>
bash scripts/operator-feature.sh open --tool cursor --chat <host-chat-id>
bash scripts/operator-feature.sh current --tool codex --chat <host-chat-id> --json
```

Codex thread metadata, Cursor chat labels, and remote-machine lane parameters
are indexes only. Rebuild the current state from `features/` when there is a
disagreement.

Use `system-map.md` and `catalog/` for V2 lane recommendations, specialist role
templates, approved architecture patterns, package/repo choices, validation
recipes, and escalation gates.

Mode split:

```text
$operator-feedback = capture evidence, classify feedback, write FB-* intake
$operator-planner  = prioritize, group, promote to roadmap/backlog
$operator          = create tasks, dispatch lanes, collect, integrate
```

Do not push raw handoffs, task packets, pane captures, task working files, memory packs, or transient notes to the project repository.

From the project repo or kit source, refresh this machine's Codex skills and
installed Operator Kit projects with:

```bash
bash scripts/operator-upgrade.sh
```
