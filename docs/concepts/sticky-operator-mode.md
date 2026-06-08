# Sticky Operator Mode

Sticky Operator mode lets a chat that is already bound to an Operator Kit
project route ordinary project-control phrases through Operator Kit without
requiring `$operator`, `/operator`, or a host-specific command on every turn.

The rule is deliberately narrow:

```text
Sticky mode changes routing. It does not grant execution authority.
```

When sticky mode is active, `status`, `what is blocked?`, or `summarize lanes`
can use Operator status, roadmap, memory, and handoff context by default. The
assistant still needs clear user intent and the normal preflight checks before
dispatching lanes, collecting handoffs, integrating source changes, pushing,
tagging, deleting files, changing credentials, or mutating provider state.

## Binding

A sticky chat is bound to one Operator project or external cockpit profile.
Binding requires:

- an available Operator capability in the host;
- exactly one selected `operator.config.env` or external Operator config;
- a resolved `OPERATOR_DIR`, lane map, and project script surface;
- explicit user initialization for the chat, or a host setting that safely
  restores the same selected binding.

If multiple Operator configs are discoverable, sticky mode should not guess. It
should list the candidates and ask the user to choose. Switching projects clears
or revalidates the binding. `operator off` clears sticky routing for the chat.

## Modes

| Mode | Behavior |
| --- | --- |
| `operator off` | Normal assistant behavior. Operator runs only when explicitly invoked. |
| `operator observe` | Read-only Operator cockpit. Status, summaries, roadmap reads, memory reads, and feedback/planning summaries can route through Operator. |
| `operator active` | Default Operator workflow routing. Feedback intake, planning, and task-packet creation can happen when the user's wording is clear. |
| `operator dispatch` | Lane execution can proceed when the user clearly asks and preflight passes. Release, destructive, provider, and credential actions still need separate confirmation. |

New sticky sessions should default to `operator observe`. It gives users the
low-friction cockpit experience without making execution feel implicit.

## Command Behavior

| User phrase | Sticky behavior |
| --- | --- |
| `status` | Run Operator status and summary for the bound project in `observe` or stronger modes. |
| `what is blocked?` | Read status, roadmap, handoffs, and memory; report blockers. |
| `summarize lanes` | Produce a read-only lane summary. |
| `capture this feedback` | Route to feedback-intake behavior and preserve evidence when the note is clear. |
| `create a task for the UI lane` | Propose the task in `observe`; create a task packet in `active` or `dispatch` if lane and scope are clear. |
| `dispatch backend` | Block in `observe`; ask for confirmation or mode change in `active`; dispatch in `dispatch` only after lane/task preflight. |
| `collect backend` | Block in `observe`; require confirmation in `active`; collect in `dispatch` when the lane, task, and handoff are clear. |
| `merge it` | Require explicit lane/task/change target, diff review, conflict check, and validation context. |
| `push main` | Require separate confirmation plus branch, remote, status, and tag/release policy checks. |
| `delete old worktrees` | Require exact targets, dry-run output, and a recovery path before deletion. |

## Safety Gates

Before any mutating action, sticky mode must pass these gates:

- Binding gate: exactly one selected Operator config.
- Mode gate: the action class is allowed in the current mode.
- Intent gate: the user's wording clearly requests the action.
- Object gate: lane, task, branch, remote, file, or path target is explicit.
- Conflict gate: lane ownership and worktree state are safe.
- Preflight gate: the relevant Operator, git, roadmap, or handoff checks pass.
- Review gate: source integration, push, tag, release, destructive cleanup, and
  provider or credential actions get a user-visible summary before action.
- Host gate: Codex, Cursor, and Claude Code only claim sticky behavior they can
  actually support.

Ambiguous phrases such as `fix it`, `merge it`, or `clean up everything` should
not trigger mutation until the target and action are explicit.

## Host Adapters

Codex can expose sticky mode as first-class plugin activation and, if the host
surface supports it, visible mode state.

Cursor should treat sticky mode as adapter guidance through project rules,
skills, prompts, or agent instructions unless Cursor exposes durable session
state for this purpose. Cursor agents should still preserve the same binding and
safety gates.

Claude Code should map sticky mode to slash commands, project agents, and docs.
The behavior is the same contract, not a separate runtime: commands and agents
can make routing easier, but execution boundaries stay explicit.

## Release Split

Sticky mode belongs with the V3 plugin/adapters direction. The documentation can
describe the contract before V3 is integrated, but it should not imply that
plugin package files are present on `main` or that global host adapters are
already installed for every project.
