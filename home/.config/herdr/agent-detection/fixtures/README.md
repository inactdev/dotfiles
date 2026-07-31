# fm_handed_off_shell_running fixtures

Example terminal snapshots demonstrating the intended match behavior of the
`fm_handed_off_shell_running` rule in `../claude.toml`. Documentation only -
not wired into an automated test, because `herdr agent explain --file`
evaluates against the *running server's cached manifest*, not the file on
disk, so a committed test would need a live `herdr server
reload-agent-manifests` on every run to mean anything. That reload affects
the real, shared herdr daemon, so it isn't something a test should do
unattended.

To check a fixture by hand against the live rule engine:

```sh
herdr server reload-agent-manifests   # picks up any local claude.toml edit
herdr agent explain --file home/.config/herdr/agent-detection/fixtures/<name>.txt --agent claude --json \
  | jq '.evaluated_rules[] | select(.id == "fm_handed_off_shell_running")'
```

`--file` mode is read-only against static text - it does not touch any real
pane, tab, or session state.

| fixture | expected `matched` |
|---|---|
| `match-still-running-singular.txt` | `true` - "1 shell still running" |
| `match-still-running-plural.txt` | `true` - "N shells still running" |
| `match-footer-singular.txt` | `true` - status-footer form, "· 1 shell ·", no "still running" text |
| `match-footer-plural.txt` | `true` - status-footer form, "· 2 shells ·" |
| `no-match-prose-seashells.txt` | `false` - "seashells" contains "shells" but not the footer or "still running" form |
| `no-match-prose-shell-scripts.txt` | `false` - "shell scripts" contains "shell" but not either matched form |
