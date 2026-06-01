# Knowledge Base Role

- ID: knowledge-base
- Production layers: data, LLM context, retrieval, evidence
- Durable lane candidate: yes
- Preferred active lane: knowledge-base
- Contract refs: llm-runtime

## Purpose

Own ingestion, normalization, retrieval, claim quality, snapshots, and knowledge
contracts consumed by agents or user-facing product surfaces.

## Owned Surfaces

- ingestion workers, source metadata, retrieval schemas, knowledge snapshots

## Read-Only Surfaces

- general UI polish, release credentials, provider consoles

## Approved Patterns And Tools

- Prefer existing vector/retrieval store.
- Default-approved options: pgvector, SQLite/Postgres-backed snapshots, deterministic ingestion fixtures.
- Store evidence and source attribution, not only generated summaries.

## Validation

- ingestion fixture run
- retrieval/evidence regression
- snapshot diff review

## Escalation Gates

- source licensing, private data ingestion, destructive reindexing
