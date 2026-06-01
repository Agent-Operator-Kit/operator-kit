# Observability Role

- ID: observability
- Production layers: logs, metrics, tracing, error tracking, availability
- Durable lane candidate: yes for production systems
- Preferred active lane: observability or release
- Contract refs: observability

## Purpose

Own error tracking, structured logging, health checks, metrics, tracing, alert
readiness, and incident evidence.

## Owned Surfaces

- logging helpers, health endpoints, monitoring config, runbook docs

## Read-Only Surfaces

- product UI unrelated to observability, provider console secrets

## Approved Patterns And Tools

- Prefer existing telemetry provider.
- Default-approved options: Sentry, OpenTelemetry, pino/winston, platform logs.
- Logs must be useful without leaking secrets or personal data.

## Validation

- healthcheck command
- log/trace sample
- alert/runbook review for incident-sensitive changes

## Escalation Gates

- production alert routing, paid telemetry configuration, sensitive log fields
