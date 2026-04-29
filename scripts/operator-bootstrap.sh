#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_REPO="${1:-}"

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-bootstrap.sh /path/to/repo

Installs Agent Operator Kit scripts/templates into an existing git repository.
USAGE
}

if [ -z "$TARGET_REPO" ]; then
  usage >&2
  exit 1
fi

TARGET_REPO="$(cd "$TARGET_REPO" && pwd)"
if ! git -C "$TARGET_REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
  printf 'Target is not a git repository: %s\n' "$TARGET_REPO" >&2
  exit 1
fi

repo_root="$(git -C "$TARGET_REPO" rev-parse --show-toplevel)"
repo_name="$(basename "$repo_root")"
code_dir="$(dirname "$repo_root")"
project_root="$(dirname "$code_dir")"
default_branch="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
[ -n "$default_branch" ] || default_branch="$(git -C "$repo_root" branch --show-current)"
[ -n "$default_branch" ] || default_branch="main"

mkdir -p "$repo_root/scripts" "$project_root/operator/tasks" "$project_root/operator/captures"
mkdir -p "$repo_root/.claude/commands" "$repo_root/.claude/agents"

for script in operator-lib.sh operator-tmux.sh operator-status.sh operator-task.sh operator-dispatch.sh operator-collect.sh operator-summary.sh; do
  cp "$KIT_ROOT/scripts/$script" "$repo_root/scripts/$script"
  chmod +x "$repo_root/scripts/$script"
done

if [ ! -f "$repo_root/operator.config.env" ]; then
  cat > "$repo_root/operator.config.env" <<EOF
PROJECT_NAME="$repo_name"
PROJECT_ROOT="$project_root"
CODE_DIR="$code_dir"
OPERATOR_DIR="$project_root/operator"
TMUX_SESSION="$repo_name"
DEFAULT_BRANCH="$default_branch"

OPERATOR_LANES='
operator|Codex Desktop|$repo_name|$default_branch|
backend|Codex CLI|$repo_name-backend|codex/backend|codex --dangerously-bypass-approvals-and-sandbox
ui|Claude Code|$repo_name-ui|claude/ui|claude --dangerously-skip-permissions --permission-mode bypassPermissions
'
EOF
fi

if [ ! -f "$repo_root/AGENTS.md" ]; then
  cp "$KIT_ROOT/templates/repo/AGENTS.md" "$repo_root/AGENTS.md"
fi

if [ ! -f "$repo_root/CODEX.md" ]; then
  cp "$KIT_ROOT/templates/repo/CODEX.md" "$repo_root/CODEX.md"
fi

if [ ! -f "$repo_root/CLAUDE.md" ]; then
  cp "$KIT_ROOT/templates/repo/CLAUDE.md" "$repo_root/CLAUDE.md"
fi

for command in operator-bootstrap.md operator-status.md; do
  if [ ! -f "$repo_root/.claude/commands/$command" ]; then
    cp "$KIT_ROOT/templates/claude/commands/$command" "$repo_root/.claude/commands/$command"
  fi
done

if [ ! -f "$repo_root/.claude/agents/operator-workflow.md" ]; then
  cp "$KIT_ROOT/templates/claude/agents/operator-workflow.md" "$repo_root/.claude/agents/operator-workflow.md"
fi

if [ ! -f "$project_root/operator/README.md" ]; then
  cp "$KIT_ROOT/templates/operator-workspace/README.md" "$project_root/operator/README.md"
fi

if ! grep -q 'Agent Operator Kit generated state' "$repo_root/.gitignore" 2>/dev/null; then
  {
    printf '\n'
    cat "$KIT_ROOT/templates/repo/gitignore.snippet"
  } >> "$repo_root/.gitignore"
fi

printf 'Installed Agent Operator Kit into: %s\n' "$repo_root"
printf 'Operator workspace: %s\n' "$project_root/operator"
printf 'Next:\n'
printf '  cd %s\n' "$repo_root"
printf '  edit operator.config.env\n'
printf '  bash scripts/operator-tmux.sh start\n'
printf '  bash scripts/operator-status.sh\n'
