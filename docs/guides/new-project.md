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

The latest bootstrap is V5. It derives `operator/catalog/role-map.json` from
the target's `OPERATOR_LANES`, installs all eleven schemas and V5 runtimes, and
creates private external runtime directories. It does not create graph events,
definitions, projections, signed bindings, authority keys, proof keys, or host
sessions. Control must provision the public anchor, signed bindings, and OS
keychain proof material, then initialize graph state only through the trusted
host/graph API.

After provisioning, verify with `operator-role-map.sh validate`,
`operator-graph.sh status`, and a bound `operator-host.sh current`. Never use a
permission-bypass runner or place private keys in the repo or external
workspace. Add `OPERATOR_DIR` to the project's backup and recovery plan.

For Codex Desktop operation after install, add or refresh the bundled global skills:

```bash
bash "$HOME/Projects/operator-kit/scripts/codex-skills-install.sh"
```

Then reopen Codex Desktop and use:

```text
Use $operator. Show project status.
Use $design-agent. Recommend a design-system starter.
```
