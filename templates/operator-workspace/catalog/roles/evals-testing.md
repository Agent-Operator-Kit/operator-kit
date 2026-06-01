# Evals And Testing Role

- ID: evals-testing
- Production layers: CI/CD, quality, regression safety
- Durable lane candidate: yes for complex products
- Preferred active lane: evals or release
- Contract refs: architecture-pattern-library

## Purpose

Own deterministic validation, regression suites, fixtures, eval harnesses, and
evidence that task acceptance criteria are actually met.

## Owned Surfaces

- Playwright, Maestro, unit/integration tests, eval fixtures, smoke scripts

## Read-Only Surfaces

- production secrets, provider consoles, unrelated implementation areas

## Approved Patterns And Tools

- Prefer existing test runner.
- Default-approved options: Playwright, Maestro, Vitest/Jest, pytest, MSW, seed fixtures.
- Use disposable agent/e2e data profiles for automation.

## Validation

- focused regression command
- artifact path for screenshots/logs
- failure reproduction notes

## Escalation Gates

- destructive resets against human local data, production data tests
