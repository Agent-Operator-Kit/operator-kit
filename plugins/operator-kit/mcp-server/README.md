# Operator Console POC

A single project cockpit served as an MCP App. The plugin bundles the server and UI; Node 20+ is needed to run the server. The current POC uses local Operator records and an explicit project root.

## Build and test

From this directory:

```sh
npm ci
npm run build
npm test
```

`dist/server.mjs` and `dist/console.html` are bundled distribution artifacts. Build after source changes. Protocol tests run against the bundle and isolated temporary projects using the canonical graph runtime.

## Tools and resource

- `operator_console({projectRoot})`: opens `ui://operator/console-v2.html` and returns a complete snapshot.
- `operator_console_refresh({projectRoot, projectId, sinceRevision, capacity})`: reads the same project; unchanged data returns an acknowledged revision and timestamp. No new rendering resource is attached.
- `operator_console_save_view({projectRoot, projectId, view})`: app-only tool that stores local presentation preferences. It cannot dispatch work or change graph state.

Always pass the exact absolute directory containing `operator.config.env`, which can be outside the source checkout. The POC never falls back to a previous project or scans sibling checkouts. `OPERATOR_PROJECT_ID` can provide an explicit identity; otherwise the ID is derived from the canonical local root and changes if the project moves. This fallback is not a shared-team identity.

View preferences live under `OPERATOR_DIR/console/views/`, separated by local home-directory hash. This provides local-user presentation persistence, not an authenticated multi-user service. Business revisions exclude those preferences. No project records are stored in installed plugin caches.

## Data semantics

Eligibility comes from the project's installed `scripts/operator_local_graph.py frontier --capacity ... --json`. Missing or failed canonical runtime produces unavailable eligibility, never a substitute readiness algorithm. Feature/task statuses and attention items are recorded Operator facts. A tmux window is reported only as window presence; worker execution remains unknown without a run adapter.

Connected tasks publish changes through existing Operator graph/feature workflows. The UI polls every four seconds while visible, revalidates on return, avoids overlapping reads, and backs off on errors. It preserves the last good snapshot on failure. A malformed record returns an error rather than an empty success. Manual refresh is available for recovery. Long-lived production deployments should add async/bounded data reads, a schema migration strategy and stronger capability scoping before adding remote access.

## Native acceptance

Install/enable this plugin source through the supported Codex plugin workflow, then open it with an explicit initialized Operator root. Verify the tool is in the task's callable inventory before expecting a card. A server listed as enabled or a resource returned over stdio does not prove native UI rendering.

Test: initial render; internal task selection; a graph change made by a second process; automatic update without another user message; stale/recovery behavior; view restoration after remount; project isolation. Only the render tool should open a card. Read and view-save tools must be available to the app for polling and restoration to work.

`Open Codex task` requests navigation through the host conversation. The POC does not claim direct navigation, cross-task persistent visibility, shared questions/knowledge, or live worker telemetry. These require separately verified host or service contracts. An iframe development host is useful protocol evidence but is not native Codex acceptance.
