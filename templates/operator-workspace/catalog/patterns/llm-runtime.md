# LLM Runtime Pattern

- ID: llm-runtime
- Applies to roles: llm-runtime, knowledge-base, evals-testing
- Default status: candidate-approved

## Use When

- prompts, model providers, tool calls, retrieval, or evals are changing

## Approved Packages And Repos

- OpenAI SDK when OpenAI is the selected provider
- Vercel AI SDK when the project already uses it
- Langfuse or OpenTelemetry when trace infrastructure is present
- Reference repos: `github.com/openai/openai-node`, `github.com/vercel/ai`, `github.com/langfuse/langfuse`, `github.com/open-telemetry/opentelemetry-js`

## Consistency Rules

- Tool schemas must be explicit.
- Prompt/runtime changes need evals or golden cases.
- Provider-specific behavior should sit behind adapters.

## Validation

- focused eval run
- trace sample
- cost/rate-limit note for loops or batch jobs
