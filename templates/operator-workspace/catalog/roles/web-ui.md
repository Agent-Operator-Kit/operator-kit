# Web UI Role

- ID: web-ui
- Production layers: frontend, browser UX, UI contracts
- Durable lane candidate: yes for browser products/admin surfaces
- Preferred active lane: web-ui
- Contract refs: architecture-pattern-library

## Purpose

Own browser-facing screens, admin workflows, UI contract consumption, accessibility,
and Playwright-visible behavior.

## Owned Surfaces

- web app routes, UI components, browser state, Playwright coverage

## Read-Only Surfaces

- backend internals except typed contracts, release credentials

## Approved Patterns And Tools

- Prefer existing frontend framework and component library.
- Default-approved options: React/Vite/Next as project-selected, Playwright, Testing Library.
- Reuse design tokens and shared components before inventing new UI patterns.

## Validation

- typecheck/build
- focused Playwright or browser smoke
- screenshot for visual changes

## Escalation Gates

- navigation IA changes, auth flow changes, broad design-system changes
