# Starter Selection

Use a curated starter before going custom.

## Starters

| Starter | Best For | Avoid When |
| --- | --- | --- |
| `shadcn-radix-tailwind` | Founder-built SaaS, internal tools, React/Next/Vite, owned component source | Team wants one packaged vendor library or is not Tailwind-compatible |
| `material-ui` | Broad React apps, mature component library, Material Design fit | Product needs distinct bespoke identity immediately |
| `ant-design` | Enterprise admin, dense dashboards, tables, forms, workflows, i18n | Consumer/editorial/lightweight branded experiences |
| `mantine` | Pragmatic SaaS dashboards and broad React components | Team already standardized on shadcn or MUI |
| `chakra-ui` | Accessible React products and component-system reference | Tailwind-first projects or shadcn-owned component preference |

## Selection Criteria

- Product type.
- UI density.
- Brand distinctiveness.
- Stack and package manager.
- Existing component library.
- Ownership model: copy-owned source vs dependency.
- Accessibility/regulatory needs.
- Speed vs long-term design-system maturity.

## Required Recommendation Format

```markdown
# Starter Recommendation

## Recommended Starter

## Why This Fits

## Tradeoffs

## Rejected Starters

| Starter | Why rejected |
| --- | --- |

## Adaptation Plan

1. Normalize token source.
2. Rewrite semantics for the product.
3. Add voice and caveats.
4. Create product kits.
5. Validate one screen.
```

