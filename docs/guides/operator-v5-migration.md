# Operator Kit V4-to-V5 Migration

V5 migration is explicit, lossless, and fail-closed. A normal latest-channel
update installs the V5 scripts, schemas, templates, and adapters but preserves
`OPERATOR_KIT_VERSION="4"`. Only a successful reviewed migration changes that
marker to `5`.

The shell-safe single-quoted form `OPERATOR_KIT_VERSION='4'` is also supported;
plan interprets it as V4 and apply preserves the quote style while changing it
to `'5'`. Other or ambiguous marker forms are refused rather than accepted by
plan and rejected later by apply.

## Safety Boundary

Stop tmux, graph, loop, host, feedback, planning, and other writers. Back up the
repository and the complete external `OPERATOR_DIR` as one recovery set. The
workspace is durable: V4 features, tasks, handoffs, roadmap, memory, catalog,
V5 graph history, lease fences, signed bindings, and host effect ledgers must
not be discarded or reconstructed.

`OPERATOR_DIR` must be a real user-owned directory outside the repository. The
migrator uses the pinned `/usr/bin/python3` interpreter and refuses symlinks,
interchanged roots or path components, hard-linked files, ambiguous config
assignments, active lock/session evidence, partial or replay-incompatible graph
state, and unavailable broker/keychain tooling. Config, mapping, legacy,
manifest, and marker I/O is rooted in held directory descriptors and traversed
without following symlinks. Private authority or proof keys must never be copied
into the repo, `OPERATOR_DIR`, a mapping, environment variable, CLI argument,
task packet, log, or handoff.

## 1. Update Without Migrating

```bash
bash /path/to/operator-kit/scripts/operator-sync.sh \
  --source /path/to/operator-kit \
  --channel latest \
  --target /path/to/project \
  --skip-skills \
  --no-fetch
```

Confirm status says version `4` and `migration required`. The update may create
empty private V5 runtime directories, but it does not create graph history,
bindings, keys, host sessions, or proof material.

If the V4 config points `OPERATOR_DIR` at the repository or one of its
descendants, latest update still refreshes project-local scripts and preserves
the V4 marker, but it creates no V5 `authority`, `graph`, `host`, `loop`,
`migrations`, or prompt state there. Update and status report
`relocation/migration blocked`. Relocate the complete durable Operator workspace
outside the repository, update the config, and rerun update before planning
migration.

## 2. Produce And Review A Plan

`plan` and `--dry-run` are read-only. They inventory and checksum config,
features, tasks, handoffs, roadmap, memory, and catalog, and emit a mapping
template on stdout.

```bash
bash scripts/operator-v5-migrate.sh plan > /secure/review/v5-plan.json
# equivalent
bash scripts/operator-v5-migrate.sh --dry-run
```

Copy only `mappingTemplate` into a separate reviewed mapping file. Set
`reviewed` to `true`, record a reviewer and UTC `reviewedAt`, and leave
`inventoryDigest`, `projectRoot`, and `operatorDir` unchanged. An empty
`selectedUnfinishedScopes` list is valid and does not initialize a graph.

Canonicalize the mapping before review, then review and retain those exact
UTF-8 bytes. Apply requires sorted object keys, compact separators, unescaped
Unicode, and one trailing newline—the same canonical encoding emitted by the
plan command. It rejects alternate whitespace or key order, duplicate or
unknown fields, floats and noncanonical numeric tokens, constants, invalid
controls, and wrong field types instead of normalizing them. The manifest
records the SHA-256 of the exact reviewed mapping bytes, not a reparsed Python
value. Do not edit or reformat the mapping after approval; produce and review a
new canonical file when any selection or review field changes.

If unfinished V4 work should be represented in V5, control must first create a
reviewed graph definition and initialize it through the trusted signed
host/graph API. Put only those already-provisioned stable graph node IDs in
`selectedUnfinishedScopes`. The migrator validates those IDs; it never converts
V4 files into nodes or writes graph definition, projection, events, authority,
bindings, or keys.

## 3. Apply Explicitly

```bash
bash scripts/operator-v5-migrate.sh apply \
  --mapping /secure/review/v5-mapping.json \
  --authorize MIGRATE_V4_TO_V5
```

Apply first acquires a private migration-wide exclusive lock, then acquires the
production graph runtime's own `graph/.lock` directory-lock protocol, and holds
both over stopped-writer checks, inventory, graph/scope validation, manifest
commit, and marker commit. Acquiring this protocol creates only its temporary
owner record and does not initialize graph definition, projection, events,
bindings, or authority state. Migration holds the original graph-directory and
lock-directory descriptors for acquisition, owner writes, heartbeat,
verification, and release. Root, graph, or lock replacements are refused; no
replacement pathname is followed or recursively deleted, and only the held
lock inode may be cleaned. Live legacy, graph, loop, host, tmux, and concurrent-
migration locks refuse the operation. A newly created migration lock is
initialized privately; a safe existing migration-lock inode is opened and
flocked without chmod, truncation, replacement, or other metadata normalization.
The migration-wide lock and every discovered writer lock are held as a complete
descriptor binding: the lock file descriptor and dev/inode, its held parent
directory descriptor and dev/inode, and the published no-follow leaf beneath
that parent. Migration takes an exclusive parent-directory flock before opening
the leaf and also holds the descriptor-anchored `OPERATOR_DIR` transaction
flock. Host mutation/effect commits participate in that root transaction
protocol; loop and graph retain their production directory protocols. A second
migrator or participating writer therefore cannot turn a replacement pathname
into an independent commit domain. Parent and leaf identities, published lock
topology, root identity, tmux state, and the graph transaction lock are checked
at every manifest/marker boundary and immediately before release. Ownership
loss never opens, chmods, truncates, unlinks, or otherwise mutates the decoy; if
loss is detected after marker replacement, the descriptor-anchored config
marker is restored to V4 before the root transaction lock is released, leaving
only a validated partial manifest for normal recovery.
Before each durable commit boundary, apply recomputes the graph initialization
state, graph ID, and revision under the held production lock and revalidates
every selected node as present and nonterminal. It also recomputes the exact
legacy inventory, validates any existing graph by signed replay without repair,
and checks broker/keychain tooling. It then writes a private canonical manifest at
`OPERATOR_DIR/migrations/v4-to-v5-manifest.json` containing stable legacy paths,
modes, sizes, checksums, review evidence, and pre/post config checksums. The
manifest file and containing directory are fsynced before the version marker is
replaced; the marker file and its containing directory are then fsynced. The
version marker is the last write. Any failed preflight leaves V4 usable and the
marker unchanged. Partial recovery recomputes the exact recorded inventory and
requires the same graph initialization state, graph ID, and graph revision
recorded by the durable manifest. It also revalidates every selected scope as
present and nonterminal before it may finish the marker commit. An exact rerun
is idempotent and returns `alreadyApplied`.

Completed and partial-recovery manifest ingress uses the same strict canonical
decoder as the reviewed mapping. Recovery refuses noncanonical bytes, duplicate
or unknown fields at every manifest layer, ambiguous numeric forms, controls,
constants, and wrong types before trusting inventory, graph, review, or scope
evidence and before changing the V4 marker.

## 4. Validate And Recover

```bash
bash scripts/operator-status.sh
bash scripts/operator-role-map.sh validate
bash scripts/operator-graph.sh replay check   # only when graph is initialized
```

Do not delete V4 files after migration; the manifest deliberately records them
in place. To recover, stop writers and restore the repository, full
`OPERATOR_DIR`, public anchor, and approved OS-keychain material from the same
recovery point. Never reset a fence, truncate valid graph history, substitute
an anchor, generate replacement production keys, or treat the V4 inventory as
graph truth. If the restored graph cannot pass signed replay, keep writers
stopped and use reviewed control-plane recovery.
