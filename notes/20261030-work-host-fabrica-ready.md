# The work host goes fresh Mac -> working Fabrica in one bootstrap

Four separate things, one goal: after `./run.sh bootstrap work`, the only
work left on a brand-new work Mac is the two steps a script is not allowed
to do for you (a browser OAuth login and a GUI app install from
Self-Service), and the closing summary names both.

## Decisions taken, and the alternatives rejected

**Pinning Node for `fabrica` only, at the launcher, with `fnm exec`.**
`~/.local/bin/fabrica` is no longer npm's own shim but a small generated
`sh` launcher that ends in

```sh
exec "$FNM" exec --using=24.18.0 node "<entry>" "$@"
```

`fnm exec --using=<version> <command>` is fnm's documented way to run one
command on one version without touching the shell's state
(`docs/commands.md`: `fnm exec --using=v12.0.0 node --version`). Two
alternatives were rejected:

- *Embedding the absolute path of the pinned `node`* (resolvable at install
  time with `fnm exec --using=... node -p process.execPath`). Shorter, and
  it would not need fnm at run time - but it depends on fnm's internal
  `node-versions/<v>/installation/bin` layout surviving, which fnm
  documents nowhere, and it pins only the *first* process: `fnm exec` also
  puts the pinned version first on `PATH` for the whole child process tree,
  so anything Fabrica itself shells out to as `node` gets 24.18.0 too.
- *Setting `fnm default 24.18.0` and leaving npm's shim alone.* That is
  exactly the thing the brief rules out: a `fabrica` run inside a
  repository that declares its own `.node-version` would pick that
  repository's version, because `fnm env --use-on-cd` in `work/zshrc` will
  have switched the shell before `fabrica` is ever resolved.

The entry script the launcher execs is read out of npm's own freshly
created shim (resolved through its symlink chain) rather than guessed from
`lib/node_modules/fabrica/package.json`, so npm stays the one authority on
where its own package put its CLI.

**Clearing `~/.local/bin/fabrica` immediately before `npm install -g`.** Not
cosmetic, and not optional: npm's bin linker refuses to link a global bin
over a path it does not already own. `bin-links`' `check-bin.js` rejects
with `EEXIST: file already exists` for a global, top-level install unless
the existing target is a symlink that resolves into the package being
installed - and our launcher is a real file, so the *second* bootstrap on
any machine would fail the Fabrica install without this. The alternative,
`npm install -g --force`, buys the same single exemption by switching off
every other check npm has ("recklessly overwrite files", per npm's own
config docs), so it was rejected. The existing launcher is *moved aside*
(to `fabrica.pre-bootstrap.$$`) rather than deleted, and moved back if the
`npm install -g` then fails: before this step existed, a failed install
simply left the working copy alone, and that is still the right outcome on
a machine in the middle of real work. A successful run removes the saved
copy, so nothing is left behind either way.

**`fnm install` is gated on a probe, not run blind.** `fnm install <v>` on
an already-installed version exits non-zero (`VersionAlreadyInstalled`),
and this script must stay re-runnable, so the version is probed first with
`fnm exec --using=<v> node --version` - the same documented command the
launcher uses, so the probe proves the launcher's own command line works
rather than merely that a directory exists.

**`work/zshrc` gets the plain `fnm env --use-on-cd` eval, not the
`--version-file-strategy=recursive` block from `modules/core.nix`.** The
recursive variant needs the `_fnm_autoload_hook` redefinition documented in
`notes/20261017-fnm-node-version.md` to stay quiet and to auto-install, and
that is zsh-specific machinery in a file that is also the Codespaces work
posture's `~/.zshrc`. The default `local` strategy keeps fnm's own
`[[ -f .node-version || -f .nvmrc ]]` guard, so the work Mac switches on
`cd` into a project root and stays silent everywhere else. What it does not
do is pick up a version file in a *parent* directory, or install a version
it has never seen; both are deliberate, and neither can affect `fabrica`,
which is pinned at the launcher precisely so the shell's current version
cannot reach it.

**fnm is a work-Mac-only Brewfile entry.** `work/Brewfile` is also the
*intent* for `work/codespace-bootstrap.sh`, which normally means a new line
there needs a matching apt/npm/binary install in that script. Not here: the
codespace work posture deliberately installs neither Fabrica nor Inspector
(a container is where work gets done, not where it gets dispatched from), so
there is nothing in a codespace for a pinned Node to be pinned *for*. The
Brewfile comment says so, so the next person does not "fix" the asymmetry.

## `~/.fabrica` is placed, never overwritten

`install_fabrica_home` creates `~/.fabrica` (0700), an empty `brain.env`
(0600) and a `projects.toml`, and is append-only by construction:

- `brain.env` is only created when absent. It is the file that holds
  `CLAUDE_CODE_OAUTH_TOKEN`, so a bootstrap that truncated it would destroy
  a working machine's credential. Its mode is re-asserted on every run
  (that is permissions, not content).
- `projects.toml` grows a `[caps]` block and a `[reader]` block only when
  that block's header is absent. Existing lines - including different
  values inside a block that is already there - are left exactly as they
  are. This was the explicit answer to the brief's clarifying question:
  append the missing blocks, do not reconcile keys inside existing ones.
- `append_toml_block` adds a newline first when the file does not end in
  one (otherwise `[caps]` would be glued onto a hand-written last line) and
  a blank separator line when the file is non-empty.

The values (`perTaskUsd = 20`, `perDayUsd = 200`, `vendor = "claude-code"`,
`model = "sonnet"`) are written as plain TOML - bare integers, quoted
strings - which is the only shape the brief's numbers and names can take.

## The two human-only steps are reported, not attempted

`check_fabrica_token` looks for an assignment of `CLAUDE_CODE_OAUTH_TOKEN`
with a non-empty value in `~/.fabrica/brain.env` (an `export ` prefix is
accepted), and nothing else: it never reads, prints, or logs the value.
When it is missing the summary says to run `claude setup-token` and where to
put the result. It is conditional on absence rather than printed every run
for the same reason the git-identity and Docker lines are - the summary is
a to-do list, and a to-do list that relists finished work gets ignored.

`claude setup-token` is a browser OAuth flow and Self-Service is a GUI app:
neither can be driven from a bootstrap, which is why these two are the only
things left in the summary on a machine that otherwise applied cleanly.

## The same shape elsewhere, deliberately left alone

`modules/fabrica.nix` + `modules/fabrica-sync.sh` install Fabrica on
personal-mac and home-linux the same three-step way, and there
`~/.npm-global/bin/fabrica` (the prefix `modules/managed-paths.nix` defines)
is still npm's own shim - `modules/managed-bin-guard.sh` even asserts that a
login shell finds exactly it. So those hosts keep the exposure this change
removes from the work Mac: `cd` into a repository with its own
`.node-version`, run `fabrica`, and it runs on that version. They also get
no `~/.fabrica`. Both were left as they are: the brief scoped this to the
work host, and porting the launcher there means teaching the managed-bin
guard that the thing on PATH is deliberately not the npm shim it checks
for - a separate change with its own test surface. If it is ported, the
`rm`/`mv`-aside dance before `npm install -g` has to come with it, for the
EEXIST reason above.

## An explicit host is remembered too

`resolve_host` now writes `.dotfiles-host` on the explicit-host and bare
`--no-nix` paths, through the same `remember_host` helper `choose_host`
uses, so `./run.sh bootstrap work` once is enough and every later
`./run.sh rebuild` targets the work host with no flag. The details worth
keeping:

- It is in `resolve_host`, so `plan`/`rebuild`/`bootstrap` all behave the
  same way. A host named on the command line is a statement about the
  machine, not about one command.
- The write is a no-op when the marker already holds that exact answer, and
  a failed write warns instead of aborting. Remembering is a convenience;
  a read-only checkout must not lose the ability to bootstrap over it.
- `work` on Linux is the one resolution that is deliberately *not*
  recorded: `cmd_bootstrap_no_nix` rejects it a moment later (there is no
  work-linux host), so remembering it would leave every later flagless
  `./run.sh` resolving to a host that can only fail. `choose_host` has
  always refused to write the marker for that same answer from the menu.
- `MARKER` now honours `DOTFILES_HOST_MARKER` from the environment, for one
  reason only: `run.test.sh` runs the real `run.sh` end to end, and that
  script computes `MARKER` from its own directory - so without the override
  those tests would rewrite the remembered host of whatever checkout the
  suite was run from, which on the owner's machine is the live
  `~/.dotfiles`. Same precedent and same justification as
  `work/bootstrap.sh`'s `DOCKER_APP`. Nothing in normal use sets it.

## Testing

`work/bootstrap.test.sh` mocks `fnm` (logging every call, faking
`exec --using=... node --version` against a fixture that says which
versions are "installed", and failing on demand) alongside the existing
`brew`/`npm`/`go`/`git`/`defaults`/`gh` mocks, and the `npm` mock now also
creates the package directory and the bin symlink real npm would, which is
what lets the launcher's entry-resolution be exercised end to end. Nothing
reaches a real fnm, a real registry, or the network. `run.test.sh` covers
the marker write on the explicit paths.
