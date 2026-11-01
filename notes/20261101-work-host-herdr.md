# herdr on the work host: one Homebrew formula, two Macs

The work host installs herdr from `work/Brewfile` (`brew "herdr"`), the same
homebrew-core formula `configuration.nix`'s `homebrew.brews` names for
personal-mac. No tap is involved on either host, and neither declares a
cask - the only `herdr` in homebrew-cask territory is Laravel's unrelated
`herd`.

- **Homebrew, not herdr's own installer.** `work/codespace-bootstrap.sh`
  does `curl -fsSL https://herdr.dev/install.sh | sh`, which is right for a
  container with no Homebrew, and wrong for the work Mac: `work/Brewfile` is
  the single captain-triaged manifest and `brew upgrade` is what keeps it
  current. herdr's own docs make that an either/or - `herdr update` is only
  for installs its installer manages, and Homebrew/mise/Nix installs must be
  updated through their package manager - so two install paths on one
  machine would disagree about who owns the upgrade.
- **The config link was already there, the package was not.** The symlink
  `~/.config/herdr` -> `home/.config/herdr` has been in
  `work/bootstrap.sh`'s `install_symlinks` since herdr was added to the
  codespace-work posture, because that function is shared (sourced, not
  copied) with `work/codespace-bootstrap.sh`. So the work Mac was already
  getting herdr's configuration without herdr itself - it was the only
  entry in `install_symlinks` whose package was missing from
  `work/Brewfile`; nvim, starship and ghostty all had theirs.
- **A pre-existing `~/.config/herdr` is a directory, not a file.** A machine
  that already got herdr from herdr's own installer has a real config
  directory there, and `link_with_backup` moves it to
  `~/.config/herdr.pre-dotfiles-backup` exactly once. That is the one
  backup path in this bootstrap that acts on a directory rather than a
  file, and `work/bootstrap.test.sh` now covers it.
- **Still declaration-only, now more so.** With herdr actually installed on
  the work Mac, a `herdr server reload-agent-manifests` or `herdr tab
  rename` from a bootstrap would have a real daemon to hit. The bootstrap
  installs and links, and never runs the binary;
  `test_bootstrap_never_runs_herdr` asserts that about the source (the
  suite's hermetic PATH could not reach a real herdr anyway, which is why
  the invariant has to be checked statically). It strips comments first and
  only matches a subcommand, so prose about herdr commands is free and a
  future `command -v herdr` probe is not a violation.

## Codespaces was and stays untouched

The work posture already installed herdr as a release binary
(`install_herdr` in `work/codespace-bootstrap.sh`), so the Brewfile header's
"adding a line here means codespace-bootstrap.sh needs the matching install
too" rule was satisfied before this change - herdr is the one entry that
arrived codespace-first and Mac-second. `README.md`'s Codespaces section
still lists only neovim, StyLua, ruff and starship as the release-binary
installs; herdr belongs in that parenthetical too, and was left out of this
change only to keep the Codespaces prose out of a work-host diff.

The personal codespace posture has no herdr at all (it imports neither
`modules/desktop.nix` nor `modules/mac.nix`), and
`install.container-test.sh` asserts both halves of that - absent for
`codespace-personal`, on PATH for `codespace-work`. Nothing here changes
either assertion.
