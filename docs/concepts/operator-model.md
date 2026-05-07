# Operator Model

The operator is the integrator and system owner. Worker agents execute scoped tasks in isolated lanes.

The operator owns:

- lane assignment
- branch and worktree policy
- dispatching task packets
- collecting handoffs
- reviewing diffs
- final integration into the stable branch
- keeping an authorized feature track moving across lanes until it is done or
  blocked

Worker agents own:

- scoped implementation within their assigned lane
- clear handoffs
- validation evidence
- respecting file and branch boundaries

This model is intentionally conservative. It favors traceability and integration quality over agents freely editing the same branch.

## Feature-Track Autonomy

For an authorized feature track, the operator should not stop after every
handoff just to ask whether to dispatch the obvious next lane. The operator
should keep coordinating follow-up work until the feature is completed,
integrated, validated, or blocked.

The operator should pause for user input when the next step changes product
direction, requires credentials, touches provider consoles, runs destructive
cleanup, starts a deployment or release submission, or enables live-money /
production trading behavior.
