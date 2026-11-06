# The work Mac's Homebrew is the Brewfile, in both directions

`work/bootstrap.sh`'s `install_packages` now runs

```
brew bundle cleanup --force --file=<repo>/work/Brewfile
brew bundle --file=<repo>/work/Brewfile
```

in that order, so the work Mac keeps exactly `work/Brewfile`'s formulae and
casks. Before this, only the second line ran: `brew bundle` installs what is
listed and removes nothing, so anything hand-installed or dropped from the
manifest stayed forever. personal-mac has had the removing half since it was
written - `configuration.nix`'s `homebrew.onActivation.cleanup = "zap"` - and
this is the work host catching up to it.

## Why this shape and not the shorter ones

- **`cleanup` as its own command, before the install - not `brew bundle
  --cleanup`.** The combined flag is documented as equivalent to running
  `cleanup --force`, but it does the removal *after* installing, in the same
  invocation, with one exit status. Three things follow that we don't want:
  a cleanup that fails takes the install's exit status with it, so a cleanup
  problem could leave the Mac without its listed packages (the one outcome
  this change must never produce); there is no separate failure to warn
  about by name; and if cleanup over-removes, nothing runs afterwards to put
  it back. Upstream has an open report that cleanup's `brew autoremove` step
  can take out packages the Brewfile *does* list
  (<https://github.com/Homebrew/brew/issues/21350>) - with cleanup first, the
  install immediately behind it reinstalls anything over-removed, so that bug
  costs a reinstall instead of a missing package.
- **Plain `cleanup`, never `--zap`.** For casks, `--zap` runs `brew uninstall
  --zap`, which also deletes that app's settings and data. On a company
  machine that is someone's real work, and an uninstall-only removal is
  recoverable by reinstalling. Note this is a deliberate divergence from
  personal-mac, whose `onActivation.cleanup` *is* `"zap"` - don't "align" the
  two.
- **No dry-run pass first.** Running `cleanup` without `--force` to print the
  list, then again with it, doubles the work and buys nothing a bootstrap can
  act on: it is non-interactive, so there is nobody to confirm with.
  `--force` prints each uninstall as it happens, and that output is left on
  stdout rather than captured, which is what reports what was removed.
- **A cleanup failure warns and continues**, like every other non-fatal step
  in this script, and lands in the closing summary as a `BREW_CLEANUP_PENDING`
  line. The install always runs.

## Scope

Work Mac only. `install_packages` is not one of the functions
`work/codespace-bootstrap.sh` sources out of this file, so the codespace-work
posture is untouched - it installs via apt/npm/release binaries and removes
nothing, which is correct for a container that is thrown away rather than
kept in shape. `BREW_CLEANUP_PENDING` is therefore one more counter that
script's own shadowing `print_summary` ignores, like the Fabrica/Inspector
ones.

Docker Desktop stays out of `work/Brewfile` and is *why* `--force` is safe to
run unattended here: cleanup only considers what the Brewfile could have
installed, and the Self-Service-managed `Docker.app` was never a Homebrew
cask on this host, so there is nothing for cleanup to match it against.

## Same shape elsewhere

Manifest-driven steps that still only ever add, listed so they are known
rather than missed:

- `work/codespace-bootstrap.sh`'s installs - deliberately left alone (above).
- `install_symlinks`/`install_ghostty_symlink` in `work/bootstrap.sh`: a path
  dropped from those functions leaves its stale symlink in `$HOME`, where
  home-manager would have retracted it on the Nix hosts. Not fixed here; it
  has never bitten, and removing files from `$HOME` by name needs more
  thought than one more line in a bootstrap.
- The Nix hosts' own `home.packages`/`homebrew.*` lists are declarative and
  retract on switch, so they have no gap of this kind.
