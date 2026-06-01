# API Contracts Role

- ID: api-contracts
- Production layers: APIs and backend logic, auth, database contracts
- Durable lane candidate: yes
- Preferred active lane: backend or api-contracts
- Contract refs: api-contracts

## Purpose

Own backend API shape, request/response contracts, service boundaries, and
schema compatibility with clients and workers.

## Owned Surfaces

- API routes, handlers, service contracts, OpenAPI or typed-contract files
- backend validation schemas and server-side integration tests

## Read-Only Surfaces

- client UI flows, mobile screens, release scripts, provider consoles

## Approved Patterns And Tools

- Prefer the existing project API framework.
- Default-approved options: OpenAPI, `openapi-typescript`, `zod`, `msw`, `supertest`.
- Keep client contracts generated or typed from one source of truth.

## Validation

- API/unit test command
- contract generation or typecheck
- client compatibility check when contracts change

## Escalation Gates

- auth/session behavior, breaking response shape, destructive data migration
