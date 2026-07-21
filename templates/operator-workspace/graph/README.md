# Operator V5 Control Graph

This directory contains signed bindings plus the definition, append-only
journal, deterministic projection, and transient `.lock`. The control-plane
public trust anchor lives separately at
`../authority/control-graph-public-key.json`; its private key must never be in
the workspace or a lane environment, and the anchor must be outside bypass
lane write scope.

Binding files are untrusted until their RS256 signature, project/graph scope,
validity window, and generation verify. Unix mode alone does not confer
authority. There are no production actor/time/fault injection flags.

Use `bash scripts/operator-graph.sh`; never edit graph state or create the lock
directly. Schedulers and runners consume `status`/`snapshot`, including
reconciliation and execution-start history. `lease sweep` does not authorize a
retry: operator/system/human must journal `lease resolve` first.

Use `validate` for state validation and `replay check` for drift. The 256 MiB
journal has no in-place V1 rotation; stop writers and use reviewed migration
tooling if `JOURNAL_FULL` is reached. Roadmap state remains separate.
