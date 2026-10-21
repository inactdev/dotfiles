# A leading `PATH=...` in an activation step is a command name, not an assignment

`modules/fabrica.nix` and `modules/inspector.nix` each began their
activation step with

```nix
$DRY_RUN_CMD PATH="${syncPath}:$PATH" ${pkgs.bash}/bin/bash <script> ...
```

and neither sync script had ever run on a real machine. What is worth
keeping from fixing it:

**A shell only treats `VAR=value` as an assignment when it is the first
word at parse time.** Parsing happens before expansion, so the moment
anything precedes it the word is already classified as the command name,
and expanding that prefix to nothing afterwards does not reclassify it.
`$DRY_RUN_CMD` is empty on every real switch (it is only `echo` under
`--dry-run`), so every real `./run.sh rebuild` failed the step with

```
PATH=/nix/store/...: No such file or directory
```

exited 127, and was swallowed by the step's own
`|| echo "<tool>-sync exited non-zero; continuing activation."` backstop -
which is there deliberately, and which is exactly why nobody noticed.

**`run` does not fix this; `env` does.** `run` is home-manager's supported
replacement for the deprecated `$DRY_RUN_CMD`/`$VERBOSE_ECHO` variables
(deprecated in 24.05; upstream keeps them only for backward
compatibility). But `run` dispatches through `"$@"`, so a leading
`PATH=...` is still an argument rather than an assignment - swapping the
prefix alone reproduces the bug. The fix is both: `run` for the
deprecation, and `env` to apply the assignment regardless of where it sits
in the argument list. The line is now

```nix
run ${pkgs.coreutils}/bin/env PATH="${syncPath}:$PATH" ${pkgs.bash}/bin/bash <script> ...
```

`${pkgs.coreutils}/bin/env` rather than a bare `env`: coreutils is on
home-manager's own activation PATH so bare `env` would resolve, but the
absolute store path matches how both modules already name
`${pkgs.bash}/bin/bash`, and keeps the step independent of what
`home.extraActivationPath`/`home.emptyActivationPath` are set to.

Reordering to `PATH=... $DRY_RUN_CMD bash ...` was rejected: it is correct
on a real switch but wrong under an actual dry run, where the assignment
would apply to `echo` and the printed command would not be the one that
would really run.

**Nothing cheaper than a real activation can catch this class of bug.** An
activation step's text is only ever interpreted by a shell at activation
time. `nix eval` type-checks and renders the string; a hermetic bash test
can grep it; neither executes it. Every test in this repo passed for as
long as the bug existed. So `install.container-test.sh` grew a section
that runs an actual `home-manager switch`, and `flake.nix` grew
`homeConfigurations."ci-linux"` for it to switch:
`modules/core.nix` + `modules/fabrica.nix` + `modules/inspector.nix` +
`modules/linux.nix`, no `desktop.nix`, nothing Darwin-only or
secret-dependent.

Four things about that rehearsal that are decisions, not incidentals:

- **It runs last, as its own container user.** It needs the Nix the
  personal-posture install put in the container, and its own home-manager
  generation must not replace `codespace-personal`'s, which every
  personal-posture assertion is about.
- **`flake.nix`'s `ciUser` is a hardcoded literal** (`ci-activation`),
  not `builtins.getEnv "USER"` like the codespace outputs. home-manager
  refuses to activate when `$HOME` is not the `home.homeDirectory` its
  configuration was evaluated with, so that string and the `useradd` in
  `install.container-test.sh` have to stay equal - a literal makes the
  coupling checkable instead of environment-dependent.
- **Nothing is stubbed.** Both installs are public
  (`npm install -g github:inactdev/fabrica`,
  `go install github.com/inactdev/inspector/cmd/inspector@<commit>`) and
  need no credentials. Pointing them at fixtures would rebuild the failure
  mode the rehearsal exists to end.
- **A zero activation exit proves nothing on its own**, because of that
  `||` backstop. The assertions are therefore: nonzero exit; the backstop
  text appearing in the log; a `VAR=value` word reported as a missing
  command (`[A-Za-z_][A-Za-z0-9_]*=[^ ]*: No such file or directory`,
  scoped that way on purpose - a bare search for `No such file or
  directory` false-positives on anything git/go/npm legitimately says);
  each sync script's own `<tool>-sync:` prefix appearing at all; and the
  positive checks that `~/go/bin/inspector` and
  `~/.npm-global/bin/fabrica` exist, carry the right provenance, and are
  what a fresh login shell resolves.

Two sharp edges in the container for anyone extending this:

- `gcc` is now in the harness's apt list. Go leaves `CGO_ENABLED` on, and
  a bare `ubuntu:24.04` is the only host in this picture with no C
  compiler - macOS has clang from the Xcode command line tools, the home
  Ubuntu box has gcc from apt. Without it a `go install` failure would be
  a container artifact masquerading as a finding.
- `modules/linux.nix` without `modules/desktop.nix` writes a systemd user
  unit whose `ExecStart` (`~/.local/bin/dotfiles-auto-apply`) has no file
  behind it, because `desktop.nix` is what symlinks that. Harmless here:
  the container has no systemd user session, and both that module's own
  activation step and home-manager's `reloadSystemd` check for one and
  skip. It would matter if `ci-linux` were ever activated somewhere
  systemd is live.

**Same shape elsewhere.** `modules/desktop.nix`'s `installNerdFont` and
`modules/linux.nix`'s `startDotfilesAutoApplyTimer` still use
`$DRY_RUN_CMD`. They are *not* broken - every one of their commands starts
with a real command name (`mkdir`, `find`, `fc-cache`, `systemctl`), so an
empty expansion leaves a valid command line - but they are on the same
deprecated variable and were left alone deliberately to keep this change
scoped. The rule to remember when touching either: `$DRY_RUN_CMD` or `run`
in front of a bare `VAR=value` is always wrong; put `env` between them.
