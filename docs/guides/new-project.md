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

For Codex Desktop operation after install, add or refresh the bundled global skills:

```bash
bash "$HOME/Projects/operator-kit/scripts/codex-skills-install.sh"
```

Then reopen Codex Desktop and use:

```text
Use $operator. Show project status.
Use $design-agent. Recommend a design-system starter.
```
