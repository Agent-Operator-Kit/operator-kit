# Trading And Risk Role

- ID: trading-risk
- Production layers: broker integration, portfolio, risk, approvals
- Durable lane candidate: yes for investing/trading products
- Preferred active lane: trading-agents or risk-trading
- Contract refs: architecture-pattern-library

## Purpose

Own broker boundaries, portfolio/risk constraints, order construction, approval
flows, and live-money safety gates.

## Owned Surfaces

- broker adapters, risk rules, paper/live separation, approval payloads, audit logs

## Read-Only Surfaces

- marketing UI, unrelated mobile polish, production broker credentials

## Approved Patterns And Tools

- Prefer paper-trading and fixture-first workflows.
- Default-approved options: broker SDK only behind a project adapter, deterministic risk fixtures, audit logs.
- Separate signal generation, risk critique, portfolio constraint, and action prep.

## Validation

- paper-trading fixture
- risk invariant tests
- audit-trace sample

## Escalation Gates

- live-money behavior, broker credentials, order submission, risk-limit relaxation
