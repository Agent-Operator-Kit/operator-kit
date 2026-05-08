# New Project Setup

For a new project, create the repo first, then install the operator kit.

```bash
mkdir -p "$HOME/Projects/acme/code/app"
cd "$HOME/Projects/acme/code/app"
git init
git checkout -b main

git clone git@github.com:Agent-Operator-Kit/operator-kit.git "$HOME/Projects/operator-kit"
bash "$HOME/Projects/operator-kit/scripts/operator-bootstrap.sh" "$PWD"
```

After the first commit, create worker worktrees from `main` using the generated config as the lane map.

For Codex Desktop operation after install, add the global runtime skill:

```bash
mkdir -p ~/.codex/skills/operator
cp "$HOME/Projects/operator-kit/skills/codex/operator/SKILL.md" ~/.codex/skills/operator/SKILL.md
```

Then reopen Codex Desktop and use:

```text
Use $operator. Show project status.
```
