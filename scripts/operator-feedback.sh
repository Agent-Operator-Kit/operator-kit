#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/operator-lib.sh
source "$SCRIPT_DIR/operator-lib.sh"
operator_load_config

CONFIG_DIR="$OPERATOR_DIR/config"
ROADMAP_DIR="$OPERATOR_DIR/roadmap"
INBOX_DIR="$ROADMAP_DIR/inbox"
DEFAULT_PORT="${OPERATOR_FEEDBACK_PORT:-8799}"

usage() {
  cat <<'USAGE'
Usage: bash scripts/operator-feedback.sh <command> [args]

Commands:
  init
      Create local feedback and roadmap workspace folders.
  detect
      Detect project feedback/test surfaces and write OPERATOR_DIR/config/feedback.env.
  start <slug> "<title>"
      Create an operator task and feedback intake workspace.
  capture-sim <slug> [--note "..."]
      Capture a screenshot from the booted iOS Simulator into the feedback task.
  record-sim-start <slug>
      Start iOS Simulator video recording for the feedback task.
  record-sim-stop <slug>
      Stop the active simulator recording for the feedback task.
  review <slug> [--port 8799]
      Start the local browser annotation UI for task captures.
  triage <slug>
      Convert saved annotations into OPERATOR_DIR/roadmap/inbox feedback items.
USAGE
}

feedback_init() {
  mkdir -p "$CONFIG_DIR" "$ROADMAP_DIR/items" "$INBOX_DIR" "$ROADMAP_DIR/views"
}

task_dir_for_slug() {
  local slug="$1"
  printf '%s\n' "$OPERATOR_DIR/tasks/$slug"
}

feedback_dir_for_slug() {
  local slug="$1"
  printf '%s\n' "$OPERATOR_DIR/tasks/$slug/work/feedback"
}

require_task() {
  local slug="$1"
  local task_dir
  task_dir="$(task_dir_for_slug "$slug")"
  if [ ! -d "$task_dir" ]; then
    printf 'Feedback task not found: %s\n' "$task_dir" >&2
    printf 'Create it first: bash scripts/operator-feedback.sh start %s "Title"\n' "$slug" >&2
    exit 1
  fi
}

init_feedback_files() {
  local slug="$1"
  local title="$2"
  local feedback_dir
  feedback_dir="$(feedback_dir_for_slug "$slug")"
  mkdir -p "$feedback_dir/captures"

  if [ ! -f "$feedback_dir/feedback.md" ]; then
    {
      printf '# Feedback Intake: %s\n\n' "$title"
      printf '%s\n' "- Slug: $slug"
      printf '%s\n' "- Created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf '\n## Capture Notes\n\n'
      printf 'Add raw testing notes here. Use `review` to annotate screenshots in a browser.\n'
    } > "$feedback_dir/feedback.md"
  fi

  [ -f "$feedback_dir/annotations.json" ] || printf '[]\n' > "$feedback_dir/annotations.json"
  [ -f "$feedback_dir/annotations.md" ] || printf '# Annotations\n\n' > "$feedback_dir/annotations.md"
  [ -f "$feedback_dir/backlog.md" ] || printf '# Backlog Candidates\n\n' > "$feedback_dir/backlog.md"
  [ -f "$feedback_dir/roadmap.md" ] || printf '# Roadmap Candidates\n\n' > "$feedback_dir/roadmap.md"
}

escape_env_value() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

write_env_var() {
  local key="$1"
  local value="$2"
  printf "%s='%s'\n" "$key" "$(escape_env_value "$value")"
}

has_package_script() {
  local package_file="$1"
  local script="$2"
  [ -f "$package_file" ] && grep -Eq "\"$script\"[[:space:]]*:" "$package_file"
}

detect_profile() {
  feedback_init
  local output="$CONFIG_DIR/feedback.env"
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

  local has_package="no" has_web="no" has_playwright="no"
  local has_expo="no" has_react_native="no" has_maestro="no"
  local has_ios_sim="no" ios_booted="no" has_android="no"
  local dev_personal="" dev_mobile="" test_mobile_maestro="" test_admin_web=""

  [ -f "$repo_root/package.json" ] && has_package="yes"
  [ -d "$repo_root/tests/playwright" ] && has_playwright="yes"
  [ -d "$repo_root/apps/web" ] && has_web="yes"
  [ -d "$repo_root/tests/maestro" ] && has_maestro="yes"

  if find "$repo_root" -maxdepth 4 \( -name 'app.json' -o -name 'app.config.ts' -o -name 'app.config.js' \) -print -quit | grep -q .; then
    has_expo="yes"
  fi

  while IFS= read -r package_file; do
    if grep -Eq "\"expo\"" "$package_file"; then
      has_expo="yes"
      has_react_native="yes"
    fi
    if grep -Eq "\"react-native\"" "$package_file"; then
      has_react_native="yes"
    fi
  done < <(find "$repo_root" -maxdepth 4 -name package.json -not -path '*/node_modules/*' 2>/dev/null | sort)

  if command -v xcrun >/dev/null 2>&1; then
    if xcrun simctl list devices available >/dev/null 2>&1; then
      has_ios_sim="yes"
    fi
    if xcrun simctl list devices booted 2>/dev/null | grep -q "Booted"; then
      ios_booted="yes"
    fi
  fi

  if command -v adb >/dev/null 2>&1 || command -v emulator >/dev/null 2>&1; then
    has_android="yes"
  fi

  if has_package_script "$repo_root/package.json" "dev:personal"; then dev_personal="pnpm dev:personal"; fi
  if has_package_script "$repo_root/package.json" "dev:mobile"; then dev_mobile="pnpm dev:mobile"; fi
  if has_package_script "$repo_root/package.json" "test:mobile:maestro"; then test_mobile_maestro="pnpm test:mobile:maestro"; fi
  if has_package_script "$repo_root/package.json" "test:admin-web"; then test_admin_web="pnpm test:admin-web"; fi

  {
    printf '# Operator feedback profile\n'
    printf '# Generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    write_env_var PROJECT_ROOT "$repo_root"
    write_env_var HAS_PACKAGE_JSON "$has_package"
    write_env_var HAS_WEB "$has_web"
    write_env_var HAS_PLAYWRIGHT "$has_playwright"
    write_env_var HAS_EXPO "$has_expo"
    write_env_var HAS_REACT_NATIVE "$has_react_native"
    write_env_var HAS_MAESTRO "$has_maestro"
    write_env_var HAS_IOS_SIMULATOR "$has_ios_sim"
    write_env_var IOS_SIMULATOR_BOOTED "$ios_booted"
    write_env_var HAS_ANDROID_TOOLS "$has_android"
    write_env_var DEV_PERSONAL_COMMAND "$dev_personal"
    write_env_var DEV_MOBILE_COMMAND "$dev_mobile"
    write_env_var TEST_MOBILE_MAESTRO_COMMAND "$test_mobile_maestro"
    write_env_var TEST_ADMIN_WEB_COMMAND "$test_admin_web"
  } > "$output"

  printf 'Feedback profile: %s\n' "$output"
  sed 's/^/  /' "$output"
}

start_feedback_task() {
  local slug="${1:-}"
  local title="${2:-}"
  if [ -z "$slug" ] || [ -z "$title" ]; then
    usage >&2
    exit 1
  fi

  feedback_init
  local task_dir
  task_dir="$(bash "$SCRIPT_DIR/operator-task.sh" "$slug" "$title")"
  init_feedback_files "$slug" "$title"

  printf '%s\n' "$task_dir"
  printf 'Feedback workspace: %s\n' "$(feedback_dir_for_slug "$slug")"
}

capture_sim() {
  local slug="${1:-}"
  shift || true
  local note=""

  if [ -z "$slug" ]; then
    usage >&2
    exit 1
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note) note="${2:-}"; shift 2 ;;
      *)
        printf 'Unknown capture-sim option: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  done

  require_task "$slug"
  local feedback_dir capture_dir file timestamp
  feedback_dir="$(feedback_dir_for_slug "$slug")"
  capture_dir="$feedback_dir/captures"
  mkdir -p "$capture_dir"

  command -v xcrun >/dev/null 2>&1 || {
    printf 'xcrun is unavailable; install/select Xcode before simulator capture.\n' >&2
    exit 1
  }
  xcrun simctl list devices booted 2>/dev/null | grep -q "Booted" || {
    printf 'No booted iOS Simulator found. Boot a simulator before capture.\n' >&2
    exit 1
  }

  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  file="$capture_dir/sim-${timestamp}.png"
  xcrun simctl io booted screenshot "$file" >/dev/null

  {
    printf '\n## %s\n\n' "$timestamp"
    printf '%s\n' "- Capture: captures/$(basename "$file")"
    if [ -n "$note" ]; then
      printf '%s\n' "- Note: $note"
    fi
  } >> "$feedback_dir/feedback.md"

  printf '%s\n' "$file"
}

record_sim_start() {
  local slug="${1:-}"
  [ -n "$slug" ] || { usage >&2; exit 1; }
  require_task "$slug"

  command -v xcrun >/dev/null 2>&1 || {
    printf 'xcrun is unavailable; install/select Xcode before simulator recording.\n' >&2
    exit 1
  }
  xcrun simctl list devices booted 2>/dev/null | grep -q "Booted" || {
    printf 'No booted iOS Simulator found. Boot a simulator before recording.\n' >&2
    exit 1
  }

  local feedback_dir capture_dir pid_file path_file timestamp file
  feedback_dir="$(feedback_dir_for_slug "$slug")"
  capture_dir="$feedback_dir/captures"
  pid_file="$feedback_dir/.recording.pid"
  path_file="$feedback_dir/.recording.path"
  mkdir -p "$capture_dir"

  if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    printf 'Recording already running with pid %s\n' "$(cat "$pid_file")" >&2
    exit 1
  fi

  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  file="$capture_dir/sim-${timestamp}.mp4"
  xcrun simctl io booted recordVideo "$file" >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$pid_file"
  printf '%s\n' "$file" > "$path_file"
  printf 'Recording: %s\n' "$file"
}

record_sim_stop() {
  local slug="${1:-}"
  [ -n "$slug" ] || { usage >&2; exit 1; }
  require_task "$slug"

  local feedback_dir pid_file path_file pid file
  feedback_dir="$(feedback_dir_for_slug "$slug")"
  pid_file="$feedback_dir/.recording.pid"
  path_file="$feedback_dir/.recording.path"

  if [ ! -f "$pid_file" ]; then
    printf 'No active recording for task: %s\n' "$slug" >&2
    exit 1
  fi

  pid="$(cat "$pid_file")"
  file="$(cat "$path_file" 2>/dev/null || true)"
  if kill -0 "$pid" 2>/dev/null; then
    kill -INT "$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file" "$path_file"

  if [ -n "$file" ]; then
    {
      printf '\n## %s\n\n' "$(date -u '+%Y%m%dT%H%M%SZ')"
      printf '%s\n' "- Recording: captures/$(basename "$file")"
    } >> "$feedback_dir/feedback.md"
    printf '%s\n' "$file"
  fi
}

review_feedback() {
  local slug="${1:-}"
  shift || true
  local port="$DEFAULT_PORT"

  if [ -z "$slug" ]; then
    usage >&2
    exit 1
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) port="${2:-}"; shift 2 ;;
      *)
        printf 'Unknown review option: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  done

  require_task "$slug"
  local feedback_dir
  feedback_dir="$(feedback_dir_for_slug "$slug")"
  mkdir -p "$feedback_dir/captures"
  [ -f "$feedback_dir/annotations.json" ] || printf '[]\n' > "$feedback_dir/annotations.json"

  command -v python3 >/dev/null 2>&1 || {
    printf 'python3 is required for the local feedback review UI.\n' >&2
    exit 1
  }

  python3 - "$feedback_dir" "$slug" "$port" <<'PY'
import datetime
import html
import json
import mimetypes
import os
from pathlib import Path
import socketserver
import sys
from http.server import BaseHTTPRequestHandler
from urllib.parse import unquote, urlparse

feedback_dir = Path(sys.argv[1]).resolve()
slug = sys.argv[2]
base_port = int(sys.argv[3])
captures_dir = feedback_dir / "captures"
annotations_file = feedback_dir / "annotations.json"
annotations_md = feedback_dir / "annotations.md"
captures_dir.mkdir(parents=True, exist_ok=True)
if not annotations_file.exists():
    annotations_file.write_text("[]\n", encoding="utf-8")

def load_annotations():
    try:
        data = json.loads(annotations_file.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except Exception:
        return []

def write_annotations(data):
    annotations_file.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    lines = ["# Annotations", ""]
    for item in data:
        lines.append(f"## {item.get('id', 'annotation')}")
        lines.append("")
        for key in ["capture", "screen", "target", "testID", "type", "severity", "priority", "ownerLane", "relatedRoadmap"]:
            lines.append(f"- {key}: {item.get(key, '')}")
        coords = item.get("coordinates") or {}
        lines.append(f"- coordinates: x={coords.get('xPercent', '')}, y={coords.get('yPercent', '')}")
        lines.append("")
        lines.append(f"Comment: {item.get('comment', '')}")
        lines.append("")
        lines.append(f"Expected: {item.get('expected', '')}")
        lines.append("")
    annotations_md.write_text("\n".join(lines) + "\n", encoding="utf-8")

def capture_files():
    out = []
    for path in sorted(captures_dir.iterdir()):
        if path.suffix.lower() in [".png", ".jpg", ".jpeg", ".gif", ".webp", ".mp4", ".mov"]:
            out.append({"name": path.name, "type": "video" if path.suffix.lower() in [".mp4", ".mov"] else "image"})
    return out

INDEX = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Operator Feedback Review</title>
  <style>
    :root { color-scheme: light; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; background: #f5f7fa; color: #17202a; }
    header { padding: 16px 22px; background: #ffffff; border-bottom: 1px solid #d9e0ea; display: flex; justify-content: space-between; align-items: center; gap: 16px; }
    h1 { margin: 0; font-size: 18px; }
    main { display: grid; grid-template-columns: minmax(320px, 1fr) 360px; gap: 18px; padding: 18px; }
    .panel { background: #ffffff; border: 1px solid #d9e0ea; border-radius: 8px; min-width: 0; }
    .panel h2 { margin: 0; padding: 12px 14px; font-size: 14px; border-bottom: 1px solid #e6ebf2; }
    .captures { padding: 14px; display: grid; gap: 16px; }
    .capture { border: 1px solid #e0e6ee; border-radius: 8px; overflow: hidden; background: #fbfcfe; }
    .capture-title { padding: 8px 10px; font-size: 12px; color: #526273; border-bottom: 1px solid #e0e6ee; }
    .image-wrap { position: relative; display: inline-block; width: 100%; background: #111827; }
    .image-wrap img { display: block; max-width: 100%; width: 100%; height: auto; cursor: crosshair; }
    .marker { position: absolute; width: 14px; height: 14px; border-radius: 999px; background: #f97316; border: 2px solid #fff; transform: translate(-50%, -50%); box-shadow: 0 1px 6px rgba(0,0,0,.35); }
    video { width: 100%; display: block; background: #111827; }
    form { padding: 14px; display: grid; gap: 10px; }
    label { display: grid; gap: 4px; font-size: 12px; color: #526273; }
    input, textarea, select { font: inherit; padding: 8px 9px; border: 1px solid #ccd6e2; border-radius: 6px; background: #fff; color: #17202a; }
    textarea { min-height: 78px; resize: vertical; }
    button { border: 0; border-radius: 6px; background: #1f6feb; color: #fff; font-weight: 650; padding: 9px 11px; cursor: pointer; }
    button.secondary { background: #eef3f9; color: #1d2733; border: 1px solid #d5deea; }
    .annotation-list { padding: 0 14px 14px; display: grid; gap: 10px; }
    .annotation { border: 1px solid #e0e6ee; border-radius: 7px; padding: 9px; font-size: 13px; background: #fbfcfe; }
    .muted { color: #697789; font-size: 12px; }
    .empty { padding: 18px; color: #697789; }
    @media (max-width: 900px) { main { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
  <header>
    <h1>Operator Feedback Review: __SLUG__</h1>
    <button class="secondary" id="reload">Reload</button>
  </header>
  <main>
    <section class="panel">
      <h2>Captures</h2>
      <div class="captures" id="captures"></div>
    </section>
    <aside class="panel">
      <h2>New Annotation</h2>
      <form id="form">
        <label>Capture <input id="capture" name="capture" readonly></label>
        <label>Coordinates <input id="coords" name="coords" readonly placeholder="Click a screenshot"></label>
        <label>Screen <input id="screen" name="screen" placeholder="Coach chat"></label>
        <label>Target <input id="target" name="target" placeholder="Input, CTA, card, tab"></label>
        <label>testID <input id="testID" name="testID" placeholder="Optional semantic target"></label>
        <label>Type
          <select id="type" name="type">
            <option>bug</option><option>ui-polish</option><option>ux</option><option>data</option><option>roadmap</option><option>release</option>
          </select>
        </label>
        <label>Severity
          <select id="severity" name="severity">
            <option>P2</option><option>P0</option><option>P1</option><option>P3</option>
          </select>
        </label>
        <label>Owner lane <input id="ownerLane" name="ownerLane" placeholder="mobile-ui, mobile-backend, product"></label>
        <label>Comment <textarea id="comment" name="comment" placeholder="What feels wrong?"></textarea></label>
        <label>Expected <textarea id="expected" name="expected" placeholder="What should happen instead?"></textarea></label>
        <button type="submit">Save Annotation</button>
      </form>
      <h2>Saved</h2>
      <div class="annotation-list" id="annotations"></div>
    </aside>
  </main>
  <script>
    let state = { captures: [], annotations: [] };
    let selected = { capture: "", xPercent: "", yPercent: "" };
    const $ = (id) => document.getElementById(id);

    async function load() {
      const res = await fetch('/api/state');
      state = await res.json();
      renderCaptures();
      renderAnnotations();
    }

    function renderCaptures() {
      const root = $('captures');
      root.innerHTML = '';
      if (!state.captures.length) {
        root.innerHTML = '<div class="empty">No captures yet. Run capture-sim or add screenshots/videos to work/feedback/captures.</div>';
        return;
      }
      for (const cap of state.captures) {
        const box = document.createElement('div');
        box.className = 'capture';
        box.innerHTML = '<div class="capture-title"></div>';
        box.querySelector('.capture-title').textContent = cap.name;
        if (cap.type === 'image') {
          const wrap = document.createElement('div');
          wrap.className = 'image-wrap';
          const img = document.createElement('img');
          img.src = '/media/' + encodeURIComponent(cap.name);
          img.alt = cap.name;
          wrap.appendChild(img);
          for (const a of state.annotations.filter(x => x.capture === cap.name && x.coordinates)) {
            const marker = document.createElement('div');
            marker.className = 'marker';
            marker.style.left = a.coordinates.xPercent + '%';
            marker.style.top = a.coordinates.yPercent + '%';
            marker.title = a.comment || a.id;
            wrap.appendChild(marker);
          }
          wrap.addEventListener('click', (event) => {
            const rect = img.getBoundingClientRect();
            const x = Math.max(0, Math.min(100, ((event.clientX - rect.left) / rect.width) * 100));
            const y = Math.max(0, Math.min(100, ((event.clientY - rect.top) / rect.height) * 100));
            selected = { capture: cap.name, xPercent: x.toFixed(2), yPercent: y.toFixed(2) };
            $('capture').value = selected.capture;
            $('coords').value = selected.xPercent + '%, ' + selected.yPercent + '%';
          });
          box.appendChild(wrap);
        } else {
          const video = document.createElement('video');
          video.controls = true;
          video.src = '/media/' + encodeURIComponent(cap.name);
          box.appendChild(video);
          video.addEventListener('play', () => {
            selected = { capture: cap.name, xPercent: '', yPercent: '' };
            $('capture').value = selected.capture;
            $('coords').value = 'video';
          });
        }
        root.appendChild(box);
      }
    }

    function renderAnnotations() {
      const root = $('annotations');
      root.innerHTML = '';
      if (!state.annotations.length) {
        root.innerHTML = '<div class="muted">No annotations saved.</div>';
        return;
      }
      for (const a of state.annotations.slice().reverse()) {
        const div = document.createElement('div');
        div.className = 'annotation';
        div.innerHTML = '<strong></strong><div class="muted"></div><p></p><p></p>';
        div.querySelector('strong').textContent = a.id + ' - ' + (a.severity || '') + ' - ' + (a.type || '');
        div.querySelector('.muted').textContent = [a.capture, a.screen, a.target, a.testID].filter(Boolean).join(' - ');
        div.querySelectorAll('p')[0].textContent = a.comment || '';
        div.querySelectorAll('p')[1].textContent = a.expected ? 'Expected: ' + a.expected : '';
        root.appendChild(div);
      }
    }

    $('form').addEventListener('submit', async (event) => {
      event.preventDefault();
      if (!$('capture').value) {
        alert('Click a screenshot or play/select a video first.');
        return;
      }
      const item = {
        capture: $('capture').value,
        coordinates: selected.xPercent ? { xPercent: selected.xPercent, yPercent: selected.yPercent } : null,
        screen: $('screen').value,
        target: $('target').value,
        testID: $('testID').value,
        type: $('type').value,
        severity: $('severity').value,
        priority: $('severity').value,
        ownerLane: $('ownerLane').value,
        comment: $('comment').value,
        expected: $('expected').value
      };
      const res = await fetch('/api/annotations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(item) });
      if (!res.ok) {
        alert('Save failed');
        return;
      }
      $('comment').value = '';
      $('expected').value = '';
      await load();
    });
    $('reload').addEventListener('click', load);
    load();
  </script>
</body>
</html>"""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(fmt % args)

    def send_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/":
            body = INDEX.replace("__SLUG__", html.escape(slug)).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/api/state":
            self.send_json({"captures": capture_files(), "annotations": load_annotations()})
            return
        if parsed.path.startswith("/media/"):
            name = unquote(parsed.path[len("/media/"):])
            path = (captures_dir / name).resolve()
            if captures_dir not in path.parents or not path.exists():
                self.send_error(404)
                return
            data = path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", mimetypes.guess_type(str(path))[0] or "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_error(404)

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/api/annotations":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            item = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            self.send_json({"error": "invalid json"}, status=400)
            return
        data = load_annotations()
        item["id"] = item.get("id") or f"AN-{len(data) + 1:04d}"
        item["createdAt"] = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
        data.append(item)
        write_annotations(data)
        self.send_json({"ok": True, "item": item})

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

for port in range(base_port, base_port + 50):
    try:
        with ReusableTCPServer(("127.0.0.1", port), Handler) as httpd:
            print(f"Feedback review UI: http://127.0.0.1:{port}/", flush=True)
            print(f"Feedback workspace: {feedback_dir}", flush=True)
            httpd.serve_forever()
    except OSError:
        continue
    break
else:
    raise SystemExit(f"No free port found from {base_port} to {base_port + 49}")
PY
}

triage_feedback() {
  local slug="${1:-}"
  [ -n "$slug" ] || { usage >&2; exit 1; }
  require_task "$slug"

  feedback_init
  local feedback_dir
  feedback_dir="$(feedback_dir_for_slug "$slug")"

  command -v python3 >/dev/null 2>&1 || {
    printf 'python3 is required to triage feedback annotations.\n' >&2
    exit 1
  }

  python3 - "$feedback_dir" "$INBOX_DIR" "$slug" <<'PY'
import json
from pathlib import Path
import re
import sys
from datetime import datetime

feedback_dir = Path(sys.argv[1])
inbox_dir = Path(sys.argv[2])
slug = sys.argv[3]
annotations_file = feedback_dir / "annotations.json"
backlog_file = feedback_dir / "backlog.md"
roadmap_file = feedback_dir / "roadmap.md"
inbox_dir.mkdir(parents=True, exist_ok=True)

try:
    annotations = json.loads(annotations_file.read_text(encoding="utf-8"))
except Exception:
    annotations = []
if not isinstance(annotations, list):
    annotations = []

def next_fb_id():
    max_num = 0
    for path in inbox_dir.glob("FB-*.md"):
        m = re.match(r"FB-(\d{4})", path.name)
        if m:
            max_num = max(max_num, int(m.group(1)))
    return f"FB-{max_num + 1:04d}"

def slugify(text):
    value = re.sub(r"[^a-z0-9]+", "-", (text or "feedback").lower()).strip("-")
    return (value or "feedback")[:64]

created = []
backlog_lines = ["# Backlog Candidates", ""]
roadmap_lines = ["# Roadmap Candidates", ""]
for item in annotations:
    fb_id = item.get("feedbackId") or next_fb_id()
    item["feedbackId"] = fb_id
    title = item.get("comment") or item.get("target") or item.get("screen") or fb_id
    file = inbox_dir / f"{fb_id}-{slugify(title)}.md"
    coords = item.get("coordinates") or {}
    content = [
        f"# {title}",
        "",
        f"- ID: {fb_id}",
        "- Source: simulator-feedback",
        "- Status: inbox",
        f"- Related task: {slug}",
        f"- Screen: {item.get('screen', '')}",
        f"- Target: {item.get('target', '')}",
        f"- Evidence: {item.get('capture', '')}",
        f"- Coordinates: x={coords.get('xPercent', '')}, y={coords.get('yPercent', '')}",
        f"- testID: {item.get('testID', '')}",
        f"- Type: {item.get('type', '')}",
        f"- Severity: {item.get('severity', '')}",
        f"- Priority: {item.get('priority') or item.get('severity', '')}",
        f"- Owner lane: {item.get('ownerLane', '')}",
        f"- Related roadmap: {item.get('relatedRoadmap', '')}",
        "",
        "## Comment",
        "",
        item.get("comment", ""),
        "",
        "## Expected",
        "",
        item.get("expected", ""),
        "",
        "## Triage Notes",
        "",
        f"- Created: {datetime.utcnow().replace(microsecond=0).isoformat()}Z",
    ]
    file.write_text("\n".join(content) + "\n", encoding="utf-8")
    created.append(str(file))
    backlog_lines.append(f"- {fb_id} [{item.get('severity', '')}] {title} -> {item.get('ownerLane', '')}")
    if item.get("type") == "roadmap":
        roadmap_lines.append(f"- {fb_id} {title}")

annotations_file.write_text(json.dumps(annotations, indent=2) + "\n", encoding="utf-8")
backlog_file.write_text("\n".join(backlog_lines) + "\n", encoding="utf-8")
roadmap_file.write_text("\n".join(roadmap_lines) + "\n", encoding="utf-8")
for path in created:
    print(path)
PY
}

command="${1:-}"
shift || true

case "$command" in
  init) feedback_init; printf '%s\n' "$OPERATOR_DIR" ;;
  detect) detect_profile ;;
  start) start_feedback_task "$@" ;;
  capture-sim) capture_sim "$@" ;;
  record-sim-start) record_sim_start "$@" ;;
  record-sim-stop) record_sim_stop "$@" ;;
  review) review_feedback "$@" ;;
  triage) triage_feedback "$@" ;;
  -h|--help|"") usage ;;
  *)
    printf 'Unknown command: %s\n\n' "$command" >&2
    usage >&2
    exit 1
    ;;
esac
