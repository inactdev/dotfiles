# `./run.sh`'s home-linux switch now carries `-b hm-backup`

## The leftover

`personal-mac` has had `home-manager.backupFileExtension = "hm-backup"` in
`flake.nix` since it was written, and `install.sh` passes `-b hm-backup` to
its codespace switch. `./run.sh`'s `home-linux` branch - the only other
place in this repo that runs a switch - passed nothing. That asymmetry was
written down as a known gap in
`notes/20261021-activation-step-env-path.md` when `programs.bash.enable`
landed, and in a `modules/core.nix` comment, but never fixed.

It matters most on exactly the machine `home-linux` describes: a stock
Ubuntu box. `useradd -m` seeds `~/.bashrc`, `~/.profile` and
`~/.bash_logout` from `/etc/skel`, and `modules/core.nix`'s
`programs.bash.enable = true` makes home-manager the owner of the first
two. Home-manager's `checkLinkTargets` refuses to touch an existing
regular file at a path the profile manages and aborts the *whole*
activation before changing anything - so the first `./run.sh rebuild` on
such a box failed outright, with no `~/go/bin`/`~/.npm-global/bin` on a
bash login shell and no way forward except moving files aside by hand.

## What `-b` is, and where it goes on the command line

`-b EXT` is the standalone-CLI equivalent of the
`home-manager.backupFileExtension` option, which only exists in the
NixOS/nix-darwin modules - a standalone `homeConfigurations.*` output has
no such option, so the CLI flag is the only way to get the behaviour that
`personal-mac` gets declaratively. It applies to regular files only;
home-manager never backs up a *symlink* in the way (every backup branch in
`checkLinkTargets` requires `! -L`), which is the separate problem
`install.sh`'s `backup_legacy_dotfile_symlinks` handles for codespaces.

`-b` is a top-level option, not one `switch` accepts: home-manager's own
manual spells the synopsis `home-manager <command> [-b ext] ...` and gives
`home-manager -b bck switch` as the example. A `-b` placed after
`switch --flake ...` is silently ignored rather than rejected, so the flag
**must precede `switch`** - the same ordering `install.sh` and
`install.container-test.sh` already use, and the reason `run.test.sh`
asserts on position rather than mere presence.

## Alternatives rejected

- **Have `run.sh` move colliding files aside itself**, the way
  `install.sh`'s `backup_legacy_dotfile_symlinks` does. Rejected: that
  function exists only because home-manager *cannot* back up symlinks. For
  regular files home-manager has a supported mechanism, and hand-rolling
  one means maintaining a hardcoded list of managed paths in `run.sh` that
  silently drifts from `modules/*.nix` every time a module adds a file -
  and more unsolicited writing to a real `$HOME` than the fix needs.
- **Set `backupFileExtension` in the flake's `home-linux` output.**
  Rejected because it does not exist: the option is defined by
  home-manager's NixOS and nix-darwin modules, not by
  `home-manager.lib.homeManagerConfiguration`, so `personal-mac`'s
  declarative spelling has no standalone counterpart.

## Same shape elsewhere

- `home/.local/bin/dotfiles-auto-apply` applies updates on `home-linux` by
  calling `./run.sh rebuild`, so it inherits this fix with no change of
  its own - and it is the caller that most needed it, being unattended.
- `install.sh` (codespaces) and `install.container-test.sh`'s `ci-linux`
  rehearsal already passed the flag, correctly positioned. They were the
  reference, not a second instance of the bug.
- `flake.nix`'s `home-linux` comment carried the apply command without the
  flag; updated, since it is the line someone copies when applying by
  hand.

## Where it is checked

The `ci-linux` rehearsal at the tail of `install.container-test.sh` has
been running this exact scenario all along without saying so: its
throwaway container user is created with `useradd -m`, so `/etc/skel`'s
`~/.bashrc` and `~/.profile` are sitting in the way of managed files on
every run, and the switch only succeeds because of its own `-b hm-backup`.
That was incidental - and incidental to a base image the test does not
control - so the rehearsal now seeds its own `~/.zshrc` (a path skel never
ships and `modules/core.nix` definitely manages) and asserts both that it
came out as `~/.zshrc.hm-backup` with its bytes intact and that the
managed file took its place. Dropping the flag now fails a named check
rather than aborting the activation twenty lines up the log.

`run.test.sh` covers `run.sh` itself hermetically - both the `rebuild` and
the `bootstrap` home-linux branches, asserting the flag appears *before*
`switch`, and asserting the Mac branch is untouched.
