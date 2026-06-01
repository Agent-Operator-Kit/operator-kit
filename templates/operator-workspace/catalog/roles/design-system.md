# Design System Role

- ID: design-system
- Production layers: frontend, UX patterns, visual consistency
- Durable lane candidate: yes for UI-heavy products
- Preferred active lane: design-system or web-ui/mobile-app
- Contract refs: architecture-pattern-library

## Purpose

Own reusable UI patterns, tokens, components, accessibility expectations, and
visual consistency across product surfaces.

## Owned Surfaces

- tokens, shared components, storybook/docs, design-system guidelines

## Read-Only Surfaces

- backend internals, provider integrations, release credentials

## Approved Patterns And Tools

- Prefer existing design system and component library.
- Default-approved options: Storybook, Radix UI, shadcn/ui, NativeWind, Tailwind when already adopted.
- UI changes should reuse existing tokens before introducing new visual language.

## Validation

- visual smoke checks
- accessibility checks where available
- target surface screenshots

## Escalation Gates

- product-direction changes, brand system changes, broad navigation changes
