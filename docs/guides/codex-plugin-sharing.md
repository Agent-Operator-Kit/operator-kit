# Sharing the Operator Codex Plugin

Operator uses two installation layers:

1. the global Codex plugin in `plugins/operator-kit/`; and
2. the explicit project-local runtime installed by `operator-sync.sh`.

The plugin contains skills and compatibility metadata. It never contains a
project's `operator.config.env`, `OPERATOR_DIR`, worktrees, feature graphs, or
handoffs.

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

## Install Into the Personal Marketplace

Workspace sharing starts from the personal marketplace, not the isolated
`operator-kit-local` development marketplace. Copy the validated package into
the personal plugin root:

```bash
rsync -a --delete --exclude='.DS_Store' \
  plugins/operator-kit/ \
  "$HOME/plugins/operator/"
```

Add an `operator` entry to `$HOME/.agents/plugins/marketplace.json` that points
at `./plugins/operator`, then install the personal identity:

```bash
codex plugin add operator@personal-plugins
```

Verify the personal installation before removing or disabling
`operator@operator-kit-local`. Restart the ChatGPT desktop app so the Personal
plugin catalog refreshes.

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

Fresh V5.1 setup installs the local dependency-graph runtime. It creates no
credentials and requires no Keychain setup.

`--channel latest` is required for V5.1 while the default `stable` channel still
points to the V2.1 release line.

## Workspace Preview And Sharing

Use a separate preview release and restrict it to a tester group before broad
workspace rollout. In the ChatGPT plugin directory:

1. Open **Personal**.
2. Find Operator under **Created by me**.
3. Open the plugin's actions or detail page.
4. Use **Share** to invite people or groups, select their access, or copy the
   workspace-scoped link.

OpenAI documentation may describe the initial local-to-workspace promotion as
**Publish**. The access-management dialog presented after promotion is
**Share**. Workspace sharing remains workspace-scoped; use the Git marketplace
route for personal accounts or collaborators outside that workspace.

## Release Checks

```bash
bash tests/smoke/codex-plugin-package.sh
bash tests/smoke/v3-host-adapters.sh
bash tests/smoke/codex-plugin-migration.sh
git diff --check
```

Do not publish, push, or tag until the preview package and a clean-project V5
bootstrap have passed validation.
