# LLM Runtime Role

- ID: llm-runtime
- Production layers: agent runtime, prompts, model providers, evals
- Durable lane candidate: yes
- Preferred active lane: agents or llm-runtime
- Contract refs: llm-runtime

## Purpose

Own model-provider integration, prompts, tool contracts, traceability, evals, and
behavioral regressions for agentic or LLM-powered features.

## Owned Surfaces

- prompt catalogs, model adapters, tool schemas, eval harnesses, runtime traces

## Read-Only Surfaces

- deployment secrets, UI-only polish, unrelated database migrations

## Approved Patterns And Tools

- Prefer existing provider abstraction.
- Default-approved options: OpenAI SDK, Vercel AI SDK, Langfuse/OpenTelemetry traces where adopted.
- Require evals or golden cases for prompt/runtime behavior changes.

## Validation

- focused eval command
- trace sample
- deterministic fallback or fixture test

## Escalation Gates

- model-provider account changes, cost-sensitive loops, unsafe tool permissions
