# Incubation Collaboration

Incubation is an optional Codex Desktop skill for lightweight product idea work before a project deserves an Operator Kit setup.

It composes with `$operator` instead of replacing it.

```text
$incubation = idea framing, durable idea files, promotion readiness
$operator = promoted-project setup, lane safety, dispatch, collection, integration review
$design-agent = UX/design-system review and UI task shaping
```

## Install The Skill

From the Operator Kit source repo:

```bash
bash scripts/codex-skills-install.sh --skill incubation
```

All bundled Codex Desktop skills can be installed or refreshed with:

```bash
bash scripts/codex-skills-install.sh
```

Restart Codex Desktop after installing or updating skills.

## Typical Requests

```text
Use $incubation. Frame this idea and capture the next experiment.
Use $incubation. Review the promotion readiness of this idea.
Use $incubation. Archive this idea and explain why.
Use $incubation with $operator. Prepare this idea for promotion into an Operator Kit project.
Use $incubation with $design-agent. Turn this thesis into design-system starting assumptions.
```

## Promotion Boundary

Do not initialize Agent Operator Kit inside:

```text
$HOME/Incubation
```

When an idea graduates, create or prepare:

```text
$HOME/Projects/<product-slug>/
  code/
    app/
  operator/
```

Then initialize Agent Operator Kit in the promoted project repo, usually:

```text
$HOME/Projects/<product-slug>/code/app
```

## Operator-Aware Flow

1. `$incubation` clarifies the idea and captures durable files under `ideas/<slug>/`.
2. `$incubation` updates `promotion-brief.md` and the incubation ops files.
3. The user confirms promotion.
4. The promoted project folder is created under `$HOME/Projects/<product-slug>/`.
5. `$operator` initializes or operates Agent Operator Kit in the promoted project repo.
6. `$design-agent` can review UX/design-system direction before UI work is dispatched.

## Guardrails

- Keep incubation lightweight.
- Capture meaningful chat learning into markdown before closing the thread.
- Do not commit, push, deploy, or initialize infrastructure from incubation unless explicitly asked.
- Do not carry every scratch note into promoted projects; summarize the useful context.
- Treat promotion as a project handoff, not an implementation shortcut.
