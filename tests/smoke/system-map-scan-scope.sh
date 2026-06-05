#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d /tmp/aok-system-map.XXXXXX)"
tmp_root="$(cd "$tmp_root" && pwd -P)"
trap 'rm -rf "$tmp_root"' EXIT

repo="$tmp_root/code/app"
operator_dir="$repo/operator"
mkdir -p "$repo/worktrees/lane/apps" "$repo/output" "$operator_dir" "$repo/docs"
printf '# Fixture\n' > "$repo/README.md"
printf '# Worktree copy\nopenai payment sentry\n' > "$repo/worktrees/lane/README.md"
printf '# Generated output\npayment sentry\n' > "$repo/output/README.md"
printf '# Operator state\nopenai payment sentry\n' > "$operator_dir/README.md"
printf '\000openai payment sentry\n' > "$repo/docs/report.pdf"

cat > "$repo/operator.config.env" <<EOF
PROJECT_NAME="system-map-smoke"
PROJECT_ROOT="$tmp_root"
CODE_DIR="$tmp_root/code"
OPERATOR_DIR="$operator_dir"
TMUX_SESSION="system-map-smoke"
DEFAULT_BRANCH="main"
OPERATOR_KIT_VERSION="2"

OPERATOR_LANES='
operator|Codex Desktop|app|main|
'
EOF

fallback_path="/usr/bin:/bin:/usr/sbin:/sbin"
if PATH="$fallback_path" command -v rg >/dev/null 2>&1; then
  printf 'Fallback PATH unexpectedly contains rg.\n' >&2
  exit 1
fi

PATH="$fallback_path" OPERATOR_CONFIG="$repo/operator.config.env" \
  bash "$KIT_ROOT/scripts/operator-system-map.sh" refresh >/dev/null

system_map="$operator_dir/system-map.md"
test -f "$system_map"

if grep -q 'worktrees/lane/README.md' "$system_map"; then
  printf 'system map included nested worktree README.\n' >&2
  exit 1
fi

if grep -q 'output/README.md' "$system_map"; then
  printf 'system map included generated output README.\n' >&2
  exit 1
fi

if grep -q 'operator/README.md' "$system_map"; then
  printf 'system map included operator state README.\n' >&2
  exit 1
fi

roles="$(PATH="$fallback_path" OPERATOR_CONFIG="$repo/operator.config.env" \
  bash "$KIT_ROOT/scripts/operator-system-map.sh" roles)"

for excluded_role in api-contracts high-risk-operations llm-runtime observability; do
  if printf '%s\n' "$roles" | grep -qx "$excluded_role"; then
    printf 'excluded content triggered role: %s\n' "$excluded_role" >&2
    printf '%s\n' "$roles" >&2
    exit 1
  fi
done

printf 'system-map scan scope smoke ok: %s\n' "$tmp_root"
