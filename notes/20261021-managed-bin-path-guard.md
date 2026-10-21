# Making the managed Inspector/Fabrica the ones a shell finds

`modules/core.nix` now puts `~/go/bin` and `~/.npm-global/bin` on PATH
ahead of `~/.local/bin`, and both sync scripts end by calling
`guard_managed_binary` from the new shared `modules/managed-bin-guard.sh`.
What is worth keeping from doing it:

**`home.sessionPath` loses to `.zshrc`, always.** This is the whole bug. A
`home.sessionPath` entry ends up in `hm-session-vars.sh`, which
home-manager's zsh module sources *before* `programs.zsh.initContent`
runs, so `export PATH="$HOME/.local/bin:$PATH"` in core.nix put every
hand-dropped copy in front of every managed one. Nothing about
`modules/inspector.nix` or `modules/fabrica.nix` could fix that from where
they sit; the order is only decidable in the file that writes the last
line. Hence `modules/managed-paths.nix`, a plain function file (deliberately
**not** a module, and never in a `homeModules [...]` list - an extra module
reorders list-typed options and changes a host's drvPath for no change in
content) holding the one definition of both directories so core.nix can
name them without guessing.

**A non-interactive login shell is the wrong thing to ask.** `zsh -l -c`
never reads `.zshrc`, which is exactly where the PATH line under test
lives, so the probe uses `-l -i -c` - a login *and* interactive shell -
with stdin from `/dev/null` (compinit's insecure-directories question
would otherwise be able to block an activation) and from `cd /` (core.nix's
fnm hook reacts to the working directory, and `/` has no `.node-version`
above it). `env -i` with nothing but `HOME`, `TERM` and a minimal `PATH`
is what makes it *fresh* rather than a copy of the activation's own
environment, which carries Nix store paths no login shell would have.
`USER` is deliberately not passed: under `darwin-rebuild` it is not
reliably the activating user, and a wrong value is worse than none.

**Startup files write to stdout, sometimes without a trailing newline.**
The probe's markers are preceded by a `printf '\n'` for exactly that: a
`.zshrc` that prints a banner with no newline would otherwise glue its
output onto the front of the first marker line and hide it. Verified
against a real bash with such an rc file.

**Quarantine, not delete, and three things never touched.** A shadowing
copy under `$HOME` is moved to
`$XDG_CACHE_HOME/dotfiles-shadowed/<timestamp>/<path relative to $HOME>` -
mirroring the relative path both prevents collisions between two copies of
one tool and makes what was moved obvious from where it landed. Never
moved: anything outside `$HOME` (warned about instead), anything that
resolves into `/nix/store` (a nix profile's own bin directory lives under
`$HOME`, so moving it would corrupt the profile and the next switch would
put it straight back), and anything at all when the managed copy is not
installed (on a machine where today's install failed, the stale copy may
be the only one there is). A symlink that resolves *to* the managed copy
is not a shadow and is left alone - every comparison is between resolved
paths.

**The guard runs on the paths that install nothing.** Both sync scripts
were a flat sequence of `exit 0`s; they are now one `sync_to_remote_tip`
function of `return 0`s with the guard called after it. The quiet paths -
already current, no network - are precisely the ones where a stale copy
goes unnoticed for weeks, so they are the ones that must not skip the
check.

**Nix gives each script its own store path.** `modules/inspector-sync.sh`
cannot find `modules/managed-bin-guard.sh` by looking next to itself once
both are in the store, so the library's path is passed as the scripts'
second argument (defaulting to the sibling file, which is what a hand-run
out of a checkout wants). A missing library is a warning, not a failure,
like everything else in these scripts.

**Portability, since this has to behave identically on both hosts.** No
`realpath`, no `readlink -f` (BSD/macOS only got `-f` recently): the
resolver follows the final component's symlink chain with plain `readlink`
and normalizes the directory with `cd -P`/`pwd -P`. No associative arrays
either, so a hand-run under macOS's bash 3.2 works.

**Where it is not wired in.** `check.sh`, `.github/**` and `*.test.sh` are
protected paths (`.inspector.json`), so `modules/managed-bin-guard.test.sh`
exists (68 assertions, mocked login shells, scratch `$HOME`) but adding it
and the two sync scripts to `check.sh`'s and `ci-floor.yml`'s shellcheck
and test lists needs a captain-side pull request - the same gap
`notes/20261018-fabrica-home-manager-install.md` and
`notes/20261021-inspector-home-manager-install.md` already record for the
scripts themselves. Run it by hand with
`bash modules/managed-bin-guard.test.sh`.

**The bash half of the guarantee is a check, not yet a fix.** zsh gets the
PATH order from core.nix; bash has no managed startup file here at all
(`programs.bash.enable` would hand home-manager `~/.bashrc`, which already
exists on the Ubuntu box, and the standalone `home-manager switch` in
`run.sh` passes no `-b`, so the first apply after that would fail
outright). So on a machine whose bash startup files do not put `~/go/bin`
on PATH, the guard says so on every activation, loudly, by design -
answering question 2 of the brief's clarification: warn and exit 0, never
fail the apply. Managing bash's rc files is the fix, and it is a decision
about the captain's login environment, not a detail of this change.
