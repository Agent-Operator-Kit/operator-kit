# API Contract Pattern

- ID: api-contracts
- Applies to roles: api-contracts, auth-permissions, data-storage
- Default status: candidate-approved

## Use When

- client/server contracts are changing
- workers consume backend service contracts
- schema or response compatibility matters

## Approved Packages And Repos

- `zod` for runtime validation when already compatible with the stack
- `openapi-typescript` for OpenAPI client types
- `msw` or equivalent for client contract fixtures
- Reference repos: `github.com/colinhacks/zod`, `github.com/openapi-ts/openapi-typescript`, `github.com/mswjs/msw`

## Consistency Rules

- One source of truth for public request/response shapes.
- Contract changes must name impacted clients and workers.
- Breaking changes need a migration or compatibility note.

## Validation

- backend tests
- typecheck
- contract generation or client compatibility check
