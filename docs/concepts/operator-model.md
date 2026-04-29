# Operator Model

The operator is the integrator and system owner. Worker agents execute scoped tasks in isolated lanes.

The operator owns:

- lane assignment
- branch and worktree policy
- dispatching task packets
- collecting handoffs
- reviewing diffs
- final integration into the stable branch

Worker agents own:

- scoped implementation within their assigned lane
- clear handoffs
- validation evidence
- respecting file and branch boundaries

This model is intentionally conservative. It favors traceability and integration quality over agents freely editing the same branch.
