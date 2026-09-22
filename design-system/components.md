# Components and behavior

All dimensions are proposed Operator values. Classes are a portable vanilla-CSS starter, not a framework dependency.

| Component | Anatomy and spacing | States and rules |
| --- | --- | --- |
| Project navigation | 200 px pane, 56 px header, 10 px side padding, 36 px rows, 16 px outline icons | Default, hover, selected, keyboard focus. Selection uses gray fill and text weight. Project switching must update all dependent panes and preserve view per project. |
| Feature/task queue | 280 px pane, 44 px toolbar, search, rows with 12–16 px padding | Loading, populated, no tasks, no search results, failed read. Each row exposes a real button/link name and selection state. Filters do not silently select a different task. |
| Task overview row | Title, feature, status, assignee and relative update time | Separate task outcome from worker activity. Unknown and stale are valid states. Never use a heartbeat as completion evidence. |
| Detail workspace | Flexible width; 24–32 px reading padding; roughly 65 characters maximum text measure | Selected, unavailable/deleted, no selection, stale snapshot. Keep previous successful content during refresh failures. |
| Outcome document | White surface, 1 px pale border, 12 px radius, 24 px padding | Outcome, criteria, latest result, next step. A checklist checkmark means a recorded criterion was met; speculative items use unchecked state. |
| Metadata inspector | 248 px pane; 20 px horizontal padding; 16 px property gaps | Status, assigned agent, feature, attempt identity, source/time. Show human sponsor/reviewer separately where available. Do not invent priority or cost defaults. |
| Attention item | Concrete question or review reason, owner, blocking consequence, primary action | Pending, being addressed, resolved. Resolving requires authoritative mutation success, not just closing the panel. |
| Worker attempt | Agent identity, activity, latest recorded action, age, output | Queued, running, waiting for human, blocked/failed, finished, unknown/stale. Retry creates an identifiable attempt. Show logs progressively. |
| Artifact row | 16 px icon, title, short description, disclosure/link | Real destination only. Display unavailable/permission error if access fails. Keep output provenance visible. |
| Action button | 36 px desktop, 44 px small/touch layout; 8 px radius; 12 px horizontal padding | Default, hover, focus, disabled, working, failed. Accessible label for icon-only buttons. Real runtime actions need pending/success/error feedback and their normal authorization rules. |
| Status label | 12 px text, small symbol and subtle colored background | State text always present. Color alone never conveys state. Avoid all caps. |
| Refresh notice | Inline banner with snapshot time, failure reason and Retry | Fresh, refreshing, stale, failed initial read. Use polite announcements; never steal focus when data arrives. |

## Responsive structure

- 1200 px and above: navigation + task queue + flexible detail + inspector.
- 900–1199 px: narrower navigation/list; inspector opens as an overlay. Its close control returns focus to its trigger.
- 640–899 px: list and detail; project navigation moves to a future accessible project-switcher control.
- Below 640 px: show queue or selected task, with a Back control restoring the row. Inspector can occupy most of the viewport. In production an overlay must trap focus and make the background inert, or use a native dialog.
- Compact inline MCP cards should summarize attention and open the full view. Actual host display-mode support must be verified.

The specimen illustrates these breakpoints. Its small-screen inspector is a non-modal panel with Escape/close support; production should upgrade it to a modal dialog if it blocks task interaction.

## Keyboard and refresh contracts

All interactive controls must be reachable with Tab and activate with standard keys. Use a visible 2 px focus ring with 3 px offset. Keep the selected task ID, scroll offset and keyboard focus across authoritative updates. If the task disappears, show an explicit unavailable state and retain a route back to the list. Announce arrivals without reordering the selected item beneath the reader.

The HTML preview is a component specimen with fixture refresh simulations. Production integration must exercise actual host return/remount, keyboard focus, two-project isolation, and source-revision updates.

## Collapsible navigation

At desktop widths (900 px and above), the sidebar header toggle switches between full labels and a 60 px icon rail. Labels remain accessible and icon items have hover titles. Toggling preserves task selection, theme and detail state. Below 900 px the existing responsive layout hides the sidebar.
