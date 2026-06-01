# Operator Catalog

V2 Operator Kit uses this catalog as the project-local source of truth for:

- specialist role templates
- durable lane recommendations
- architecture patterns
- approved packages, repos, and solution approaches
- validation recipes and escalation gates

Treat this like an engineering design system. The generic templates give a
starting point; project-approved patterns should be curated here as the system
matures.

## Layout

- `roles/`: specialist role templates that can become durable lanes or role overlays.
- `patterns/`: approved architecture patterns and tool choices reused by roles.

## Rule

Existing project architecture wins. New solutions should either follow an
approved pattern here or add a clear proposal before implementation.
