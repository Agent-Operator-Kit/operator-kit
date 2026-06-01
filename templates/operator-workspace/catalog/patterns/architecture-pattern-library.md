# Architecture Pattern Library

- ID: architecture-pattern-library
- Applies to roles: all
- Default status: project-curated

## Use When

- a worker proposes a new package, repo, framework, service, or cross-cutting pattern
- a task touches a subsystem with existing conventions
- consistency matters more than one-off speed

## Approved Packages And Repos

- Add project-approved package and GitHub repo allowlists here.
- Existing project stack is approved by default unless deprecated in this file.
- New packages should include rationale, alternatives considered, and validation.
- Store approved GitHub repo URLs next to packages so agents know which upstream
  project is trusted.

## Consistency Rules

- Prefer existing patterns over new abstractions.
- Make architecture decisions explicit in the task handoff.
- If a pattern becomes recurring, promote it into this catalog.

## Validation

- task-specific checks
- operator review of new dependencies
- dependency/security review for production-impacting packages
