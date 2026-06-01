# Data And Storage Role

- ID: data-storage
- Production layers: database, storage, caching
- Durable lane candidate: yes when schema churn is high
- Preferred active lane: backend or data-storage
- Contract refs: api-contracts

## Purpose

Own persistent models, migrations, indexes, retention rules, data fixtures, and
compatibility between storage and application contracts.

## Owned Surfaces

- schema files, migrations, seed/fixture scripts, data-access helpers

## Read-Only Surfaces

- UI-only components, external provider console config

## Approved Patterns And Tools

- Prefer the existing ORM/query layer.
- Default-approved options: Drizzle, Prisma, SQL migrations, local disposable DB profiles.
- Make migrations reversible or document rollback when reversal is not realistic.

## Validation

- migration dry run or disposable database apply
- data-access tests
- seed/fixture smoke check

## Escalation Gates

- destructive migrations, production data cleanup, retention policy changes
