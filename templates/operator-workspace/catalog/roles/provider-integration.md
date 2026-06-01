# Provider Integration Role

- ID: provider-integration
- Production layers: external APIs, auth, rate limits, jobs, storage
- Durable lane candidate: yes when a provider is core to the product
- Preferred active lane: provider-integrations or backend
- Contract refs: provider-integration

## Purpose

Own external-provider integration contracts such as OAuth, webhooks, imports,
rate limits, retries, provider fixtures, and provider-specific edge cases.

## Owned Surfaces

- provider adapters, OAuth/token flows, webhook handlers, import jobs, fixtures

## Read-Only Surfaces

- unrelated UI, production provider console settings, secrets

## Approved Patterns And Tools

- Prefer official provider SDKs only when they are maintained and match project needs.
- Default-approved options: `undici`/fetch wrappers, `zod` response validation, `nock`/MSW fixtures, idempotent jobs.
- Persist provider raw IDs and replay-safe import checkpoints.

## Validation

- provider fixture import
- token refresh or auth regression
- webhook replay/idempotency test

## Escalation Gates

- provider app settings, production credentials, webhook URL changes, rate-limit policy changes
