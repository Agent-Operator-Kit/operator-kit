# Operator V5 Trusted Host Runners

Status: normative RM-0005 host boundary for Codex and Claude Code.

Operator V5 host runners connect the RM-0003 loop to the RM-0007 control graph
without giving a lane graph authority, a proof key, or another lane's writable
paths. `scripts/operator-host.sh` is the host entrypoint and
`scripts/operator-proof-broker.sh` is its isolated one-shot signer. Their only
shared implementation is `scripts/operator_host.py`.

The graph remains the source of truth. A chat title, CLI session label, tmux
window, task packet, or host-session file cannot authorize a mutation. The
current signed actor binding, graph assignment, lease, and fence must all agree.

## Host commands

```text
operator-host open         --tool codex|claude --session ID [--scope NODE] [--json]
operator-host current      --tool codex|claude --session ID [--scope NODE] [--json]
operator-host bind         --tool codex|claude --session ID --scope NODE [--json]
operator-host tick         --tool codex|claude --session ID --scope NODE
                           [--max-actions N] [--dry-run] [--json]
operator-host goal-context --tool codex|claude --session ID --scope NODE [--json]
operator-host effect-commit --tool codex|claude --session ID --scope NODE
                            --idempotency-key HASH --lease-id ID
                            --fence N --name NAME [--json]
```

`bind` reads a locked graph snapshot, resolves the node's single `assigned-to`
lane, and selects exactly one currently valid signed lane or host binding whose
lease scope and configured tool match that assignment. It does not accept an
actor-binding or proof-key selector from the caller. It also verifies that the
configured worktree is on its assigned branch. Before it creates the initial
record, it walks the kernel process ancestry and requires the exact vetted
Codex or Claude executable selected from trusted host policy. A reparented
process cannot establish a first-use binding merely by guessing a session ID;
there is no trust-on-first-use path.

The resulting record is stored mode 0600 beneath:

```text
OPERATOR_DIR/host/sessions/<tool>/<sha256(session-id)>.json
```

The record fixes the tool, original session ID, graph/node, actor-binding
generation and hash, proof-key ID, holder scope, lane node, worktree, branch,
and a lane/node-specific external handoff directory. It also records the
kernel process identity (PID, owner, executable, and start time) of the durable
invoking session. `open`, `current`, `tick`, `goal-context`, and
`effect-commit` require that identity in the caller ancestry and revalidate the
signed actor binding. Copying strings or a binding file into an unrelated,
reparented process therefore cannot authenticate the session. Internal loop
wrappers use a separate random, single-tick credential. Rebinding is rejected
while the previous binding owns an active graph lease.

Two host sessions therefore have distinct durable scope even when they use the
same executable or human-visible title.

## The four RM-0003 trusted interfaces

For each tick the host creates four private, short-lived executable wrappers
and gives their absolute paths to `operator-loop.sh`:

| Loop variable | Host operation | Contract |
| --- | --- | --- |
| `OPERATOR_LOOP_SNAPSHOT_COMMAND` | locked `operator-graph snapshot` delivery | exact successful graph envelope |
| `OPERATOR_LOOP_CLOCK_COMMAND` | graph runtime's host/boot monotonic source | one `operator.scheduler-clock/v1` record |
| `OPERATOR_LOOP_MUTATION_COMMAND` | session-fixed mutation launcher and proof broker | exact graph mutation result or error |
| `OPERATOR_LOOP_RUNNER_COMMAND` | Codex or Claude restricted runner | one `operator.runner-result/v1` record |

Each wrapper contains only its interface name and a random per-tick relay
credential. It contains no proof key, host session credential, or root
descriptor. The persistent trusted relay is bound to the tool, session, node,
invocation, and exact held root capabilities before launchd submission. The
wrappers execute with an empty inherited environment plus a pinned system path
and are deleted after the supervised tick. Inputs and outputs are bounded. The
runner receives only `PATH`, `HOME`, `TMPDIR`, and fixed locale variables; it
reconstructs policy from the private host record, never from lane-controlled
environment values.

On macOS, launchd does not carry the caller's arbitrary file descriptors into
the submitted job. Before submission the parent therefore starts one private
per-tick interface relay with the already-held root, authority, graph,
bindings, host, fixed-leaf, selected-binding, and binding-manifest
capabilities. The relay requires `exclusive-held` mode and never calls
`flock` or unlocks that shared open-file description. Launchd descendants send
canonical bounded requests through a random-token relay directory whose exact
device/inode is embedded in each private wrapper; clients open and retain that
directory no-follow and perform descriptor-relative atomic request/response
I/O. The relay persists across snapshot, clock, mutation, and runner calls, so
an authorized mutation can validate and refresh its mutable graph leaves for a
later interface call without a pathname reattach. Parent teardown terminates
the relay before releasing the root transaction lock. A dedicated monitor
blocks on the inherited parent-lifetime pipe even while an interface request is
running. Parent EOF atomically revokes new child launches, kills every tracked
separate child group plus the relay group, and thereby closes all duplicated
root, graph, binding, and proof capabilities. Each client also retains the
exact single-link liveness leaf and requires the relay's exclusive lock while
polling, reading, and accepting a response; relay death therefore refuses
promptly instead of waiting for the runner timeout or accepting late output.

Snapshot delivery is trusted because lanes cannot invoke graph maintenance
through a writable graph path. Although `snapshot` is semantically read-only,
the host retains the filesystem permission needed for RM-0007 lock recovery,
tail truncation, or roll-forward. Lane sandboxes receive only delivered JSON.

The clock adapter calls the same RM-0007 platform implementation used by graph
transactions: Linux `/proc/uptime` or macOS `mach_continuous_time`. It never
constructs a clock from wall time, snapshot timestamps, or lease expiry.

## Mutation and proof brokerage

The mutation adapter accepts only the exact
`operator.loop-mutation-request/v1` fields and only `acquire`, `renew`,
`release`, and leased `transition`. The request graph and node must equal the
durable session scope. It supplies the actor binding and holder scope from host
policy, then creates a fresh Unix stream socket pair for that one graph command.

The graph endpoint receives one descriptor through `--proof-fd`. The other
descriptor belongs to a new isolated `operator-proof-broker.sh` process. The
broker independently reloads the session record and signed actor binding,
fixes one proof key and graph node, and enforces:

1. exactly one canonical newline JSON `authorize` challenge;
2. a matching `operator.mutation-proof-request/v1` for the fixed binding,
   node, command, holder scope, and CAS revision;
3. zero or one subsequent `event` challenge;
4. an event whose request, intent, CAS, actor generation/hash, and proof key
   match the authorized phase;
5. client write-side shutdown immediately after the event challenge and before
   the broker releases the append-enabling event proof.

Wrong session, copied binding, caller-selected binding, wrong key, changed key,
cross-node or cross-lane intent, duplicate/reordered phase, extra record, and
socket replay all fail closed before a graph append. In particular, the broker
waits for EOF before signing the event, so a delayed third record is rejected
without returning an event proof. Authorize-only EOF remains valid for exact
retries and other no-append graph outcomes.

The host does not trust a successful graph child response by itself. Before
launch it retains the exact committed journal and fixed authority capability.
After a zero-status mutation it acquires the descriptor-anchored production
graph lock, parses the exact result envelope, and requires the request's one
matching event to be the journal tail with the expected action, intent, CAS,
actor binding, revision, and result. It then replays the full journal under the
held authority, opens the newly published definition and projection as
unadopted candidates, and requires their canonical bytes to equal that replay.
The journal inode, bytes, and digest must remain stable through this check.
Only then may the host replace its retained definition/projection capabilities.
Restoring an old pathname after commit, substituting a shadow materialization,
or rewriting the same journal inode fails closed. A nonzero graph outcome must
leave the original definition, projection, journal identities, and bytes
unchanged.

Production proof brokerage supports two proof providers. The ordinary host
loop reads one RSA private exponent from the operating-system keychain into
the isolated broker process. The installed design-flow broker may use that
same provider, or it may delegate signing to the supported external provider
described below. On macOS the generic-password service is
`agent-operator-kit.proof-key` with the proof-key ID as account. On Linux the
Secret Service lookup attributes are `service` =
`agent-operator-kit.proof-key` and `key-id` = the proof-key ID. The keychain
secret is a canonical JSON record (or base64url encoding of that record):

```json
{"d":"<hex>","keyId":"proof-key-id","n":"<hex>","schemaVersion":"operator.proof-key/v1"}
```

The modulus must equal the signed binding's public modulus. Missing provider,
missing key, mismatch, malformed response, unavailable broker, timeout, or
signing failure returns `BROKER_UNAVAILABLE` without graph mutation. RM-0005
does not provision a credential or provider and never writes user-global
files. Trust anchor, signed-binding, and proof-provider provisioning remain an
integration/control-plane responsibility.

### Supported external design proof provider

An installation may configure an external signer for design-flow mutations by
placing this exact canonical record at
`OPERATOR_DIR/host/design-proof-signer.json`:

```json
{"command":"/absolute/path/to/operator-design-proof-provider","schemaVersion":"operator.design-proof-signer/v1"}
```

The command is a production proof-provider boundary, not a test hook. It must
be an owned, single-link, non-group/world-writable executable physically
outside the installed repository/worktree and `OPERATOR_DIR`; the provider is
responsible for protecting its private key,
for example behind an HSM, agent, or separately reviewed key service. It reads
one canonical `operator.proof-sign-request/v1` record from standard input and
must return exactly one canonical `operator.proof-sign-response/v1` record.
The response proof-key ID and RSA signature must match the signed actor
binding and exact broker payload.

The broker traverses the configured absolute command with descriptor-relative
no-follow opens; every intermediate component must be a real directory. It
holds the installed repository root and Operator root identities and rejects
the signer as `BROKER_UNAVAILABLE` if any traversed ancestor matches either
`(st_dev, st_ino)`. The executable must retain `st_nlink == 1` at initial open,
each descriptor read, and every reopen/rebind check, preventing an apparently
external pathname from aliasing a hard-linked inode inside either forbidden
root. These checks occur before provider execution or an authorization proof
can enable graph mutation.

After placement validation, the broker pins the leaf device/inode and content
hash and executes an exact private snapshot of the held descriptor. The
snapshot is the portable immutable wrapper used on macOS, where a script
cannot reliably execute via `/dev/fd/N`. The broker live-bounds stdout and
stderr to 4096 bytes, kills a provider that exceeds the bound or ten-second
deadline, rejects additional or noncanonical output, verifies the returned
signature itself, and then reopens/re-hashes the configured command before
accepting it. Forbidden containment, hard-link aliases, pathname replacement,
in-place content replacement, timeout, over-output, and invalid signature all
fail closed before graph append.

Private keys never cross the Operator Kit boundary into a repository,
worktree, task packet, `OPERATOR_DIR`, environment variable, command-line
argument, graph process, log, result, or handoff. Installed entrypoints reject
test mode, fake signer/runner,
scheduler, script-directory, interface-command, configuration, and runtime
overrides. Hostile tests inject fakes only into an in-process module instance.

## Restricted Codex and Claude runners

Immediately before launch, the host obtains a fresh trusted snapshot and binds
the request's exact node ID, title, kind, scheduler claims, lease ID, fence,
actor binding, holder scope, lane node, expiry, monotonic source, host, boot,
and fence tombstone. It repeats the live-lease check after execution. A changed
snapshot or expired lease makes the result stale even if the old process exits
successfully.

The native runner tool sandbox grants write access only to:

- the assigned worktree; and
- one fence-specific directory beneath the session's lane/node handoff area.

Other worktrees, other handoffs, graph/runtime state, signed bindings,
authority state, broker state, keychain operations, and network remain outside
runner tool authority. The host does not use a caller-selected sandbox profile.
If the native boundary cannot be applied, launch fails closed.

The native sandbox capability check runs both while binding and immediately
before each production launch. Claude additionally requires a successful
installed credential preflight; an installed but logged-out CLI is treated as
`RUNNER_UNAVAILABLE` rather than falling back to a weaker runner.

Codex uses its native non-interactive boundary with approval policy `never`,
the `workspace-write` sandbox, the assigned worktree as `-C`, only the exact
run handoff as an added directory, ignored user configuration/rules, an empty
shell inheritance policy, and ephemeral state. App, browser, and computer
features are disabled. Claude uses safe mode, `dontAsk`, native sandbox
settings that reject unsandboxed commands and sockets, no persistence, no MCP
servers, and only Read/Edit/Write/Glob/Grep; shell, web, task, agent, and
computer tools are denied. Neither path uses any approval, permission, or
sandbox bypass switch. Shipped defaults use the same restricted policy.

Both adapters require structured `succeeded|failed` output. The host injects
the leased run/node/lease/fence identities into the final
`operator.runner-result/v1` record and rejects malformed, mismatched, or
oversized results. A success is accepted only while the same lease and fence
remain current.

Claude's durable binding belongs to the top-level Claude session. Subagents and
hooks may return evidence or ask that the top-level session request another
tick. They cannot bind or lease a graph node, change priority, decide a gate,
integrate, or cross the top-level scope.

## Descendant supervision and external-effect fences

On macOS the host submits the trusted loop as a launchd job and validates the
wrapper's kernel PID start identity before teardown. Launchd reaps the ordinary
job process group. A runner descendant that double-forks, calls `setsid`, and
is reparented may outlive that group, but it retains the native runner kernel
sandbox and therefore remains unable to reach graph/bindings/keychain/network,
other roots, or an effect ledger. An abnormal loop/runner parent exit is always
reported as `HOST_SUPERVISION`, with the launchd and inherited-sandbox outcomes
identified. If launchd is unavailable, the tick fails closed. Hostile smoke
records the exact surviving PID/start identity, proves the inherited denials,
then kills only that identity after evidence collection.

Worktree and per-fence handoff output are drafts until ordinary Operator review
and graph-gated integration. Any separately committed external effect must use
`effect-commit`. That endpoint recomputes the stable RM-0003 idempotency key,
requires the exact caller-supplied lease ID, current fence/tombstone, holder,
and live trusted monotonic epoch, and holds the RM-0007 graph store lock across
final validation and descriptor-anchored effect recording. Fence advancement
therefore cannot race the commit. An identical name/payload is an exact retry;
a changed payload is `EFFECT_CONFLICT`. Once fence 2 exists, fence 1 cannot
commit even if its sandbox-contained process survived.

Host mutation and effect commits also hold an exclusive flock on the pinned
`OPERATOR_DIR` descriptor before opening their existing leaf lock. This is the
shared stopped-writer boundary used by V4-to-V5 migration: migration holds the
same root transaction lock plus descriptor-bound parent/leaf locks, so a
renamed replacement lock file cannot create a second host commit domain while
migration owns the workspace.

## Filesystem and configuration trust

Host session, binding, broker, handoff, invocation, and effect paths are opened
by descriptor-relative, no-follow traversal from a pinned Operator root.
Directories and private files must be owned by the effective user, must have
the expected type and 0700/0600 modes, and must have one link where applicable.
The root inode is checked again after operations. Symlink, hard-link, directory
swap, leaf replacement, and rename-race attempts fail closed.

Binding discovery is bounded and does not export one descriptor or environment
record per installed binding. At the serialized command-root boundary the host
records at most 10,000 binding names, identities, sizes, and SHA-256 digests in
one canonical `operator.binding-capability-manifest/v1` temporary-file
capability. Each binding is limited to 64 KiB and the aggregate inventory to
8 MiB. A child receives that one held manifest plus the fixed
authority/graph/bindings directory capabilities and only the exact selected
actor-binding leaf descriptor. It validates the manifest before opening a
requested leaf descriptor-relatively and requires its identity, size, content
hash, and stable read to match; there is no first-discovery pathname reopen.
Unrelated binding credentials and historical host files are neither inherited
nor serialized into the environment.

The installed helper finds its sibling `operator.config.env`, requires safe
ownership and mode, and reconstructs Operator/code/lane policy under an empty
environment. Executables resolve through a pinned system path and are checked
for ownership, writability, and executable type. Caller `PATH`, Operator/code
roots, lane configuration, script paths, commands, runtime policy, signer,
runner, scheduler, and test variables are rejected rather than inherited.
The host, one-shot proof broker, V4-to-V5 migration, design-flow, graph, and
feedback Python shell entrypoints remove `PYTHONPATH` and `PYTHONHOME`, replace
caller `PATH` with the fixed system tool path, and invoke pinned
`/usr/bin/python3` with `-E -s` before the first application import. This
blocks Python startup hooks and PATH shims while preserving sibling-module
loading. Host worktree verification
invokes `/usr/bin/git` directly; trusted executable resolution does not consult
the caller's `PATH`.

The installed production design smoke is intentionally a real graph plus real
one-shot design broker plus an external `operator.design-proof-signer/v1`
provider. It is not described as a macOS Keychain end-to-end test. The same
smoke exercises start, human selection, feedback, root replacement refusal,
signer pathname/content replacement, live over-output, extra output, and
timeout without provider-command fixture overrides.

## Goal context

`goal-context` reconstructs an objective from the current graph node. For
Codex it emits a `codex-native-goal` request with `activated:false` and tells the
bound session to use Codex `/goal` or the native goal control. A shell command
cannot activate `/goal`, and this adapter never claims that it did. Claude gets
the same graph objective as scoped prompt context without invented native-goal
semantics.

The graph lease—not a Codex goal, Claude prompt, chat binding, or runner
result—authorizes mutation.
