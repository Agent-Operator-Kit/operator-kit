# Mobile Release Pattern

- ID: mobile-release
- Applies to roles: mobile-app, mobile-release, deployment-recovery
- Default status: candidate-approved

## Use When

- mobile build profiles, native permissions, TestFlight, app release, or simulator smoke changes

## Approved Packages And Repos

- Expo/EAS when project uses Expo
- Maestro for deterministic native flows
- Playwright only for companion web/admin surfaces
- Reference repos: `github.com/expo/expo`, `github.com/mobile-dev-inc/maestro`, `github.com/microsoft/playwright`

## Consistency Rules

- Separate staging and production build profiles.
- Keep release notes and smoke evidence with the task.
- Never use agent automation against the human's persistent local data unless explicitly approved.

## Validation

- mobile typecheck/build command
- simulator or device smoke
- release checklist for submission-affecting changes
