# Packing a `github:` spec loses the commit, and `npm link` leaves more than a shim

Two things about the Fabrica install in `modules/fabrica.nix` that were
wrong in ways nothing failed over, both found through `fabrica doctor`
rather than through any exit status.

**`npm pack github:owner/repo` does not clone, so there is no `.git` to
read.** For a hosted-git spec npm fetches GitHub's tarball of the tree
(codeload) instead of cloning it. Fabrica's `prepare` is
`scripts/write-build-info.mjs`, and all it does is write
`git rev-parse HEAD` into `build-info.json` - so with no repository in
the packed tree it writes `{"commit":null}`. Every command still exits 0:
pack succeeds, `npm install -g` of the tarball succeeds, the activation
reports an install, and the only symptom is `fabrica doctor` refusing to
start work on a machine that was switched successfully an hour ago. The
fix is for `modules/fabrica-sync.sh` to do its own
`git clone --depth 1 --branch master` into the temporary directory it
already made, run `npm pack` with no spec inside that clone (npm's
documented behaviour: "if no arguments are supplied, then npm packs the
current package folder", running `prepack`/`prepare`/`postpack` there),
and install the tarball that produces. Three things worth knowing about
that shape:

- **`npm pack` of a clone installs nothing first.** npm's own git-dep
  path installed the package's `dependencies` *and* `devDependencies` in
  its clone before running `prepare`; packing a bare clone does not.
  Fabrica's `prepare` is dependency-free plain node on purpose, so this
  is fine today - and it is also why the step is now faster and needs the
  npm registry only for the final install. If Fabrica's `prepare` ever
  grows a build that needs its `node_modules`, this step has to run an
  install in the clone first.
- **`--pack-destination` must already exist.** npm does not create it;
  it fails with `ENOENT` opening the tarball it was about to write. Here
  it is the `mktemp -d` the step just made, so this only matters if the
  order ever changes.
- **The clone's own `.npmrc` is read, and its `engine-strict=true` does
  not apply to `pack`.** Verified against a clone whose `engines.node`
  was edited to an impossible version: `npm pack` packed it anyway. So
  the step does not depend on the activation's `pkgs.nodejs` matching the
  exact Node version Fabrica pins for its own development.

The commit is also checked rather than assumed: after the install, the
step re-reads the commit out of the copy it just installed and warns when
it finds none. That turns the silent version of this bug into a line in
the activation log.

**A leftover `npm link` is a second thing to clean up, and the order
matters.** `npm link` writes two things into a prefix: the bin shim at
`<prefix>/bin/<name>` and a *relative* symlink at
`<prefix>/lib/node_modules/<name>` pointing at the checkout.
`modules/managed-bin-guard.sh` only ever looked at bin directories, so on
a machine where someone had linked a Fabrica checkout into `~/.local`
(the user-writable prefix this repo reaches for whenever npm's own
default is not writable), the shim was quarantined on every switch and
the package symlink stayed. That symlink alone is enough to fail
`fabrica doctor` (Fabrica issue #171), and an `npm install -g` into that
prefix fails with `ENOTDIR` while it stands. It is now removed - the one
thing this file deletes rather than moves aside, because a symlink holds
no content, one `npm link` puts it back, and the checkout on the far end
is never touched.

- **Remove the package link *after* the bin scan, never before.** A shim
  that resolves through the link becomes a dangling symlink the moment
  the link goes, and a dangling symlink fails the scan's own
  `[ -f ] && [ -x ]` test - so it would survive, unmoved and unrunnable,
  in front of the managed copy.
- **Only a symlink, and only one pointing at a git checkout of that
  tool.** A real directory there is an install, not a link. A link whose
  target is gone cannot be shown to be a leftover of this tool at all, so
  it is warned about instead of guessed at.
- **The package.json name is read with the shell's own pattern
  matching.** Not grep, not jq, not node: the only commands this file may
  rely on are the ones its callers put on the activation PATH from the
  Nix store, and that is coreutils - which has no grep - plus a language
  runtime that is `node` for Fabrica and `go` for Inspector.

**Where this is proved.** `modules/managed-bin-guard.test.sh` covers the
link cases hermetically (removed, real directory refused, non-checkout
refused, nothing touched while the managed copy is missing, silence when
the path does not exist). The commit in `build-info.json` is only
observable in a real activation, so the assertions for it live at the
tail of `install.container-test.sh`, alongside a seeded leftover link -
which also makes that rehearsal the only place the link cleanup runs for
real. Note the same gap `notes/20261021-managed-bin-path-guard.md`
records: `check.sh` and `.github/**` are protected paths, so
`modules/managed-bin-guard.test.sh` still has to be run by hand
(`bash modules/managed-bin-guard.test.sh`) and is in neither
`check.sh` nor `ci-floor.yml`.
