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

- `gcc` is in the harness's apt list as insurance, not as a requirement.
  The `go install` now runs with `CGO_ENABLED=0` (see below), and an
  apt-installed compiler would be invisible to that step anyway, because
  an activation step only sees the store packages its module puts on PATH.
  It stays so that a dependency falling back to building a native addon
  cannot fail for a container-only reason.
- `modules/linux.nix` without `modules/desktop.nix` writes a systemd user
  unit whose `ExecStart` (`~/.local/bin/dotfiles-auto-apply`) has no file
  behind it, because `desktop.nix` is what symlinks that. Harmless here:
  the container has no systemd user session, and both that module's own
  activation step and home-manager's `reloadSystemd` check for one and
  skip. It would matter if `ci-linux` were ever activated somewhere
  systemd is live.

Two things the rehearsal itself needed, both worth knowing before writing
another one:

- **`docker exec -u <user>` does not set `USER`, and home-manager's command
  reads it under `set -u`.** A switch started that way dies with
  `home-manager: line NNN: USER: unbound variable` before any activation
  step runs - and because that happens before the steps, every assertion
  about them fails for a reason unrelated to what it checks. Pass
  `-e USER=<user>` (and `-e HOME=<that user's home>`, which also has to be
  the `home.homeDirectory` the configuration was evaluated with, or
  home-manager refuses outright). `install.sh` names `USER` for its own
  codespace switch for the same reason.
- **nixfmt expands a binding whose value is an attribute set with one
  `name = value;`, but leaves one with a single `inherit x;` inline.** So
  `extraSpecialArgs = { inherit user; };` passes `nixfmt --check` while
  `extraSpecialArgs = { user = ciUser; };` fails it, and the fix is the
  three-line form. It is not a width rule: nixfmt's `absorbRHS` carves out
  "exactly one inherit statement" as the only non-expanding case, so
  copying a neighbouring single-line attrset is only safe when the thing
  being copied is also a lone `inherit`. Worth knowing because
  `nixfmt --check` runs in CI and the formatter is not on every machine.

**What the rehearsal found once the steps actually ran.** Four things, and
only the second one was about PATH at all.

- **`npm install -g <git spec>` is broken by npm, for everyone.** npm
  clones the spec into a temporary directory of its own under
  `~/.npm/_cacache/tmp`, and in global mode installs that clone by
  *symlinking* the prefix at it and then deleting the clone - so a
  lifecycle script (the package's own `prepare`, esbuild's `postinstall`)
  is asked to run in a directory that is already gone. The error it
  surfaces as is `npm error enoent spawn sh ENOENT`, which reads like a
  missing shell and is not one: it reproduces with `/bin/sh` and
  `/bin/bash` both present, and `--ignore-scripts` merely trades it for a
  dangling symlink to a deleted `git-cloneXXXX` directory with no
  `node_modules` under it. Do not chase the shell. The two-step install is
  the fix: `npm pack <git spec> --pack-destination <dir>` (same clone, same
  `prepare`, so build artefacts still ship) and then
  `npm install -g <dir>/<name>-<version>.tgz`, which is an ordinary
  tarball install into real files.
- **`go` leaves cgo on, and no C compiler is in the store PATH.**
  `go install` stopped with `cgo: C compiler gcc not found` on a container
  that had gcc installed, because an activation step's PATH is only the
  store packages its module lists. Inspector is pure Go, so
  `modules/inspector-sync.sh` sets `CGO_ENABLED=0` on the install - no
  compiler needed on any host, and nothing to be visible or not.
- **A step that reads the new generation's files belongs after
  `linkGeneration`, not after `writeBoundary`.** The two are not the same
  point: `writeBoundary` is where a step is first allowed to touch the
  user's files, and `linkGeneration` - a later entry in home-manager's own
  activation DAG - is what actually symlinks them into `$HOME`. Both sync
  steps end by asking a fresh login shell what `command -v <tool>`
  answers, so ordered after `writeBoundary` they ran before any `.zshrc`
  existed on a home directory being switched for the first time, found
  nothing, and reported a managed tool that no shell could see.
  `lib.hm.dag.entryAfter [ "linkGeneration" ]` is the right place for
  anything that reads what the generation just linked.
- **`home.sessionPath` reaches bash only if `programs.bash` is enabled.**
  home-manager exports the session path from
  `hm-session-vars.sh`, and the only thing that sources it for bash is the
  `~/.bash_profile`/`~/.profile` pair that `programs.bash` writes - so with
  bash unmanaged, `~/go/bin` and `~/.npm-global/bin` were on zsh's PATH
  (from `modules/core.nix`'s own line) and on nothing else. Two details
  that matter when enabling it: the export *prepends*, so managed copies
  come ahead of what was already on PATH without anything being spelled
  out by hand; and the module writes `~/.bashrc`, `~/.bash_profile` and
  `~/.profile`, which home-manager refuses to overwrite as existing
  regular files unless the switch carries a backup extension (`-b
  hm-backup`, as `install.sh` passes and personal-mac's
  `home-manager.backupFileExtension` sets - `./run.sh`'s home-linux switch
  does not).

**Same shape elsewhere.** `modules/desktop.nix`'s `installNerdFont` and
`modules/linux.nix`'s `startDotfilesAutoApplyTimer` still use
`$DRY_RUN_CMD`. They are *not* broken - every one of their commands starts
with a real command name (`mkdir`, `find`, `fc-cache`, `systemctl`), so an
empty expansion leaves a valid command line - but they are on the same
deprecated variable and were left alone deliberately to keep this change
scoped. The rule to remember when touching either: `$DRY_RUN_CMD` or `run`
in front of a bare `VAR=value` is always wrong; put `env` between them.

`startDotfilesAutoApplyTimer` is also on the ordering shape above, and
still is: it runs `systemctl --user start dotfiles-auto-apply.timer` after
`writeBoundary`, while the unit file it names is one of the files
`linkGeneration` links. On a first-ever switch the start therefore comes
before the unit exists, and the step says so and carries on ("it starts on
the next login"), which is why this has never looked like a failure - the
next activation starts it. Moving it after `linkGeneration` would make the
first switch start it too.
