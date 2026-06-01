# Mobile Release Role

- ID: mobile-release
- Production layers: CI/CD, mobile distribution, staging/production
- Durable lane candidate: yes when shipping native apps
- Preferred active lane: release
- Contract refs: mobile-release

## Purpose

Own EAS/build profiles, signing assumptions, TestFlight/App Store readiness,
release notes, and device smoke gates.

## Owned Surfaces

- mobile build config, EAS profiles, release checklists, TestFlight notes

## Read-Only Surfaces

- feature implementation unless release fix requires it

## Approved Patterns And Tools

- Default-approved options: EAS Build/Submit, Maestro smoke flows, manual iPhone smoke checklist.
- Use separate staging and production profiles.

## Validation

- build config lint/check
- release checklist
- simulator/device smoke command

## Escalation Gates

- App Store/TestFlight submission, signing credentials, production build promotion
