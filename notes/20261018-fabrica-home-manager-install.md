# Fabrica via home-manager activation: why the commit check looks like that

`modules/fabrica.nix` + `modules/fabrica-sync.sh` install Fabrica on
`personal-mac`/`home-linux` and keep it level with `origin/master`,
reinstalling with `npm install -g github:inactdev/fabrica` only when the
installed commit differs. Four things about that are not obvious from the
code, and one of them cost an experiment to establish.

**npm records nothing about the commit a global git install came from.**
This was the first design (ask npm what is installed, compare, done) and
it cannot work. Verified empirically with npm 11 by installing a local
`git+file://` package into a scratch `--prefix`: no
`node_modules/.package-lock.json` is written for a global install, the
installed `package.json` is the repo's own file verbatim (no `_resolved`,
no `gitHead`), and `npm ls -g --json --long` reports `version`/`path` and
nothing resolved. So the installed commit has to come from somewhere else
entirely - hence the two sources the script reads, in order:

1. Fabrica's own build info (`build-info.json` at the installed package
   root, or under `dist/`), which stays correct no matter who installed
   the copy. The parse is deliberately forgiving - any key matching
   `commit|sha|rev` holding a 7-40 character hex string, at any depth -
   and comparison allows either side to be abbreviated.
2. Failing that, a commit this script recorded itself under
   `$XDG_STATE_HOME/fabrica-sync/installed-commit` the last time it
   installed.

If neither answers, the copy counts as unknown and is reinstalled once,
which establishes source 2 for every switch after it. That is the whole
reason the state file exists: it makes the step correct even where the
build-info read finds nothing, at a cost of at most one redundant
install. The same fallback absorbs a `fabrica update` done by hand
without build info to show for it - one extra reinstall on the next
switch, then quiet.

**`npm install -g` has nowhere to write on a Nix host by default.** npm's
default global prefix is the `nodejs` package's own store path, which is
read-only. The module therefore owns `~/.npm-global` and passes it with
`--prefix` (CLI beats every `.npmrc`), putting `<prefix>/bin` on PATH via
`home.sessionPath`. It deliberately does *not* export `NPM_CONFIG_PREFIX`
for interactive shells: a pinned npm prefix is exactly what Node version
managers refuse to work alongside (nvm errors out on it outright), and
`modules/core.nix` runs fnm on every `cd`.

**Activation must not be able to fail a switch.** Every failure path in
the script - unreachable remote, no credentials, missing branch, npm
erroring - warns on stderr and exits 0. `GIT_TERMINAL_PROMPT=0` keeps a
private-repo credential prompt from blocking a non-interactive switch
forever, and `-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15` keeps a
half-open connection from hanging it instead. The `|| echo` in the
activation entry is only a backstop for an unexpected non-zero exit.

**The script is a `.sh` file run through `${pkgs.bash}/bin/bash`, not a
`pkgs.writeShellApplication`.** writeShellApplication is the tidier
spelling and runs shellcheck at build time, but that check runs during
`darwin-rebuild`/`home-manager switch` and not in CI (`ci-floor.yml`
evaluates, it does not build), so a shellcheck finding would surface as a
broken switch on the captain's machine rather than as a red PR. A plain
file keeps shellcheck where this repo already runs it, over real files.
It is not in `check.sh`'s or `ci-floor.yml`'s path lists yet: both are
protected paths, so adding `modules/fabrica-sync.sh` there has to come
from a captain-side PR.
