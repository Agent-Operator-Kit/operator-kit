# Contributing

Agent Operator Kit should stay simple, inspectable, and safe to adapt.

Guidelines:

- Keep scripts dependency-light.
- Prefer plain shell and plain text templates for v0.
- Do not add project-specific secrets, private paths, real handoffs, raw transcripts, or provider credentials.
- Keep examples sanitized.
- Document behavior before adding automation.
- Preserve the external operator workspace boundary.

Useful local checks:

```bash
bash -n scripts/*.sh
bash tests/smoke/bootstrap-existing-project.sh
```
