# Mobile App Role

- ID: mobile-app
- Production layers: frontend, device APIs, auth, release readiness
- Durable lane candidate: yes for mobile-first products
- Preferred active lane: mobile-app or mobile-ui
- Contract refs: mobile-release

## Purpose

Own native app screens, navigation, device permissions, mobile API consumption,
and simulator/device validation.

## Owned Surfaces

- Expo/React Native app code, mobile UI contracts, native permission flows

## Read-Only Surfaces

- backend internals except API contracts, production release credentials

## Approved Patterns And Tools

- Prefer existing mobile stack.
- Default-approved options: Expo, React Navigation/Expo Router, Maestro, EAS profiles.
- Keep staging/production environment assumptions visible in task packets.

## Validation

- typecheck or mobile test command
- simulator smoke or Maestro flow
- screenshot/video evidence for UX-sensitive work

## Escalation Gates

- TestFlight submission, production build profiles, native permission copy changes
