#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

unit_bootstrap_project() {
  if [ -n "${UNIT_BOOTSTRAPPED:-}" ]; then
    return 0
  fi

  UNIT_TMP="$(mktemp -d /tmp/aok-unit.XXXXXX)"
  UNIT_TMP="$(cd "$UNIT_TMP" && pwd -P)"
  UNIT_APP="$UNIT_TMP/code/app"

  mkdir -p "$UNIT_APP"
  git -C "$UNIT_APP" init -b main >/dev/null
  git -C "$UNIT_APP" config user.email unit@example.com
  git -C "$UNIT_APP" config user.name "Unit Test"
  printf '# Unit\n' > "$UNIT_APP/README.md"
  git -C "$UNIT_APP" add README.md
  git -C "$UNIT_APP" commit -m 'init' >/dev/null

  bash "$KIT_ROOT/scripts/operator-bootstrap.sh" --profile cursor "$UNIT_APP" >/dev/null
  UNIT_BOOTSTRAPPED=1
}

unit_cleanup() {
  if [ -n "${UNIT_TMP:-}" ] && [ -d "$UNIT_TMP" ]; then
    rm -rf "$UNIT_TMP"
  fi
}

unit_pass() {
  printf 'unit ok: %s\n' "$1"
}

unit_fail() {
  printf 'unit failed: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! printf '%s' "$haystack" | grep -Fq "$needle"; then
    unit_fail "expected output to contain: $needle"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if printf '%s' "$haystack" | grep -Fq "$needle"; then
    unit_fail "expected output not to contain: $needle"
  fi
}

trap unit_cleanup EXIT
