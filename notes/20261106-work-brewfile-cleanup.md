# The work Mac's Homebrew is the Brewfile, in both directions

`work/bootstrap.sh`'s `install_packages` now runs three commands where it
used to run one:

```
brew bundle dump --force --file=${XDG_STATE_HOME:-~/.local/state}/dotfiles/brew-before-cleanup-<YYYYMMDD-HHMMSS>.Brewfile
brew bundle cleanup --force --file=<repo>/work/Brewfile
brew bundle --file=<repo>/work/Brewfile
```

in that order, so the work Mac keeps exactly `work/Brewfile`'s formulae and
casks, and every removal is recoverable. Before this, only the last line
ran: `brew bundle` installs what is listed and removes nothing, so anything
hand-installed or dropped from the manifest stayed forever. personal-mac has
had the removing half since it was written - `configuration.nix`'s
`homebrew.onActivation.cleanup = "zap"` - and this is the work host catching
up to it, with a safety net the Nix host gets from generations instead.

## The commands, from Homebrew's own documentation

- `dump` is documented as writing "all installed casks/formulae/images/taps
  into a `Brewfile`", explicitly as an installed-state snapshot; `--file`
  is "Read from or write to the `Brewfile` from this location"; `--force`
  under `dump` is "Overwrite an existing `Brewfile`". The default
  categories - casks, formulae, taps - are exactly the ones `cleanup` can
  remove given a Brewfile that declares nothing but `brew` and `cask`
  lines, which is what `work/Brewfile` is, so no opt-in flag (`--mas`,
  `--vscode`, ...) is needed for the snapshot to be complete.
- `cleanup` is documented as "Uninstall all dependencies not present in the
  `Brewfile`", and without `--force` it prompts - "a declined or
  unavailable prompt yields exit code 1", which is what an unforced cleanup
  would do in a bootstrap that has no one to ask.

## Why this shape and not the shorter ones

- **Snapshot first, and no removal without one.** The dump runs before
  cleanup, and if it fails, cleanup is *skipped* entirely: a warning, then
  straight on to the install. Removing packages is the only thing this
  script does that someone might need to undo, and the one-line `brew
  bundle --file=<snapshot>` that undoes it only exists if the snapshot
  does. The snapshot's path and that restore command are printed in the
  closing summary whenever cleanup removed anything, because a summary line
  is what is still on screen when someone notices a missing tool.
- **Outside the repository, under the XDG state dir.** The snapshot is
  machine state, not a tracked manifest: in the repo it would dirty
  `git status` on every rebuild, invite being committed (it lists
  everything installed on a company machine), and leave a stray Brewfile
  lying around for someone to point `brew bundle` at by accident.
  `${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/` is where this repo
  already keeps recoverable machine state (`run.sh` and
  `home/.local/bin/dotfiles-auto-apply` both use that same base).
- **One dated file per run, never one overwritten file.** A fixed filename
  would mean the second run destroys the record of what the first one
  removed - which is precisely when it is wanted, since a missing tool is
  usually noticed a run or two later. The files are a few KB of text each
  and nothing prunes them, deliberately.
- **"Did cleanup remove anything?" is answered by cleanup producing any
  output at all**, not by grepping for "Uninstalling": the wording differs
  between formulae, casks and the `autoremove` step and is not part of any
  documented interface. So the failure mode is over-reporting the restore
  path when nothing was removed, never leaving someone without it.
- **`cleanup` as its own command, before the install - not `brew bundle
  --cleanup`.** The combined flag is documented as equivalent to running
  `cleanup --force`, but it does the removal *after* installing, in the
  same invocation, with one exit status. Three things follow that we don't
  want: a cleanup that fails takes the install's exit status with it, so a
  cleanup problem could leave the Mac without its listed packages (the one
  outcome this change must never produce); there is no separate failure to
  warn about by name; and if cleanup over-removes, nothing runs afterwards
  to put it back. Upstream has an open report that cleanup's `brew
  autoremove` step can take out packages the Brewfile *does* list
  (<https://github.com/Homebrew/brew/issues/21350>) - with cleanup first,
  the install immediately behind it reinstalls anything over-removed, so
  that bug costs a reinstall instead of a missing package.
- **Plain `cleanup`, never `--zap`.** For casks, `--zap` runs `brew
  uninstall --zap`, which also deletes that app's settings and data. On a
  company machine that is someone's real work, and an uninstall-only
  removal is recoverable by reinstalling from the snapshot. Note this is a
  deliberate divergence from personal-mac, whose `onActivation.cleanup`
  *is* `"zap"` - don't "align" the two.

## Scope

Work Mac only. `install_packages` is not one of the functions
`work/codespace-bootstrap.sh` sources out of this file, so the codespace-work
posture is untouched - it installs via apt/npm/release binaries and removes
nothing, which is correct for a container that is thrown away rather than
kept in shape. `BREW_CLEANUP_PENDING` and `BREW_SNAPSHOT` are therefore two
more globals that script's own shadowing `print_summary` ignores, like the
Fabrica/Inspector ones.

Docker Desktop stays out of `work/Brewfile` and is *why* `--force` is safe to
run unattended here: cleanup only considers what the Brewfile could have
installed, and the Self-Service-managed `Docker.app` was never a Homebrew
cask on this host, so there is nothing for cleanup to match it against.

## Same shape elsewhere

Two kinds of neighbour, listed so the ones left standing are known rather
than missed.

Back up before destroying, which this now joins:

- `link_with_backup` in `work/bootstrap.sh` - moves a pre-existing real file
  to `.pre-dotfiles-backup` before replacing it with a symlink.
- `install_fabrica` in the same file - moves the previous `fabrica` launcher
  aside and moves it back if the reinstall fails.
- `install.sh`'s `backup_legacy_dotfile_symlinks` and home-manager's
  `backupFileExtension = "hm-backup"`.
- personal-mac's Homebrew cleanup has no snapshot and needs none: a Nix
  generation is the rollback, and `homebrew.onActivation.cleanup` is driven
  from a manifest in the same commit.

Manifest-driven steps that still only ever add:

- `work/codespace-bootstrap.sh`'s installs - deliberately left alone (above).
- `install_symlinks`/`install_ghostty_symlink` in `work/bootstrap.sh`: a path
  dropped from those functions leaves its stale symlink in `$HOME`, where
  home-manager would have retracted it on the Nix hosts. Not fixed here; it
  has never bitten, and removing files from `$HOME` by name needs more
  thought than one more line in a bootstrap.
- The Nix hosts' own `home.packages`/`homebrew.*` lists are declarative and
  retract on switch, so they have no gap of this kind.
