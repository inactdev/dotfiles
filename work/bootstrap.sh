#!/usr/bin/env bash
# The --no-nix bootstrap path: plain Homebrew + shell, no Nix, no
# home-manager. Invoked by ./run.sh bootstrap work --no-nix (see run.sh).
#
# Every function here is idempotent and safe to re-run. Nothing in this
# file may assume a specific username or home directory layout beyond
# $HOME, and nothing here may touch flake.nix/modules/*.nix/configuration.nix
# or the personal-mac (Nix) path.
#
# Also sourced (not just executed) by work/codespace-bootstrap.sh, the
# codespace-work no-nix path - see the BASH_SOURCE guard at the tail of
# this file, which exists for exactly that (and is what already lets
# work/bootstrap.test.sh source it directly). Every function below except
# brew_bin/install_homebrew/install_packages/install_ghostty_symlink/
# macos_write_default/configure_macos_defaults is plain shell with
# nothing macOS-specific about it and is reused as-is by the codespace
# path rather than copied - see AGENTS.md.
#
# install_fabrica/install_inspector are the exception to that rule: they
# are plain shell too, and the codespace path still does not call them.
# A container is a place work gets done, not a place it gets dispatched
# from or checked, which is the same reason flake.nix leaves
# modules/fabrica.nix and modules/inspector.nix out of both codespace
# hosts. Adding them later is two lines in that script's own main().
set -euo pipefail

# Collected here so the final summary can tell the captain what still
# needs a human, instead of silently doing nothing.
#
# FABRICA_PENDING/INSPECTOR_PENDING are read only by this file's own
# print_summary. work/codespace-bootstrap.sh defines its own print_summary
# that shadows this one and never installs either tool, so sourcing this
# file leaves it with two counters it ignores - deliberately, rather than
# threading them through the shared print_git_gh_pending, which would put
# work-Mac-only state into the codespace summary.
GIT_IDENTITY_PENDING=0
MACOS_DEFAULTS_PENDING=0
GH_LOGIN_PENDING=0
FABRICA_PENDING=0
INSPECTOR_PENDING=0

# The two repositories this host installs from, and where their binaries
# land. $HOME/.local rather than npm's own global prefix (Homebrew's, on
# this host) or Go's own default GOBIN (~/go/bin, which is what the Nix
# hosts use): $HOME/.local/bin is the single directory work/zshrc already
# exports on PATH, it needs no sudo and no writable Homebrew prefix, and
# it is already where everything else the no-nix path installs by npm or
# by download goes. Using ~/go/bin instead would mean adding a PATH entry
# to work/zshrc, which the codespace-work posture shares verbatim.
FABRICA_REPO_URL=https://github.com/inactdev/fabrica.git
FABRICA_BRANCH=master
INSPECTOR_PKG_PATH=github.com/inactdev/inspector/cmd/inspector
MANAGED_PREFIX="$HOME/.local"

brew_bin() {
  if command -v brew >/dev/null 2>&1; then
    command -v brew
  elif [ -x /opt/homebrew/bin/brew ]; then
    echo /opt/homebrew/bin/brew
  elif [ -x /usr/local/bin/brew ]; then
    echo /usr/local/bin/brew
  fi
}

install_homebrew() {
  if [ -n "$(brew_bin)" ]; then
    echo "==> Homebrew already installed"
    return
  fi
  if [ ! -t 0 ]; then
    echo "Homebrew is not installed and this shell is not interactive, so the"
    echo "official installer can't prompt for your password if it needs one."
    echo "Install Homebrew yourself first: https://brew.sh"
    echo "Then re-run: ./run.sh bootstrap work --no-nix"
    exit 1
  fi
  echo "==> installing Homebrew (you may be prompted for your password)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

install_packages() {
  local repo="$1" brew
  brew="$(brew_bin)"
  echo "==> installing packages (brew bundle)"
  "$brew" bundle --file="$repo/work/Brewfile"
}

# Replaces $target with a symlink to $source, backing up a pre-existing
# real file or directory (not one of our own symlinks) exactly once.
link_with_backup() {
  local source="$1" target="$2"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    mv "$target" "$target.pre-dotfiles-backup"
    echo "    backed up existing $target -> $target.pre-dotfiles-backup"
  fi
  ln -sfn "$source" "$target"
}

# The configs every --no-nix host wants, regardless of OS - shared with
# work/codespace-bootstrap.sh. Ghostty is deliberately separate (see
# install_ghostty_symlink below): there's no GUI terminal to configure in
# a codespace container, so the codespace path never calls it.
install_symlinks() {
  local repo="$1"
  echo "==> linking configs"
  mkdir -p "$HOME/.config" "$HOME/.claude"
  link_with_backup "$repo/home/.config/nvim" "$HOME/.config/nvim"
  link_with_backup "$repo/home/.config/starship.toml" "$HOME/.config/starship.toml"
  link_with_backup "$repo/home/.config/herdr" "$HOME/.config/herdr"
  link_with_backup "$repo/home/AGENTS.md" "$HOME/AGENTS.md"
  link_with_backup "$repo/home/AGENTS.md" "$HOME/.claude/CLAUDE.md"
}

# Mac-only: ghostty is a GUI terminal app, meaningless in a codespace
# container - work/codespace-bootstrap.sh's main() never calls this.
install_ghostty_symlink() {
  local repo="$1"
  link_with_backup "$repo/home/.config/ghostty" "$HOME/.config/ghostty"
}

install_zshrc() {
  local repo="$1"
  echo "==> linking work zshrc"
  link_with_backup "$repo/work/zshrc" "$HOME/.zshrc"
}

install_claude_settings() {
  local repo="$1"
  echo "==> linking work Claude settings"
  mkdir -p "$HOME/.claude"
  link_with_backup "$repo/work/claude-settings.json" "$HOME/.claude/settings.json"
}

configure_git_identity() {
  local name email
  name="$(git config --global user.name 2>/dev/null || true)"
  email="$(git config --global user.email 2>/dev/null || true)"
  if [ -n "$name" ] && [ -n "$email" ]; then
    echo "==> git identity already set: $name <$email>"
    return
  fi
  if [ -t 0 ]; then
    echo "==> no git identity configured on this machine"
    if [ -z "$name" ]; then
      read -r -p "    git user.name: " name || true
      [ -n "$name" ] && git config --global user.name "$name"
    fi
    if [ -z "$email" ]; then
      read -r -p "    git user.email: " email || true
      [ -n "$email" ] && git config --global user.email "$email"
    fi
  fi
  name="$(git config --global user.name 2>/dev/null || true)"
  email="$(git config --global user.email 2>/dev/null || true)"
  if [ -z "$name" ] || [ -z "$email" ]; then
    GIT_IDENTITY_PENDING=1
    echo "    WARNING: git identity not set. Commits will fail until you run:"
    echo "      git config --global user.name \"Your Name\""
    echo "      git config --global user.email you@example.com"
  fi
}

configure_git() {
  echo "==> configuring git"
  git config --global push.autoSetupRemote true
  git config --global core.editor nvim
  configure_git_identity
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh auth setup-git
  else
    GH_LOGIN_PENDING=1
  fi
}

# Fabrica, the task orchestrator, installed the three-step way its own
# README prescribes: a shallow clone of master, `npm pack` inside that
# clone, then `npm install -g` of the tarball that produced. The same path
# modules/fabrica-sync.sh takes for the Nix hosts, and for the same
# reasons - neither shorter form works:
#
#   - `npm install -g github:inactdev/fabrica` installs a git spec
#     globally by symlinking the prefix at npm's own temporary clone and
#     then deleting that clone, so Fabrica's build step is left running in
#     a directory that no longer exists.
#   - `npm pack github:inactdev/fabrica` fails more quietly: for a
#     `github:` spec npm fetches GitHub's tarball of the tree rather than
#     cloning, so there is no `.git` for Fabrica's build step to read its
#     commit out of. The install succeeds, build-info.json lands saying
#     `{"commit":null}`, and the only symptom is `fabrica doctor` refusing
#     to start work afterwards.
#
# What this does NOT copy from modules/fabrica-sync.sh is its `git
# ls-remote` comparison against the installed copy's commit. That exists
# because a home-manager activation runs on its own schedule and must not
# cost a clone every time; a work-host bootstrap or rebuild is a command
# someone ran on purpose, so this simply installs the tip of master every
# time. Re-running is therefore safe and leaves the same state, which is
# what "idempotent" has to mean for a step whose whole job is "be
# current".
#
# No failure here is fatal. The repository is private, so a machine whose
# `gh auth login` is still pending cannot clone it at all - that has to
# warn and land in the summary, not abort a bootstrap that has already
# linked every config and installed every package. GIT_TERMINAL_PROMPT=0
# so such a machine fails immediately instead of stopping on a credential
# prompt (GitHub accepts no password there anyway), and the low-speed
# settings so a half-open connection gives up in seconds.
install_fabrica() {
  local tmpdir clone_dir candidate
  local tarball=
  local count=0

  echo "==> installing Fabrica (clone $FABRICA_BRANCH, npm pack, npm install -g)"
  if ! command -v npm >/dev/null 2>&1; then
    FABRICA_PENDING=1
    echo "    WARN: npm is not on PATH, so Fabrica was not installed" >&2
    return 0
  fi

  if ! tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/fabrica-install.XXXXXX")"; then
    FABRICA_PENDING=1
    echo "    WARN: could not make a temporary directory, so Fabrica was not installed" >&2
    return 0
  fi
  clone_dir="$tmpdir/fabrica"

  # The clone and the tarball are removed whichever way this goes: between
  # them they are two full copies of Fabrica's source, and there is no
  # reason for either to outlive the install it was made for.
  if ! GIT_TERMINAL_PROMPT=0 git \
    -c http.lowSpeedLimit=1000 \
    -c http.lowSpeedTime=15 \
    clone --quiet --depth 1 --branch "$FABRICA_BRANCH" "$FABRICA_REPO_URL" "$clone_dir"; then
    rm -rf "$tmpdir"
    FABRICA_PENDING=1
    echo "    WARN: could not clone $FABRICA_BRANCH from $FABRICA_REPO_URL," >&2
    echo "          so Fabrica was not installed. It is a private repository -" >&2
    echo "          run gh auth login, then re-run this bootstrap." >&2
    return 0
  fi

  # `npm pack` with no spec packs the package in the current directory,
  # running its prepack/prepare/postpack there - `.git` is present, so
  # Fabrica's build step records the real commit - and writes the tarball
  # where --pack-destination says.
  if ! (cd "$clone_dir" && npm pack --pack-destination "$tmpdir" >/dev/null); then
    rm -rf "$tmpdir"
    FABRICA_PENDING=1
    echo "    WARN: npm pack of the clone failed, so Fabrica was not installed" >&2
    return 0
  fi

  # Found by globbing rather than by name: npm names the tarball from the
  # packed package.json (<name>-<version>.tgz), which this script has no
  # other reason to know. The directory is this run's own and was just
  # created, so exactly one .tgz in it is the one that was just packed -
  # any other count means something happened that was not planned for, and
  # nothing is installed. The clone is a directory, so it never counts.
  for candidate in "$tmpdir"/*.tgz; do
    if [ -f "$candidate" ]; then
      tarball="$candidate"
      count=$((count + 1))
    fi
  done
  if [ "$count" -ne 1 ]; then
    rm -rf "$tmpdir"
    FABRICA_PENDING=1
    echo "    WARN: npm pack left $count tarballs rather than one, so Fabrica was not installed" >&2
    return 0
  fi

  # --prefix: see MANAGED_PREFIX above for why Fabrica goes under
  # ~/.local rather than into npm's own global prefix.
  if ! npm install -g --prefix "$MANAGED_PREFIX" "$tarball"; then
    rm -rf "$tmpdir"
    FABRICA_PENDING=1
    echo "    WARN: npm install -g of the packed tarball failed, so Fabrica was not installed" >&2
    return 0
  fi

  rm -rf "$tmpdir"
  return 0
}

# Inspector, the checker that runs a repository's check.sh against a
# worker's branch, from the one command its own documentation gives.
# `@latest` rather than a commit read with `git ls-remote` first: unlike
# Fabrica's npm install this needs no clone of its own, so there is
# nothing to save by deciding in advance whether to run it, and go's own
# build cache makes a re-install of an unchanged Inspector cheap. On a
# repository with no tags - which inspector has none of today - `@latest`
# is the tip of the default branch; once it has a release tag, `@latest`
# is that tag, which is the right answer to "current" either way.
#
# The environment is the same one modules/inspector-sync.sh established
# for this exact command, for the same reasons:
#
#   - GOBIN pins where the binary lands, so it matches the PATH entry
#     work/zshrc already has, whatever this machine's `go env` says.
#   - GOPRIVATE keeps the fetch off the public proxy and checksum database
#     and on the repository itself, which is what `go help private`
#     prescribes for a module that may not be publicly available - so this
#     keeps working if inspector is ever made private, and costs nothing
#     while it is public. Scoped to one owner's modules, so every
#     dependency still goes through the proxy and is still
#     checksum-verified.
#   - CGO_ENABLED=0 because Inspector is pure Go and this step must not
#     need a C toolchain: a locked-down Mac without the Xcode command line
#     tools would otherwise stop with `cgo: C compiler not found`.
#   - GIT_TERMINAL_PROMPT=0 because go fetches with git, and a credential
#     prompt must never be able to hang a bootstrap.
#
# Like install_fabrica, every failure warns and returns 0: Inspector being
# a version behind is not worth losing the rest of the bootstrap over.
install_inspector() {
  local gobin="$MANAGED_PREFIX/bin"

  echo "==> installing Inspector (go install $INSPECTOR_PKG_PATH@latest)"
  if ! command -v go >/dev/null 2>&1; then
    INSPECTOR_PENDING=1
    echo "    WARN: go is not on PATH, so Inspector was not installed" >&2
    return 0
  fi

  if ! mkdir -p "$gobin"; then
    INSPECTOR_PENDING=1
    echo "    WARN: could not create $gobin, so Inspector was not installed" >&2
    return 0
  fi

  if ! GOBIN="$gobin" \
    GOPRIVATE='github.com/inactdev/*' \
    GIT_TERMINAL_PROMPT=0 \
    CGO_ENABLED=0 \
    go install "$INSPECTOR_PKG_PATH@latest"; then
    INSPECTOR_PENDING=1
    echo "    WARN: go install $INSPECTOR_PKG_PATH@latest failed, so Inspector" >&2
    echo "          was not installed. If it is a credentials problem, run" >&2
    echo "          gh auth login, then re-run this bootstrap." >&2
    return 0
  fi

  return 0
}

macos_write_default() {
  if ! defaults write "$@" >/dev/null 2>&1; then
    echo "    WARN: could not set '$*' (likely locked by MDM)"
    MACOS_DEFAULTS_PENDING=1
  fi
}

configure_macos_defaults() {
  echo "==> applying macOS defaults"
  macos_write_default NSGlobalDomain KeyRepeat -int 2
  macos_write_default NSGlobalDomain InitialKeyRepeat -int 15
  macos_write_default NSGlobalDomain _HIHideMenuBar -bool true
  macos_write_default NSGlobalDomain AppleShowAllExtensions -bool true
  macos_write_default com.apple.dock autohide -bool true
  macos_write_default com.apple.finder FXPreferredViewStyle -string Nlsv
  macos_write_default com.apple.finder CreateDesktop -bool false
  killall Dock >/dev/null 2>&1 || true
  killall Finder >/dev/null 2>&1 || true
}

# Shared with work/codespace-bootstrap.sh's own print_summary, which
# also has git/gh pending state to report but no macOS defaults.
print_git_gh_pending() {
  if [ "$GIT_IDENTITY_PENDING" = 1 ]; then
    echo "  - git identity: run git config --global user.name/user.email"
  fi
  if [ "$GH_LOGIN_PENDING" = 1 ]; then
    echo "  - GitHub login: run gh auth login, then re-run this bootstrap"
  fi
}

print_summary() {
  echo ""
  echo "==> done"
  if [ "$GIT_IDENTITY_PENDING" = 1 ] || [ "$MACOS_DEFAULTS_PENDING" = 1 ] ||
    [ "$GH_LOGIN_PENDING" = 1 ] || [ "$FABRICA_PENDING" = 1 ] ||
    [ "$INSPECTOR_PENDING" = 1 ]; then
    echo "Still needs attention:"
    print_git_gh_pending
    if [ "$FABRICA_PENDING" = 1 ]; then
      echo "  - Fabrica: not installed; see the warning above, then re-run this bootstrap"
    fi
    if [ "$INSPECTOR_PENDING" = 1 ]; then
      echo "  - Inspector: not installed; see the warning above, then re-run this bootstrap"
    fi
    if [ "$MACOS_DEFAULTS_PENDING" = 1 ]; then
      echo "  - some macOS defaults were rejected, likely by MDM policy"
    fi
  else
    echo "Everything applied cleanly."
  fi
}

main() {
  local repo="${1:?usage: bootstrap.sh <repo-dir>}"
  install_homebrew
  install_packages "$repo"
  install_symlinks "$repo"
  install_ghostty_symlink "$repo"
  install_zshrc "$repo"
  install_claude_settings "$repo"
  configure_git
  # After configure_git, not before: that is what runs `gh auth setup-git`,
  # and both of these fetch from GitHub over https - Fabrica's clone
  # directly (from a private repository, so it needs those credentials),
  # Inspector's `go install` through go's own git fetch (public today, but
  # GOPRIVATE means it would need them the day that changes). Run any
  # earlier and the first bootstrap of a freshly logged-in machine would
  # fail for no reason but ordering.
  install_fabrica
  install_inspector
  configure_macos_defaults
  print_summary
}

# Allow work/bootstrap.test.sh to source this file and call individual
# functions without running the whole bootstrap.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
