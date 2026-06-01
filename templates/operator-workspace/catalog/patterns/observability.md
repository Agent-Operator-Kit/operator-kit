# Observability Pattern

- ID: observability
- Applies to roles: observability, deployment-recovery, api-contracts
- Default status: candidate-approved

## Use When

- adding logs, traces, metrics, health checks, alerting, or incident runbooks

## Approved Packages And Repos

- Sentry when the project uses it for error tracking
- OpenTelemetry when traces or metrics need vendor-neutral propagation
- Existing platform logging before adding a new service
- Reference repos: `github.com/getsentry/sentry-javascript`, `github.com/open-telemetry/opentelemetry-js`, `github.com/pinojs/pino`

## Consistency Rules

- Structured logs should include correlation context.
- Do not log secrets, tokens, personal health data, or live-money sensitive details.
- Health checks should distinguish app, dependency, and database status when possible.

## Validation

- healthcheck command
- log or trace sample
- redaction review for sensitive fields
