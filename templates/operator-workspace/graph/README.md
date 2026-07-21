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
over the request and complete event through an inherited `--proof-fd` socket.
Private proof keys never belong in this directory, the repository, environment,
or graph process. Unix mode alone does not confer authority. There are no
production actor/time/proof/fault injection shortcuts.

Use `bash scripts/operator-graph.sh`; never edit graph state or create the lock
directly. Schedulers and runners consume the versioned `status`/`snapshot`
contract, including
reconciliation and execution-start history. `lease sweep` does not authorize a
retry: operator/system/human must journal `lease resolve` first.

Use `validate` for state validation and `replay check` for drift. The 256 MiB
journal has no in-place V1 rotation; stop writers and use reviewed migration
tooling if `JOURNAL_FULL` is reached. Roadmap state remains separate.
