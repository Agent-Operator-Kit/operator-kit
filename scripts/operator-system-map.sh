#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

SYSTEM_MAP="$OPERATOR_DIR/system-map.md"
REPO_ROOT="$(cd "$(dirname "$(operator_config_file)")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-system-map.sh <command>

Commands:
  refresh
      Scan the repo and write OPERATOR_DIR/system-map.md.
  show
      Print the current system map, refreshing it first if missing.
  roles
      Print detected role-template candidates.
  recommend-lanes
      Print durable lane and role-overlay recommendations.
USAGE
}

repo_has_path() {
  local pattern="$1"
  find "$REPO_ROOT" -path '*/.git' -prune -o -path '*/node_modules' -prune -o -path '*/vendor' -prune -o -name "$pattern" -print -quit 2>/dev/null | grep -q .
}

repo_has_text() {
  local pattern="$1"
  if command -v rg >/dev/null 2>&1; then
    rg -qi --glob '!.git/**' --glob '!node_modules/**' --glob '!vendor/**' "$pattern" "$REPO_ROOT" 2>/dev/null
  else
    grep -Rqi "$pattern" "$REPO_ROOT" 2>/dev/null
  fi
}

detect_roles() {
  local emitted=""

  emit() {
    case " $emitted " in
      *" $1 "*) ;;
      *) emitted="$emitted $1"; printf '%s\n' "$1" ;;
    esac
  }

  if repo_has_path "apps" || repo_has_text "fastify|express|nestjs|trpc|openapi|server.ts|routes"; then
    emit api-contracts
  fi
  if repo_has_text "expo|react native|maestro|eas.json|ios|android"; then
    emit mobile-app
    emit mobile-release
  fi
  if repo_has_text "vite|next|react|svelte|vue|playwright"; then
    emit web-ui
  fi
  if repo_has_text "drizzle|prisma|postgres|mysql|sqlite|migration|schema"; then
    emit data-storage
  fi
  if repo_has_text "auth|session|permission|rls|oauth|jwt|better-auth"; then
    emit auth-permissions
  fi
  if repo_has_text "strava|wahoo|apple health|healthkit|webhook|provider|token exchange"; then
    emit provider-integration
  fi
  if repo_has_text "openai|anthropic|llm|prompt|agent-runtime|model provider|eval"; then
    emit llm-runtime
  fi
  if repo_has_text "knowledge|rag|embedding|vector|claim|snapshot|retrieval"; then
    emit knowledge-base
  fi
  if repo_has_text "playwright|maestro|vitest|jest|pytest|evals|regression"; then
    emit evals-testing
  fi
  if repo_has_path ".github" || repo_has_text "railway|vercel|docker|deployment|testflight|ci/cd|workflow"; then
    emit deployment-recovery
  fi
  if repo_has_text "sentry|otel|opentelemetry|logging|metrics|healthcheck|incident"; then
    emit observability
  fi
  if repo_has_text "broker|trading|portfolio|risk|position sizing|order"; then
    emit trading-risk
  fi
  if repo_has_text "design system|tokens|figma|storybook|tailwind|component library"; then
    emit design-system
  fi
}

print_architecture_docs() {
  find "$REPO_ROOT" \
    -path '*/.git' -prune -o \
    -path '*/node_modules' -prune -o \
    \( -iname 'architecture.md' -o -iname 'ARCHITECTURE.md' -o -name 'README.md' -o -name 'AGENTS.md' \) \
    -print 2>/dev/null | sort | sed "s#^$REPO_ROOT/##"
}

print_current_lanes() {
  local lane
  for lane in $(operator_lanes); do
    printf '| `%s` | %s | `%s` | `%s` |\n' \
      "$lane" \
      "$(operator_lane_owner "$lane")" \
      "$(operator_lane_worktree_name "$lane")" \
      "$(operator_lane_branch "$lane")"
  done
}

recommend_lanes() {
  local roles
  roles="$(detect_roles | sort)"

  printf '# Operator V2 Lane Recommendation\n\n'
  printf 'Principle: create durable lanes for long-lived ownership, contract boundaries, high-risk domains, distinct validation loops, and high context density. Use role overlays for specialist work that does not yet need a permanent worktree.\n\n'

  printf '## Recommended Durable Lanes\n\n'
  if printf '%s\n' "$roles" | grep -qx 'api-contracts'; then
    printf '%s\n' '- `api-contracts`: backend/API ownership, schema contracts, service boundaries.'
  fi
  if printf '%s\n' "$roles" | grep -qx 'mobile-app'; then
    printf '%s\n' '- `mobile-app`: native app flows, device permissions, simulator validation.'
  fi
  if printf '%s\n' "$roles" | grep -qx 'web-ui'; then
    printf '%s\n' '- `web-ui`: browser surface, UI contracts, Playwright validation.'
  fi
  if printf '%s\n' "$roles" | grep -qx 'llm-runtime'; then
    printf '%s\n' '- `llm-runtime`: prompts, providers, evals, traceability, model behavior.'
  fi
  if printf '%s\n' "$roles" | grep -qx 'knowledge-base'; then
    printf '%s\n' '- `knowledge-base`: ingestion, retrieval, snapshots, evidence quality.'
  fi
  if printf '%s\n' "$roles" | grep -qx 'deployment-recovery'; then
    printf '%s\n' '- `release`: deployment, CI/CD, release gates, rollback and recovery.'
  fi
  if printf '%s\n' "$roles" | grep -qx 'trading-risk'; then
    printf '%s\n' '- `risk-trading`: broker, portfolio, order, exposure, and live-money gates.'
  fi

  printf '\n## Recommended Role Overlays\n\n'
  if [ -n "$roles" ]; then
    printf '%s\n' "$roles" | sed 's/^/- `/' | sed 's/$/`/'
  else
    printf '%s\n' '- No specialist overlays detected. Curate the catalog manually.'
  fi

  printf '\n## Serialized Or Approval-Gated Domains\n\n'
  printf '%s\n' '- production deployments, release submissions, provider console changes, destructive migrations, secrets, live-money behavior'
}

refresh_map() {
  mkdir -p "$(dirname "$SYSTEM_MAP")"
  {
    printf '# Operator System Map\n\n'
    printf '%s\n' "- Project: $PROJECT_NAME"
    printf '%s\n' "- Operator Kit version: $(operator_kit_version)"
    printf '%s\n' "- Project root: \`$PROJECT_ROOT\`"
    printf '%s\n' "- Repo root: \`$REPO_ROOT\`"
    printf '%s\n' "- Code dir: \`$CODE_DIR\`"
    printf '%s\n\n' "- Operator dir: \`$OPERATOR_DIR\`"
    printf '%s\n\n' "- Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    printf '## Current Lanes\n\n'
    printf '| Lane | Owner | Worktree | Branch |\n'
    printf '| --- | --- | --- | --- |\n'
    print_current_lanes

    printf '\n## Architecture Inputs\n\n'
    print_architecture_docs | sed 's/^/- `/' | sed 's/$/`/'

    printf '\n## Detected Role Candidates\n\n'
    detect_roles | sort | sed 's/^/- `/' | sed 's/$/`/'

    printf '\n'
    recommend_lanes
  } > "$SYSTEM_MAP"

  printf '%s\n' "$SYSTEM_MAP"
}

command="${1:-}"
shift || true

case "$command" in
  refresh) refresh_map ;;
  show)
    [ -f "$SYSTEM_MAP" ] || refresh_map >/dev/null
    cat "$SYSTEM_MAP"
    ;;
  roles) detect_roles | sort ;;
  recommend-lanes) recommend_lanes ;;
  -h|--help|"") usage ;;
  *)
    printf 'Unknown command: %s\n\n' "$command" >&2
    usage >&2
    exit 1
    ;;
esac
