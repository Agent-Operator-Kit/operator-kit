#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-memory.sh <command> [args]

Commands:
  init
      Create the operator memory workspace.

  status
      Show project, task, and episode memory counts.

  search [--limit N] <query>
      Search operator memory with simple lexical ranking.

  pack <lane> <slug> [--task-file <path>]
      Build a small dispatch context pack for one lane and task.

  ingest <lane> <slug> <handoff-file>
      Distill a collected lane handoff into an episode memory file.

  promote project <text...>
  promote task <slug> <text...>
      Append a durable memory entry. If text is omitted, stdin is read.
USAGE
}

MEMORY_DIR="$OPERATOR_DIR/memory"
EPISODES_DIR="$MEMORY_DIR/episodes"
PACKS_DIR="$MEMORY_DIR/packs"

memory_init() {
  mkdir -p "$EPISODES_DIR" "$PACKS_DIR"

  if [ ! -f "$MEMORY_DIR/project.md" ]; then
    cat > "$MEMORY_DIR/project.md" <<'EOF'
# Project Memory

Durable project facts, decisions, constraints, and recurring pitfalls that
should be available to Operator Kit task dispatch.

Keep this file short. Promote only facts that are likely to help future lanes.

## Entries
EOF
  fi

  if [ ! -f "$MEMORY_DIR/README.md" ]; then
    cat > "$MEMORY_DIR/README.md" <<'EOF'
# Operator Memory

Operator memory is local generated state under `OPERATOR_DIR`.

It is split into:

- `project.md` for durable project facts and decisions
- `tasks/<slug>/memory.md` for feature-track memory
- `episodes/*.md` for distilled lane handoffs
- `packs/` for optional generated context packs

Raw pane captures and handoffs are evidence, not memory. Promote only concise,
useful facts that should influence future task dispatch.
EOF
  fi
}

task_memory_file() {
  local slug="$1"
  printf '%s\n' "$OPERATOR_DIR/tasks/$slug/memory.md"
}

relative_to_operator_dir() {
  local path="$1"
  case "$path" in
    "$OPERATOR_DIR"/*) printf '%s\n' "${path#$OPERATOR_DIR/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

cap_stream() {
  local max_bytes="${1:-4000}"
  awk -v max="$max_bytes" '
    BEGIN { used = 0; truncated = 0 }
    {
      line = $0
      next_used = used + length(line) + 1
      if (next_used <= max) {
        print line
        used = next_used
      } else if (!truncated) {
        print "...[truncated]"
        truncated = 1
        exit
      }
    }
  '
}

summarize_stream() {
  awk '
    BEGIN { count = 0 }
    {
      line = $0
      gsub(/\r/, "", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^```/) next
      if (line ~ /(Memory Candidates|Durable decision|Project fact|Failed approach|Validation finding|Follow-up|Handoff|Result|Status|Changed files|Commands run|Blockers?|failed|passed|completed|Done|Next|Recommended|Working|Running|Waiting|Validation|clean|dirty|merge|dispatch)/) {
        lines[++count] = line
      }
    }
    END {
      start = count - 23
      if (start < 1) start = 1
      for (i = start; i <= count; i++) print "- " lines[i]
    }
  '
}

extract_memory_candidates() {
  local source_file="$1"
  awk '
    BEGIN { in_section = 0; found = 0 }
    /^##[[:space:]]+Memory Candidates/ { in_section = 1; found = 1; next }
    /^##[[:space:]]+/ && in_section { in_section = 0 }
    in_section {
      line = $0
      gsub(/\r/, "", line)
      if (line != "" && line !~ /^```/) print line
    }
    END {
      if (!found) exit 1
    }
  ' "$source_file"
}

memory_files() {
  memory_init
  {
    [ -f "$MEMORY_DIR/project.md" ] && printf '%s\n' "$MEMORY_DIR/project.md"
    find "$OPERATOR_DIR/tasks" -mindepth 2 -maxdepth 2 -name memory.md -type f 2>/dev/null || true
    find "$EPISODES_DIR" -type f -name '*.md' 2>/dev/null || true
  } | sort
}

score_file() {
  local query="$1"
  local file="$2"
  awk -v q="$query" -v file="$file" '
    BEGIN {
      query = tolower(q)
      gsub(/[^a-z0-9._\/:-]+/, " ", query)
      n = split(query, toks, /[[:space:]]+/)
      score = 0
      snippet = ""
    }
    {
      line = tolower($0)
      line_score = 0
      for (i = 1; i <= n; i++) {
        tok = toks[i]
        if (length(tok) >= 2 && index(line, tok) > 0) {
          line_score++
        }
      }
      if (line_score > 0) {
        score += line_score
        if (snippet == "") {
          snippet = $0
          gsub(/^[[:space:]]+/, "", snippet)
        }
      }
    }
    END {
      if (score > 0) {
        printf "%09d\t%s\t%s\n", score, file, snippet
      }
    }
  ' "$file"
}

search_memory() {
  local limit=8
  local query_parts=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --limit)
        limit="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        query_parts+=("$1")
        shift
        ;;
    esac
  done

  local query="${query_parts[*]}"
  if [ -z "$query" ]; then
    printf 'search requires a query\n' >&2
    exit 1
  fi
  case "$limit" in
    ''|*[!0-9]*)
      printf 'search --limit must be a positive integer\n' >&2
      exit 1
      ;;
  esac
  if [ "$limit" -lt 1 ]; then
    printf 'search --limit must be a positive integer\n' >&2
    exit 1
  fi

  local tmp
  tmp="$(mktemp)"

  while IFS= read -r file; do
    score_file "$query" "$file" >> "$tmp"
  done < <(memory_files)

  if [ ! -s "$tmp" ]; then
    printf 'No memory matches for: %s\n' "$query"
    rm -f "$tmp"
    return 0
  fi

  sort -r "$tmp" | head -n "$limit" | awk -F'\t' -v op="$OPERATOR_DIR" '
    {
      rel = $2
      sub("^" op "/", "", rel)
      printf "### %s\n", rel
      printf "Score: %d\n", $1 + 0
      if ($3 != "") printf "Snippet: %s\n", $3
      printf "\n"
    }
  '
  rm -f "$tmp"
}

latest_episode_files() {
  local lane="$1"
  local slug="$2"
  find "$EPISODES_DIR" -type f -name "*-${lane}-${slug}.md" 2>/dev/null \
    | sort \
    | tail -3
}

pack_context() {
  local lane="${1:-}"
  local slug="${2:-}"
  if [ -z "$lane" ] || [ -z "$slug" ]; then
    printf 'pack requires <lane> <slug>\n' >&2
    exit 1
  fi
  shift 2
  local task_file=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task-file)
        task_file="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown pack argument: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  done

  operator_require_lane "$lane"
  memory_init

  local task_memory
  task_memory="$(task_memory_file "$slug")"
  local query="$lane $slug"
  if [ -n "$task_file" ] && [ -f "$task_file" ]; then
    query="$query $(sed -n '1,80p' "$task_file" | tr '\n' ' ')"
  fi

  printf '# Operator Context Pack\n\n'
  printf 'Generated: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '%s\n' "- Project: $PROJECT_NAME"
  printf '%s\n' "- Lane: \`$lane\`"
  printf '%s\n' "- Owner: $(operator_lane_owner "$lane")"
  printf '%s\n' "- Worktree: \`$(operator_lane_path "$lane")\`"
  printf '%s\n\n' "- Expected branch: \`$(operator_lane_branch "$lane")\`"

  printf '## Use This Context\n\n'
  printf '%s\n' '- Treat this pack as retrieved context, not as a replacement for the task packet.'
  printf '%s\n' '- If this pack conflicts with the task packet, follow the task packet and report the conflict.'
  printf '%s\n\n' '- Return concise memory candidates in your handoff when you learn something durable.'

  if [ -n "$task_file" ] && [ -f "$task_file" ]; then
    printf '## Task Packet Excerpt\n\n'
    sed -n '1,120p' "$task_file" | cap_stream 4500
    printf '\n\n'
  fi

  printf '## Feature-Track Memory\n\n'
  if [ -f "$task_memory" ]; then
    cap_stream 3500 < "$task_memory"
  else
    printf 'No task memory yet.\n'
  fi
  printf '\n\n'

  printf '## Project Memory\n\n'
  if [ -f "$MEMORY_DIR/project.md" ]; then
    cap_stream 3500 < "$MEMORY_DIR/project.md"
  else
    printf 'No project memory yet.\n'
  fi
  printf '\n\n'

  printf '## Recent Same-Lane Episodes\n\n'
  local any_episode=0
  while IFS= read -r episode; do
    any_episode=1
    printf '### %s\n\n' "$(relative_to_operator_dir "$episode")"
    summarize_stream < "$episode" | cap_stream 1800
    printf '\n'
  done < <(latest_episode_files "$lane" "$slug")
  if [ "$any_episode" -eq 0 ]; then
    printf 'No same-lane episodes yet.\n'
  fi
  printf '\n'

  printf '## Retrieved Memory Matches\n\n'
  local tmp
  tmp="$(mktemp)"
  while IFS= read -r file; do
    score_file "$query" "$file" >> "$tmp"
  done < <(memory_files)
  if [ -s "$tmp" ]; then
    sort -r "$tmp" | head -n 5 | while IFS=$'\t' read -r _score file snippet; do
      printf '### %s\n\n' "$(relative_to_operator_dir "$file")"
      if [ -n "$snippet" ]; then
        printf '%s\n\n' "$snippet"
      fi
      summarize_stream < "$file" | cap_stream 1200
      printf '\n'
    done
  else
    printf 'No retrieved matches.\n'
  fi
  rm -f "$tmp"
}

ingest_handoff() {
  local lane="${1:-}"
  local slug="${2:-}"
  local handoff_file="${3:-}"

  if [ -z "$lane" ] || [ -z "$slug" ] || [ -z "$handoff_file" ]; then
    printf 'ingest requires <lane> <slug> <handoff-file>\n' >&2
    exit 1
  fi
  operator_require_lane "$lane"
  if [ ! -f "$handoff_file" ]; then
    printf 'handoff file not found: %s\n' "$handoff_file" >&2
    exit 1
  fi

  memory_init
  local timestamp
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  local episode="$EPISODES_DIR/${timestamp}-${lane}-${slug}.md"

  {
    printf '# Episode: %s / %s\n\n' "$lane" "$slug"
    printf 'Captured: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "- Lane: \`$lane\`"
    printf '%s\n' "- Task: \`$slug\`"
    printf '%s\n' "- Source handoff: \`$(relative_to_operator_dir "$handoff_file")\`"
    printf '%s\n\n' "- Expected branch: \`$(operator_lane_branch "$lane")\`"

    printf '## Episode Highlights\n\n'
    summarize_stream < "$handoff_file" | cap_stream 3500
    printf '\n\n'

    printf '## Memory Candidates\n\n'
    if ! extract_memory_candidates "$handoff_file" | cap_stream 2500; then
      printf 'No explicit memory candidates found in the handoff.\n'
    fi
    printf '\n\n'

    printf '## Evidence Pointer\n\n'
    printf 'Raw handoff remains available at `%s`.\n' "$(relative_to_operator_dir "$handoff_file")"
  } > "$episode"

  printf '%s\n' "$episode"
}

promote_memory() {
  local scope="${1:-}"
  shift || true
  local target=""
  local text=""

  case "$scope" in
    project)
      memory_init
      target="$MEMORY_DIR/project.md"
      text="$*"
      ;;
    task)
      local slug="${1:-}"
      if [ -z "$slug" ]; then
        printf 'promote task requires <slug>\n' >&2
        exit 1
      fi
      shift || true
      memory_init
      target="$(task_memory_file "$slug")"
      if [ ! -f "$target" ]; then
        mkdir -p "$(dirname "$target")"
        {
          printf '# Task Memory: %s\n\n' "$slug"
          printf '## Entries\n'
        } > "$target"
      fi
      text="$*"
      ;;
    *)
      printf 'promote scope must be project or task\n' >&2
      exit 1
      ;;
  esac

  if [ -z "$text" ]; then
    text="$(cat)"
  fi

  if [ -z "$text" ]; then
    printf 'promote requires text or stdin\n' >&2
    exit 1
  fi

  {
    printf '\n- %s: %s\n' "$(date -u '+%Y-%m-%d')" "$text"
  } >> "$target"

  printf '%s\n' "$target"
}

memory_status() {
  memory_init
  local project_entries=0
  local task_files=0
  local episode_files=0

  project_entries="$(grep -c '^- ' "$MEMORY_DIR/project.md" 2>/dev/null || true)"
  task_files="$(find "$OPERATOR_DIR/tasks" -mindepth 2 -maxdepth 2 -name memory.md -type f 2>/dev/null | wc -l | tr -d ' ')"
  episode_files="$(find "$EPISODES_DIR" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"

  printf 'Operator memory: %s\n' "$MEMORY_DIR"
  printf 'Project entries: %s\n' "$project_entries"
  printf 'Task memory files: %s\n' "$task_files"
  printf 'Episode files: %s\n' "$episode_files"
}

command="${1:-}"
if [ -z "$command" ]; then
  usage >&2
  exit 1
fi
shift || true

case "$command" in
  init)
    memory_init
    printf '%s\n' "$MEMORY_DIR"
    ;;
  status)
    memory_status
    ;;
  search)
    search_memory "$@"
    ;;
  pack)
    pack_context "$@"
    ;;
  ingest)
    ingest_handoff "$@"
    ;;
  promote)
    promote_memory "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    printf 'Unknown command: %s\n\n' "$command" >&2
    usage >&2
    exit 1
    ;;
esac
