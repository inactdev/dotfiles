# The work host installs Fabrica and Inspector (issue #39)

`work/bootstrap.sh` now installs Fabrica and Inspector on every run, which
means on every `./run.sh bootstrap work --no-nix` and every `./run.sh
rebuild` once `work` is the chosen host (`cmd_rebuild` for a `--no-nix`
host just calls `cmd_bootstrap_no_nix`, so there is one code path to keep
current, not two). The durable facts:

- **Both tools go under `$HOME/.local`**, not into npm's own global prefix
  and not into Go's default `~/go/bin`. `work/zshrc` exports exactly one
  extra PATH entry, `$HOME/.local/bin`, and it is shared verbatim with the
  codespace-work posture - so using `~/go/bin` the way `personal-mac` does
  (`modules/managed-paths.nix`) would have meant editing a file the
  codespace path also reads, which issue #39 says to leave alone.
  `MANAGED_PREFIX` at the top of `work/bootstrap.sh` is the single
  definition; `install_fabrica` passes it as `npm install -g --prefix` and
  `install_inspector` passes `$MANAGED_PREFIX/bin` as `GOBIN`.
- **No `git ls-remote` comparison, deliberately.**
  `modules/fabrica-sync.sh` and `modules/inspector-sync.sh` compare the
  installed commit against the remote tip before doing anything because a
  home-manager activation runs on its own schedule (and
  `home/.local/bin/dotfiles-auto-apply` triggers it unattended), so a
  clone per switch would be unacceptable. A work-host bootstrap/rebuild is
  a command a human ran, so these install unconditionally. If that ever
  becomes too slow, the comparison logic to port already exists in those
  two scripts - don't reinvent it.
- **The install steps must stay after `configure_git` in `main()`.** That
  is what runs `gh auth setup-git`. Fabrica's repository is private, so
  its clone needs those credentials outright; Inspector's is public today,
  but `GOPRIVATE` means its fetch would need them the day that changes.
  Run earlier and the first bootstrap of a freshly logged-in machine fails
  for no reason but ordering.
- **`FABRICA_PENDING`/`INSPECTOR_PENDING` are read only by
  `work/bootstrap.sh`'s own `print_summary`,** not by the shared
  `print_git_gh_pending`. `work/codespace-bootstrap.sh` sources this file
  and defines its own `print_summary`, so putting work-Mac-only state in
  the shared helper would leak it into the codespace summary for a tool
  that path never installs.
- **`go install ...@latest` is the right query for "current" here.** Per
  the Go module reference, `latest` takes the highest release version,
  then the highest pre-release, and only if neither exists the
  pseudo-version of the default branch's tip. `inspector` has no tags
  today (`modules/inspector-sync.sh` says so too), so `@latest` is the tip;
  once it has a release tag, `@latest` is that tag. Both are the right
  answer to "keep it current", so nothing here needs to know which case it
  is in.
- **`GOPRIVATE='github.com/inactdev/*'` matters for a private Inspector.**
  It is what makes go resolve and fetch straight from the repository
  instead of through `proxy.golang.org` and the public checksum database,
  which is what `go help private` prescribes for a module that may not be
  publicly available. Scoped to one owner, so every dependency is still
  proxied and still checksum-verified. `CGO_ENABLED=0` is there so the
  step needs no Xcode command line tools on a locked-down Mac;
  `GIT_TERMINAL_PROMPT=0` (and the same on Fabrica's clone) so a machine
  without credentials fails in seconds instead of stopping on a prompt.

## The username guard needed a carve-out

`work/bootstrap.test.sh`'s `test_no_username_hardcoded_in_source` greps
`work/` and `run.sh` for a bare `inactdev` and fails on any hit. Fabrica
and Inspector live at `github.com/inactdev/{fabrica,inspector}`, which is
the repositories' own identity and cannot be parameterized away the way a
home directory can - so the grep now filters out hits where the owner
directly follows a `github.com` host or a `github:` spec prefix, and
nothing else. A bare `inactdev` used as a username or a home-directory
component still fails.

Two sibling tests have the same shape and the same latent limitation, left
unchanged because nothing they scan carries a GitHub owner reference
today: `install.test.sh`'s `test_no_username_hardcoded_in_source` (scans
`install.sh`, `codespaces/`, `modules/core.nix`, `modules/codespace.nix`,
`work/codespace-bootstrap.sh`, `work/zshrc`) and `run.test.sh`'s
`test_no_username_hardcoded_in_run_sh` (scans `run.sh`). Whichever of
those first needs a repository URL will need the same filter.

## Testing it without a network

`work/bootstrap.test.sh` mocks `npm` and `go`, and now also intercepts
`git clone` specifically - `mock_git` fakes a clone (creating the
destination with a minimal `package.json`) and `exec`s the real git, via
`$REAL_GIT`, for everything else, which the suite still needs for its
git-identity assertions. The npm mock's `pack --pack-destination` leaves
exactly one `.tgz` behind, so the clone -> pack -> glob -> install chain is
exercised end to end with nothing real running. `TMPDIR` is pointed inside
the scratch directory so a leaked clone/tarball directory is assertable.
