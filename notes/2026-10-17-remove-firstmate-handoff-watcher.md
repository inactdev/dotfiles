# Removing the firstmate handoff watcher (what it was, what it left behind)

Until 2026-10-17 this repo shipped a personal-mac-only watcher that marked
firstmate crewmate tabs with an hourglass while their agent had handed off to a
background shell: `home/.local/bin/herdr-agent-handoff-marker` (plus its mocked
test), a `launchd.agents.herdr-agent-handoff-marker` block in `modules/mac.nix`
polling it every 5s, the `fm_handed_off_shell_running` rule and its `fixtures/`
tree under `home/.config/herdr/agent-detection`, and a `herdr-agent-state.sh`
`SessionStart` hook in `home/.claude/settings.json`. Firstmate is retired; all
of it is gone. `home/.config/herdr` itself stays - the daemon is still what the
captain's Fabrica setup drives.

Three things worth knowing, none visible from the diff alone:

- **The removal is declaration-only, by captain decision.** home-manager
  unloads a `launchd.agents` entry and removes its `mkOutOfStoreSymlink` files
  on the next `./run.sh rebuild` once they leave the config, so no activation or
  uninstall step was added. An hourglass still sitting on a tab label on a
  machine that ran the old watcher is cosmetic and cleared by hand - nothing
  rewrites it now.
- **An emptied directory can break the shellcheck floor.** Both
  `.github/workflows/ci-floor.yml` and `check.sh` listed `home/.local/bin/*`
  explicitly (the repo's deliberate "no broad globs, nothing silently skipped"
  style). Deleting the only two scripts there empties the directory, git tracks
  no empty directory, and an unmatched glob reaches shellcheck as a literal
  path and fails the job - so that entry had to go with the scripts. Re-add it
  only together with a new script.
- **The detection rule was deleted, not just orphaned.** `herdr`'s
  `agent-detection/claude.toml` is read by the live daemon, not by the watcher,
  so leaving `fm_handed_off_shell_running` in place would have kept
  reclassifying an idle Claude pane with a backgrounded shell as "working" for
  every herdr consumer, with nothing left that wanted that signal.

Still true about herdr automation if any is ever wanted again: a herdr plugin
(`herdr plugin ...`) cannot host it. Startup hooks are one-shot and must exit,
and `[[panes]]` are user-facing terminal surfaces, not hidden background
workers - continuous reaction needs an external script driven by a
`launchd.agents` entry, which is exactly the shape that was just removed. The
standing safety rule outlives the watcher: never run `herdr server
reload-agent-manifests`, `herdr tab rename`, or any other state-mutating herdr
command from a dev/test session, because the daemon is shared and live and it
repaints the owner's real tabs.
