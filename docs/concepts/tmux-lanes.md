# tmux Lanes

tmux provides persistent agent terminals.

Each lane maps to a tmux window named after the lane:

```text
operator
backend
ui
release
product
```

The operator can dispatch task packets into a lane, collect pane output, and restore visibility after restarts.

The kit uses tmux windows rather than complex pane layouts by default because windows are portable and easier to script.
