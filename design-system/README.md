# Operator design system

Accepted direction: 22 September 2026. Linear and WorkOS inform white surfaces and compact typography; Lemni informs spacing and pane hierarchy. Values are Operator choices, not official exports.

## Foundations

- Inter Variable 4.1 (bundled SIL Open Font License), 400/500/600. Body 14 px; compact rows 13 px; metadata 12 px; titles 22 px.
- Four-pixel spacing scale. Use 24–32 px reading padding, 8–16 px within groups.
- Semantic colors in tokens.json and tokens.dark.json; regenerate CSS with node design-system/build-tokens.mjs.
- Dark theme uses charcoal surfaces and soft white text. Respect host preference unless the user chooses a theme.
- Sidebar can collapse to a 60 px icon rail without losing accessible labels.

## Files

Tokens are the source of truth. components.css and preview.html/preview.js are standalone component specimens with sample data. components.md and typography.md document usage. Production cockpit integrates these foundations in plugins/operator-kit/mcp-server; do not replace live records with specimen fixtures.

## Product rules

Keep project, feature, task and worker attempt distinct. Only show recorded status; missing activity stays unknown. Preserve selected work through refresh. Pair every status color with text. Use actual source records for review and readiness.

## Voice

Use sentence case, clear next actions and readable metadata. Avoid decorative KPI panels, nested card stacks, all-caps labels, tiny type and invented live activity.

## References

- https://linear.app/ai
- https://mobbin.com/explore/screens/449b12bf-bcf8-4352-bc72-31ec95cbd41b
- https://mobbin.com/explore/screens/68aa3af4-c84d-4a60-bffc-8e3935bc4b63

Linear’s public page declares Inter Variable. WorkOS/Lemni screenshots do not establish exact font or CSS values. This package is an adaptation.
