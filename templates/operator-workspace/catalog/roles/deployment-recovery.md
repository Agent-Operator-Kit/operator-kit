# Deployment And Recovery Role

- ID: deployment-recovery
- Production layers: hosting, deployment, CI/CD, availability, recovery
- Durable lane candidate: yes
- Preferred active lane: release
- Contract refs: mobile-release, observability

## Purpose

Own deployment workflows, environment separation, CI/CD, rollback, release
readiness, and recovery playbooks.

## Owned Surfaces

- deployment config, CI workflows, release scripts, runbooks, environment docs

## Read-Only Surfaces

- feature implementation details outside release gates

## Approved Patterns And Tools

- Prefer existing host and CI.
- Default-approved options: GitHub Actions, Docker, Railway/Vercel/Fly/Render as project-selected hosts.
- Keep staging and production gates explicit.

## Validation

- CI dry run or workflow lint
- smoke checklist
- rollback note for release-impacting changes

## Escalation Gates

- deploys, production env vars, release submission, rollback execution
