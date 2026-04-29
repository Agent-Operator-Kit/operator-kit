# Cleanup Policy

Keep the repo evergreen.

Do commit:

- source code
- tests
- reusable scripts
- stable architecture docs
- stable operator policy
- durable product or release docs

Do not commit:

- raw task packets
- raw handoffs
- tmux captures
- one-off status notes
- local screenshots
- agent transcripts
- secrets or provider state

If generated state becomes useful, summarize the durable fact in a maintained doc and leave the raw file in the external operator workspace.
