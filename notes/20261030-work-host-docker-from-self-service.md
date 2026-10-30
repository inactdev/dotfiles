# Docker on the work Mac comes from Self-Service, not Homebrew

`work/Brewfile` has no `docker-desktop` cask and must not grow one. On the
work Mac Docker Desktop is distributed through the company's Self-Service
app, which installs and updates a managed copy; a `cask "docker-desktop"`
line would either fight that copy on every `brew bundle` or install a
second, unmanaged one alongside it. `work/bootstrap.sh`'s `check_docker`
only *looks* for it instead.

- **A miss is a pending item, never a failure.** `check_docker` sets
  `DOCKER_PENDING=1` and `print_summary` prints one line pointing at
  Self-Service. Nothing else in the bootstrap depends on Docker, and
  installing it is a human step in a GUI app no script here can drive - so
  this must not become an `exit 1`, the same reasoning as the
  Fabrica/Inspector steps.
- **Both halves of the check are load-bearing:** `docker` on PATH *and*
  `/Applications/Docker.app` present. Either alone is a false positive - a
  `docker` with no app bundle is usually a leftover CLI from a former
  install or a colima/podman shim, and an app bundle that has never been
  launched hasn't created its CLI symlinks yet, so the app is there and
  `docker` is not.
- **`DOCKER_APP` is overridable (`${DOCKER_APP:-/Applications/Docker.app}`)
  for exactly one reason: the test suite.** `/Applications` is outside the
  scratch `$HOME` that keeps `work/bootstrap.test.sh` hermetic, cannot be
  written from a test, and would otherwise report whatever the machine
  running the suite happens to have - including a real work Mac's real
  Docker. Nothing in normal use sets it.
- **`check_docker` is Mac-only, like `install_ghostty_symlink`.**
  `work/codespace-bootstrap.sh` sources `work/bootstrap.sh` and so inherits
  the function and the counter, but its `main()` never calls it and its own
  `print_summary` shadows the one that reads `DOCKER_PENDING` - a container
  has neither `/Applications` nor Self-Service. That makes three counters
  the codespace path inherits and ignores (`FABRICA_PENDING`,
  `INSPECTOR_PENDING`, `DOCKER_PENDING`), still deliberately rather than
  threading them through the shared `print_git_gh_pending`.

## One `docker` test case is not hermetically reachable

`work/bootstrap.test.sh` covers Docker present, Docker absent, and a stray
`docker` CLI with no app bundle. The fourth combination - app bundle
present, no CLI - is the same `&&` read the other way and is deliberately
not asserted: the suite's hermetic PATH still ends in `/usr/bin:/bin`, so
on a machine with a system-wide `docker` there (any Linux dev box with
`docker.io` installed; `work/bootstrap.test.sh` runs on `macos-latest` in
CI, which has none) that case would silently become "both present" and
assert the opposite of what it was written for.

## Mentions of the removed cask left standing on purpose

`work/codespace-bootstrap.sh` lists `docker-desktop` among the "macOS-only
Brewfile entries ... simply not installed" in both its header comment and
its summary output, `work/codespace-bootstrap.test.sh` asserts that
summary line, and `README.md`'s Codespaces section restates it. All four
were left as-is: the statement is still true for a container, and changing
it would change user-visible codespace output and the test pinning it, for
a path that never installed Docker in the first place. Whoever next edits
that summary should drop the name then.
