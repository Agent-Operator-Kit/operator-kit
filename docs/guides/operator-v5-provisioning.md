# Operator V5 Trusted-Host Provisioning

V5 project bootstrap and V4 migration install the runtime but intentionally do
not create cryptographic authority. Provisioning is a separate, explicit
control-plane operation:

```bash
bash scripts/operator-v5-provision.sh plan
bash scripts/operator-v5-provision.sh apply \
  --authorize PROVISION_OPERATOR_V5_AUTHORITY
```

Review the plan before applying it. `apply` refuses non-V5 projects, unsafe or
mismatched role maps, permission-bypass lane invocations, partial graph state,
foreign public artifacts, expired bindings, unsupported platforms, and missing
Keychain/OpenSSL support.

## What It Creates

The explicit apply operation creates:

- one 3072-bit RSA control authority private key in macOS Keychain;
- one independent 2048-bit proof key per signed actor binding in macOS
  Keychain;
- the public authority anchor under
  `OPERATOR_DIR/authority/control-graph-public-key.json`;
- a least-privilege control binding, human-gate binding, and one host binding
  for every durable role-map lane;
- a signed initial graph containing the durable lane nodes and the
  `operator-bootstrap` task assigned to the operator lane.

The authority Keychain service is `agent-operator-kit.authority-key`. Proof
keys use the existing `agent-operator-kit.proof-key` service. Accounts are
public deterministic key IDs scoped to the project, graph, canonical host, and
resolved Operator workspace. Private parameters are passed only in process
memory to Security.framework and never through a file, argument, environment
variable, stdout, stderr, task packet, handoff, repository, or Operator
workspace.

## Recovery And Idempotency

Provisioning is resumable. Keychain entries use put-if-absent semantics, public
files use anchored atomic creation, and the signed graph initialization uses a
stable request ID. A repeat run validates and reuses identical state. It never
silently overwrites a Keychain item, anchor, binding, or initialized graph.

If only some graph materialized files exist, the command fails closed. Recover
the journal/materialized graph as a reviewed control-plane operation before
running provisioning again. Do not delete or replace the public anchor after
history is initialized because the first signed event pins its identity and
hash.

## Validation And Host Binding

After apply:

```bash
bash scripts/operator-role-map.sh validate
bash scripts/operator-graph.sh status
bash scripts/operator-graph.sh replay check
```

The initial session binding still enters through `operator-host.sh` and must be
requested by a process descended from the vetted native Codex or Claude runner:

```bash
bash scripts/operator-host.sh bind \
  --tool codex \
  --session <stable-session-id> \
  --scope operator-bootstrap \
  --json
```

Never weaken the runner peer check, native sandbox policy, or proof broker to
make initial binding convenient. A successful provision operation establishes
cryptographic state; it does not approve a human gate, dispatch work, push,
publish, deploy, or release.
