# Sharing the Operator Codex Plugin

Operator uses two installation layers:

1. the global Codex plugin in `plugins/operator-kit/`; and
2. the explicit project-local runtime installed by `operator-sync.sh`.

The plugin contains skills and compatibility metadata. It never contains a
project's `operator.config.env`, `OPERATOR_DIR`, worktrees, graph journal,
bindings, proof material, or private Keychain identities.

## Install From a Git Marketplace

This repository is a Codex plugin marketplace through
`.agents/plugins/marketplace.json`. After a preview revision has been committed,
pushed, and tagged, install it with:

```bash
codex plugin marketplace add Agent-Operator-Kit/operator-kit --ref <release-tag>
codex plugin add operator@operator-kit
```

Use an immutable release tag for testers. A branch may be used for development,
but it does not provide a reproducible installation.

## Install or Refresh a Local Development Copy

From the source checkout:

```bash
bash scripts/operator-plugin-migrate.sh --dry-run
bash scripts/operator-plugin-migrate.sh
```

The helper prepares `~/.codex/operator-kit-plugin-marketplace`, installs
`operator@operator-kit-local`, and backs up legacy direct Operator skills.
Restart or reopen Codex Desktop after refreshing the plugin.

## Enable a Project

Installing the plugin does not mutate a project. Bootstrap a new project from a
trusted Operator Kit source checkout:

```bash
bash scripts/operator-sync.sh \
  --channel latest \
  --target /path/to/project \
  --bootstrap-if-missing \
  --skip-skills
```

Fresh V5 setup installs the runtime but does not initialize production graph
history or private keys. Create project-specific authority and bindings only
through the reviewed V5 host setup for that project.

`--channel latest` is required for V5 while the default `stable` channel still
points to the V2.1 release line.

## Workspace Preview

Use a separate preview release and restrict it to a tester group before broad
workspace rollout. In Codex workspace plugin settings, import the preview
package, keep its installation policy `AVAILABLE` during the pilot, and share
it only with the selected audience. Workspace sharing is workspace-scoped; use
the Git marketplace route for personal accounts or collaborators outside the
workspace.

## Release Checks

```bash
bash tests/smoke/codex-plugin-package.sh
bash tests/smoke/v3-host-adapters.sh
bash tests/smoke/codex-plugin-migration.sh
git diff --check
```

Do not publish, push, or tag until the preview package and a clean-project V5
bootstrap have passed validation.
