# Onboarding install flow — test harness

A committed, static browser harness for the **proposed** Operator install
experience in Codex. It exercises one boundary end to end:

1. an explicit GitHub instruction pasted into a fresh Codex session;
2. a Codex-owned install starting screen;
3. the install receipt, the ownership handoff, and Operator's first message.

**This is not a Codex surface.** Nothing here installs, fetches, reads, or
changes anything — every control moves local DOM state. The harness says so on
screen, and it stops at an explicit *Next implementation slice* notice rather
than pretending project setup exists.

## Running it

No build step and no dependencies. Serve `site/` and open the harness directly:

```bash
python3 -m http.server 0 --directory site   # prints the port it chose
# then open http://localhost:<port>/onboarding-v5-3/
```

Opening `index.html` from the filesystem also works; only the Clipboard API
degrades (see below).

## Entries and steps

The URL is shareable, so a reviewer can link to a specific frame.

| Parameter | Values | Meaning |
| --- | --- | --- |
| `entry` | `github` (default), `plugin` | which acquisition path opened the flow |
| `step` | `entry`, `screen`, `installed`, `next` | which frame to render |

- `?entry=github` — the instruction sits in the composer, selectable, with
  `Send to Codex`. Sending resolves the source and opens the install screen; it
  installs nothing.
- `?entry=plugin` — the same install screen, opened directly, marked as a future
  Codex entry. The catalog itself is deliberately not designed; only its output
  is represented.
- An invalid or missing `step` falls back to the entry's own first frame
  (`entry` for GitHub, `screen` for plugin).
- The transient `installing` and `checking` steps are never written to the URL,
  so a shared link always reconstructs a settled transcript instead of replaying
  the wait.

A dashed **prototype entry switch** sits above the mock window so a reviewer can
flip between the two entries without editing the URL. It is labelled as not part
of the design.

## State model

`app.js` holds two variables — `entry` and `step` — and one `render()` that
derives everything else. All turns are authored in `index.html` and revealed per
step, so first paint is meaningful and every bubble, card, marker, source row,
and list stays independently selectable for browser annotation.

```text
entry ──send/open──▶ screen ──install──▶ installing ──(750ms)──▶ installed
  ▲                    │                                            │
  └──────cancel────────┘                                          check
                                                                    ▼
                       next ◀──(900ms)── checking
                        │
                        └──────────restart──────────▶ back to the entry's first frame
```

- `entry` — pre-install frame. GitHub: the pasted instruction. Plugin: an
  *Operator is not installed* frame with `Open install screen`.
- `screen` — the Codex-owned install screen, tagged `Proposed Codex install
  screen`. Its two actions live on the card, because a host-owned install
  surface owns its own decision; the composer says so instead of duplicating
  them. `Cancel` returns to the correct pre-install frame for the current entry.
- `installing` — a short local state with no network access. Under
  `prefers-reduced-motion` the spinner does not animate and the state is shorter.
- `installed` — Codex receipt (source plus `Repository unchanged`), then the
  structural handoff marker, then Operator's first message. Operator renders
  nothing before that marker.
- `checking` — a pending reply. The user's choice is appended as a chat message,
  the triggering action is replaced in place by a disabled echo of itself, and an
  Operator turn in a dashed bubble says the check is read-only. Everything above
  it stays visible.
- `next` — the honest end of this slice. Operator's final message is tagged
  `Test harness`, states that the check was simulated, and carries `0 files
  read` / `0 files written` / `Nothing ran` chips.

Replies arrive the way a conversation grows: each step reveals more of the
transcript and never replaces what came before. Turns are authored once in the
markup and revealed per step rather than cloned, so a repeated activation cannot
duplicate a message; the click handler additionally ignores input while a reply
is pending.

`Restart test` returns to the current entry's first frame without a reload.

## Ownership boundary

Operator cannot speak before it is installed, so the harness makes that
structural rather than decorative:

- Codex branding in the topbar plus an `Operator not installed` chip;
- a rail split into a Codex band and a dimmed Operator band;
- a composer owner tag reading `Codex` until installation, `Operator` after;
- one handoff marker in the thread, which no Operator-authored turn precedes.

The install screen is authored by Codex — Codex avatar, `Codex` speaker tag —
even though it advertises Operator. The host vouches for the source.

## Accessibility and rendering notes

- Semantic buttons, headings, lists, and `<dl>` source rows; one `role="status"`
  live region restates every transition — send, cancel, install, restart, copy,
  and the not-yet-implemented next slice.
- Focus moves to the newly appended turn while a reply is pending, and otherwise
  to the action the user is expected to reach next, so a keyboard user is not
  dropped on `<body>` when the pressed control disappears. All interactive
  elements have a visible `:focus-visible` outline.
- Auto-scroll uses `scrollIntoView({ block: 'nearest' })` with a
  `scroll-margin-bottom` that clears the sticky composer: it brings the newest
  turn into view and moves no further. First paint does not scroll at all.
- Icons are an inline `<svg>` sprite referenced with `<use>` — no CDN, so no
  glyph can fail to load. There is no `src` or `href` to any external resource,
  no iframe, no remote font, and no fetch.
- Light and dark via `color-scheme` and `light-dark()`; responsive at a ~757px
  sidebar and 360px mobile width.
- `history.replaceState` and the Clipboard API are both wrapped in `try`/`catch`.
  Where copying is refused, the button falls back to `Select to copy` and the
  live region explains that the instruction is `user-select: all` — one click
  selects the whole string.
- No Operator vocabulary before the handoff: no graph, lane, worktree, dispatch,
  or feature session appears in user-facing copy.

## Deliberately not covered

Only the success path is built. There is no failure, refusal, offline,
already-installed, or already-set-up state, and no project setup: the read-only
check, the setup preview, and the approval step belong to later slices. The
copy and the `Next implementation slice` notice both say so.

Design reference: the FS-0008 `proposal-b-fresh-install` exploration. That
artefact is an exploration; this harness is the smaller committed translation of
it, not a copy of every exploratory state.
