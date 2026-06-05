# High-Risk Operations Role

- ID: high-risk-operations
- Production layers: regulated actions, approvals, audit trails, recovery paths
- Durable lane candidate: yes for domains with irreversible or externally regulated effects
- Preferred active lane: risk-operations or compliance-safety
- Contract refs: architecture-pattern-library

## Purpose

Own high-risk operational boundaries, approval flows, auditability, recovery
plans, and explicit human gates for irreversible or regulated behavior.

## Owned Surfaces

- approval payloads, audit logs, risk rules, recovery flows, privileged actions

## Read-Only Surfaces

- unrelated UI polish, unrelated marketing surfaces, production credentials

## Approved Patterns And Tools

- Prefer fixture-first and sandbox-first workflows.
- Default-approved options: deterministic fixtures, explicit approval records, audit logs.
- Separate recommendation, critique, approval, and action execution.

## Validation

- fixture covering approved and rejected actions
- invariant tests for risk limits and approval gates
- audit-trace sample

## Escalation Gates

- regulated behavior, privileged credentials, irreversible external actions, risk-limit relaxation
