# New Project Setup

For a new project, create the repo first, then install the operator kit.

The preferred scoped layout is:

```text
$HOME/Projects/acme/
  code/
    app/             canonical repo worktree
    app-backend/     optional permanent backend lane
    app-ui/          optional permanent UI lane
  operator/          tasks, handoffs, memory, roadmap, catalog
```

From an empty project root, the sync command can create `code/app` and
initialize git there:

```bash
mkdir -p "$HOME/Projects/acme"
git clone git@github.com:Agent-Operator-Kit/operator-kit.git "$HOME/Projects/operator-kit"
bash "$HOME/Projects/operator-kit/scripts/operator-sync.sh" \
  --target "$HOME/Projects/acme" \
  --bootstrap-if-missing
cd "$HOME/Projects/acme/code/app"
bash scripts/operator-recommend-lanes.sh
```

```bash
mkdir -p "$HOME/Projects/acme/code/app"
cd "$HOME/Projects/acme/code/app"
git init
git checkout -b main

git clone git@github.com:Agent-Operator-Kit/operator-kit.git "$HOME/Projects/operator-kit"
bash "$HOME/Projects/operator-kit/scripts/operator-bootstrap.sh" "$PWD"
bash scripts/operator-recommend-lanes.sh
```

For a Cursor-first project without Codex, use:

```bash
bash "$HOME/Projects/operator-kit/scripts/operator-bootstrap.sh" --profile cursor "$PWD"
bash scripts/operator-recommend-lanes.sh
```

After the first commit, create worker worktrees from `main` using the generated config as the lane map.

The latest bootstrap is V5.2. It derives `operator/catalog/role-map.json` from
the target's `OPERATOR_LANES` and installs a local, feature-scoped dependency
graph. It creates no authority, bindings, private keys, Keychain entries, host
sessions, leases, or background loop.

V5.2 also installs optional advisory model-selection files. It remains off and
creates no live model catalog or policy. During onboarding, ask the user to run:

```bash
bash scripts/operator-model-select.sh setup-guide
```

The user should provide the models and exact thinking settings they can use,
verified capabilities and context limits, task-class quality/token/retry
estimates, policy limits, and any preferred profile or pin. Never request API
keys for these files, and do not enable `recommend` mode without review.

Verify with `operator-role-map.sh validate`, `operator-graph.sh status`, and
`operator-status.sh`. Add `OPERATOR_DIR` to the project's backup plan when its
feature graphs, handoffs, and planning history matter.

For Codex Desktop operation after install, add or refresh the bundled global skills:

```bash
bash "$HOME/Projects/operator-kit/scripts/codex-skills-install.sh"
```

Then reopen Codex Desktop and use:

```text
Use $operator. Show project status.
Use $design-agent. Recommend a design-system starter.
```
