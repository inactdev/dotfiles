#!/usr/bin/env bash
# The --no-nix bootstrap path: plain Homebrew + shell, no Nix, no
# home-manager. Invoked by ./run.sh bootstrap work --no-nix (see run.sh).
#
# Every function here is idempotent and safe to re-run. Nothing in this
# file may assume a specific username or home directory layout beyond
# $HOME, and nothing here may touch flake.nix/home.nix/configuration.nix
# or the personal-mac (Nix) path.
set -euo pipefail

# Collected here so the final summary can tell the captain what still
# needs a human, instead of silently doing nothing.
GIT_IDENTITY_PENDING=0
MACOS_DEFAULTS_PENDING=0
GH_LOGIN_PENDING=0

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

install_symlinks() {
  local repo="$1"
  echo "==> linking configs"
  mkdir -p "$HOME/.config" "$HOME/.claude"
  ln -sfn "$repo/home/.config/nvim" "$HOME/.config/nvim"
  ln -sfn "$repo/home/.config/starship.toml" "$HOME/.config/starship.toml"
  ln -sfn "$repo/home/.config/ghostty" "$HOME/.config/ghostty"
  ln -sfn "$repo/home/AGENTS.md" "$HOME/AGENTS.md"
  ln -sfn "$repo/home/AGENTS.md" "$HOME/.claude/CLAUDE.md"
}

# Replaces $target with a symlink to $source, backing up a pre-existing
# real file (not one of our own symlinks) exactly once.
link_with_backup() {
  local source="$1" target="$2"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    mv "$target" "$target.pre-dotfiles-backup"
    echo "    backed up existing $target -> $target.pre-dotfiles-backup"
  fi
  ln -sfn "$source" "$target"
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
      read -r -p "    git user.name: " name
      [ -n "$name" ] && git config --global user.name "$name"
    fi
    if [ -z "$email" ]; then
      read -r -p "    git user.email: " email
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

print_summary() {
  echo ""
  echo "==> done"
  if [ "$GIT_IDENTITY_PENDING" = 1 ] || [ "$MACOS_DEFAULTS_PENDING" = 1 ] || [ "$GH_LOGIN_PENDING" = 1 ]; then
    echo "Still needs attention:"
    if [ "$GIT_IDENTITY_PENDING" = 1 ]; then
      echo "  - git identity: run git config --global user.name/user.email"
    fi
    if [ "$GH_LOGIN_PENDING" = 1 ]; then
      echo "  - GitHub login: run gh auth login, then re-run this bootstrap"
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
  install_zshrc "$repo"
  install_claude_settings "$repo"
  configure_git
  configure_macos_defaults
  print_summary
}

# Allow work/bootstrap.test.sh to source this file and call individual
# functions without running the whole bootstrap.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
