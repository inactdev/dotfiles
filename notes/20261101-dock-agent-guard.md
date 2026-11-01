# personal-mac: the Dock does not always come back from a switch

Applying `system.defaults` restarts the Dock, and on this macOS the restart
can be the end of it. What the log showed on 2026-11-01:

```
com.apple.Dock.agent exited due to exit(0)
... service inactive
```

launchd only revives a job that *died*; a clean exit is a job that meant it,
so the service was left inactive and the machine had no Dock and no Spaces
swiping until a restart - from a switch that reported success.
`modules/dock-agent-guard.sh`, called at the tail of
`configuration.nix`'s `postActivation`, is what notices that now. The
decisions worth keeping:

- **The uid has to be the primary user's, not the caller's.** The activate
  script runs as root, so `id -u` there is 0 and `gui/0` has no Dock in it.
  The guard takes the user *name* as its only argument - the same string
  `system.primaryUser` is set from, so the two cannot drift - and resolves
  `id -u <name>` itself. Any future activation step that talks to a GUI
  launchd domain needs the same treatment; `modules/inkwell-sync.sh` gets
  away with a bare `id -u` only because home-manager's activation runs as
  the user.
- **"Running" means `launchctl print` reported a pid.** Same predicate
  `modules/inkwell-sync.sh` already uses: `print` shows `pid = <n>` for a
  running job and no pid for one that is merely loaded. Positive evidence
  only, on purpose - a `print` that fails outright *and* a `print` with no
  pid both count as not running, because asking launchd to start a Dock
  that is already up costs nothing, while believing a dead Dock is alive is
  the whole bug. `kickstart` is therefore never given `-k`: killing a
  healthy Dock on every rebuild would recreate the failure instead of
  fixing it.
- **The kickstart's exit status is only a message.** What decides is
  whether a pid appears afterwards, so a kickstart that reports failure
  while the Dock comes up anyway is a success, and one that reports success
  while nothing starts is not. launchctl's own words are passed on in the
  warning rather than interpreted.
- **Two seconds, twice.** Each attempt looks for a pid at once, then waits
  two seconds and looks again - which is also what makes "the Dock came
  back by itself" a success rather than a false warning. The retry (one,
  after that wait) is cheap next to leaving the machine without a Dock, and
  four seconds in the worst case is the price of never crying wolf.
- **It exits 0 on every path, including the one where it gives up.**
  Everything else in the switch has already been applied by the time this
  runs; a non-zero exit would wrongly read as "the switch did not happen".
  A Dock it could not start is reported instead, naming
  `launchctl kickstart gui/<uid>/com.apple.Dock.agent` as the command to run
  by hand. It says nothing at all on the happy path, so the rebuild output
  only grows a line on the rebuilds where the Dock actually went missing.
- **`lib.mkAfter`, so the warning is not buried.** The whole
  `postActivation` fragment is now a `lib.mkAfter` definition: that places
  it behind every ordinary definition of the same option - home-manager's
  darwin module contributes one too - which is as close to "the last thing
  the rebuild prints" as a declarative step gets. Ordering *within* the
  merged option is all that can be controlled from here; nothing stops a
  later `mkAfter` definition from printing after this one.

**Same shape elsewhere, deliberately left standing.** Each of these also
stops and restarts something during a switch without anything afterwards
checking that it came back; none has been seen to fail, and widening this
change to them would have been guesswork:

- nix-darwin's same defaults step restarts **Finder and SystemUIServer**,
  which could in principle exit cleanly for the same reason. Only the Dock
  has been seen to, and only the Dock is guarded.
- `modules/mac.nix`'s **dotfiles-auto-apply** launchd agent is booted out
  and back in by home-manager whenever its plist text changes; a failure to
  come back would be silent until the next login.
- `configuration.nix`'s **ollama** brew has `restart_service = "changed"`,
  and Homebrew's restart is likewise unverified.
- `modules/inkwell-sync.sh`'s `ensure_agent` is the one place that already
  carries this guard itself - it checks for a pid and starts the agent when
  it is loaded but not running - which is where the predicate above came
  from.

Checking it without switching anything:
`bash modules/dock-agent-guard.test.sh` covers the decisions against a
mocked `launchctl`/`id`/`sleep` (including the retry, the give-up warning
and the "came back by itself" path), and
`nix eval --impure --expr '(builtins.getFlake (toString ./.)).darwinConfigurations.personal-mac.config.system.activationScripts.postActivation.text'`
shows the fragment that calls it. Neither runs the step: an activation
step's command line is only ever interpreted by a shell at activation time
(see `notes/20261021-activation-step-env-path.md`), so the first real proof
is a rebuild on the Mac.
