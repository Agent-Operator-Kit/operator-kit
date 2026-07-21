# Operator V5 Control Graph

This directory contains signed bindings plus the definition, append-only
journal, deterministic projection, and transient `.lock`. The control-plane
public trust anchor lives separately at
`../authority/control-graph-public-key.json`; its private key must never be in
the workspace or a lane environment, and the anchor must be outside bypass
lane write scope.

Binding files are untrusted until their RS256 signature, project/graph scope,
validity window, generation, and caller proof verifier validate. They are not
bearer credentials: every mutation needs a matching keychain/broker signature
over the request and complete event through a fresh inherited `--proof-fd`
socket. The trusted host broker selects the key from launcher/session policy,
not from a CLI binding label or `proofKeyId` alone. The wire exchange is strict
newline-delimited one-shot `authorize` and optional subsequent `event`, at most
one request and response per phase, one mutation per connection, with one fixed
proof key. Authorize-only EOF is valid when a retry or post-authorization check
produces no append; EOF before a requested response or mid-record, a reordered
or duplicate phase, or any record after event is invalid.
Private proof keys never belong in this directory, the repository, environment,
or graph process. Unix mode alone does not confer authority. There are no
production actor/time/proof/fault injection shortcuts.

Production mutations are disabled until RM-0003/RM-0005 provide that isolated
broker and launch lanes without permission bypass, with graph state, bindings,
the anchor, and runtime outside the lane's writable sandbox.

Signed payload bytes use `Operator Canonical JSON v1`: recursively code-point-
sorted object keys, array order preserved, integer-only numbers, compact JSON,
unescaped accepted Unicode encoded as UTF-8, and exactly one trailing LF. RS256
signs the canonical payload only, not its challenge envelope. Authorization is
permission to attempt; event proof approves a candidate but is not a commit
acknowledgement. The successful graph result plus replay/snapshot is commit
evidence.

Use `bash scripts/operator-graph.sh`; never edit graph state or create the lock
directly. Schedulers and runners consume the versioned `status`/`snapshot`
contract, including
reconciliation and execution-start history. `lease sweep` does not authorize a
retry: operator/system/human must journal `lease resolve` first.
Although status/snapshot are semantic reads, they take the transaction lock and
may recover a partial journal tail or roll committed state forward. Sandboxed
lanes receive snapshot output from the trusted host and are not granted graph
directory write access.

Use `validate` for state validation and `replay check` for drift. The 256 MiB
journal has no in-place V1 rotation; stop writers and use reviewed migration
tooling if `JOURNAL_FULL` is reached. Roadmap state remains separate.
