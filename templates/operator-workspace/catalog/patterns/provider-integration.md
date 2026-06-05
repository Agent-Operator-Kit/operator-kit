# Provider Integration Pattern

- ID: provider-integration
- Applies to roles: provider-integration, auth-permissions, data-storage
- Default status: candidate-approved

## Use When

- integrating external APIs such as health platforms, payment services, CRM systems, or other third-party providers

## Approved Packages And Repos

- Prefer maintained official SDKs only when they do not hide critical contract behavior.
- Use `zod` or equivalent validation for provider responses.
- Use `nock`, MSW, or stored provider fixtures for replayable tests.
- Reference repos: `github.com/colinhacks/zod`, `github.com/nock/nock`, `github.com/mswjs/msw`

## Consistency Rules

- Provider adapters should expose project-owned contracts.
- OAuth/token refresh must be testable without production credentials.
- Imports and webhooks must be idempotent and replay-safe.
- Rate limits, retries, and backoff belong in the contract.

## Validation

- fixture import
- token refresh/auth test
- webhook replay/idempotency check
