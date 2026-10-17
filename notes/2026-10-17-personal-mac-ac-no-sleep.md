# personal-mac: no-sleep on AC power (pmset, not power.sleep.*)

`configuration.nix` keeps personal-mac awake on mains power with a
`system.activationScripts.postActivation.text` step running
`/usr/bin/pmset -c sleep 0 disksleep 0`. Three facts behind that shape, none of
which are visible from the option names alone:

- **nix-darwin's `power.sleep.computer`/`.display`/`.harddisk` are the wrong
  tool for an AC-only policy.** They compile to `systemsetup -setComputerSleep`
  (see `modules/power/sleep.nix` upstream), which is power-source-agnostic - it
  would also stop the machine sleeping on battery - *and* `systemsetup`'s value
  takes precedence over pmset's per-profile `sleep` timers, so setting both
  would make the pmset line decorative. pmset's `-c` (charger) / `-b`
  (battery) / `-a` (all) split is the only per-profile knob.
- **The activate script runs as root under `env -i` with a minimal PATH**
  (coreutils + gnugrep only), so anything in `/usr/bin` must be called by
  absolute path. It also runs with `set -e`/`set -o pipefail`: a failing command
  in a `postActivation` fragment aborts the whole switch, so fragments should be
  idempotent (they run on every rebuild) and should not be casually wrapped in
  `|| true`, which would hide a real failure.
- **`postActivation` is the only supported extension point.** A custom
  `system.activationScripts.<myName>` is never executed - only the named
  fragments interpolated into `system.activationScripts.script.text` run - and
  the old `preUserActivation`/`postUserActivation`/`extraUserActivation`
  options now trip an assertion, since all activation happens as root.

Out of scope on purpose, in case someone later reports "it still slept":
`displaysleep` is untouched (the screen may still blank - that is not system
sleep), and lid-closed/clamshell sleep ignores the `sleep` timer entirely
(it needs `pmset -b disablesleep 1`, which nix-darwin exposes no option for).

Checking it without switching anything:
`nix eval --impure --expr '(builtins.getFlake (toString ./.)).darwinConfigurations.personal-mac.config.system.activationScripts.postActivation.text'`
shows the fragment; `pmset -g custom` on the host shows the applied values per
power source.
