#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

if [ "${1:-}" = "setup-guide" ]; then
  cat <<EOF
Operator model selection is optional. It never applies a model or reasoning
setting; live recommendations require reviewed catalog.json and policy.json files.

Provide these inputs before opting in:
  1. Models: provider/model IDs and each exact thinking or reasoning setting.
  2. Availability: verified hosts, lanes, tools, modalities, context windows,
     data classes, credential capability names, and maximum risk class.
  3. Evidence by task class: quality and confidence plus first-attempt, retry,
     escalation, latency, and cost estimates. Keep unknown values null.
  4. Policy: allowed profiles, quality/risk floors, budgets, data rules, and
     whether user pins are allowed.
  5. User guidance: preferred profiles, continuity needs, explicit pins, and
     the reason for any override.

Starter files:
  $OPERATOR_DIR/model-selection/catalog.example.json
  $OPERATOR_DIR/model-selection/policy.example.json

Live files (create only after review):
  $OPERATOR_DIR/model-selection/catalog.json
  $OPERATOR_DIR/model-selection/policy.json

Keep policy mode "off" while preparing inputs. Then validate both files and
change mode to "recommend" only when you want advisory recommendations. Operator
will still not apply a model, change a lane/chat, dispatch work, or learn online.

To ask Operator for an evidence-backed starting point from the current lane map
and any structured task/outcome history, run:
  bash scripts/operator-model-select.sh suggest-from-history

The suggestion is printed to stdout, writes nothing, keeps policy mode "off",
and lists every missing or review-required input. By default it looks for:
  $OPERATOR_DIR/model-selection/tasks.jsonl
  $OPERATOR_DIR/model-selection/outcomes.jsonl
  $OPERATOR_DIR/model-selection/catalog.json
EOF
  exit 0
fi

# Stable exits from operator_model_selector.py:
#   0 = valid recommendation, validation, or replay
#   3 = valid off/needs_override advisory receipt
#   2 = invalid usage, input, or I/O
exec /usr/bin/python3 -E -s "$SCRIPT_DIR/operator_model_selector.py" \
  --operator-dir "$OPERATOR_DIR" \
  --project-name "$PROJECT_NAME" \
  --lane-map "$OPERATOR_LANES" \
  "$@"
