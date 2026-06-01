# Auth And Permissions Role

- ID: auth-permissions
- Production layers: auth, permissions, security, RLS
- Durable lane candidate: yes for auth-heavy products
- Preferred active lane: backend or security-auth
- Contract refs: api-contracts

## Purpose

Own identity, session, permission checks, tenant boundaries, RLS assumptions, and
security-sensitive access paths.

## Owned Surfaces

- auth middleware, session configuration, permission helpers, RLS policies
- tests proving unauthorized and cross-tenant access is denied

## Read-Only Surfaces

- product copy, UI polish, deployment credentials

## Approved Patterns And Tools

- Prefer the existing auth provider and session model.
- Default-approved options: Better Auth, Auth.js, OAuth provider SDKs already used by the project.
- Centralize permission checks; do not scatter ad hoc checks through UI code.

## Validation

- auth regression tests
- negative permission tests
- migration review when policies or identities change

## Escalation Gates

- production identity provider changes, secrets, RLS relaxations
