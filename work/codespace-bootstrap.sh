#!/usr/bin/env bash
# The codespace-work bootstrap path: plain apt/npm/direct-binary installs,
# no Nix, no Homebrew, no cloned repositories. Invoked by install.sh for
# work-posture Codespaces only - see install.sh's main() and AGENTS.md.
#
# work/Brewfile is this script's intent, not its manifest: every tool
# there is translated to the codespace universal image's own package
# manager (apt) first, a language package manager already on the image
# (npm, since Node ships with the image) second, and a direct download of
# an official release binary only when neither covers a modern-enough
# version (see install_neovim, install_stylua, install_starship,
# install_ruff). Homebrew-on-Linux is deliberately not an option - it is
# exactly the kind of heavy, slow install this script exists to replace.
# macOS-only Brewfile entries (ghostty, docker-desktop, the nerd font
# cask) have no codespace equivalent and are simply not installed.
#
# Package installation (this file) is the only thing that genuinely
# differs from the Mac --no-nix path. Everything else - symlinking
# configs, linking work/zshrc, linking Claude settings, git config, and
# the git/gh pending-report helper - is plain shell with nothing
# macOS-specific about it, so it's sourced straight from work/bootstrap.sh
# rather than copied: link_with_backup, install_symlinks, install_zshrc,
# install_claude_settings, configure_git_identity, configure_git,
# print_git_gh_pending. install_ghostty_symlink is the one Mac-only piece
# left there - this file never calls it (no GUI terminal in a container).
#
# Every function here is idempotent (checks `command -v`/`dpkg -s` before
# acting) and safe to re-run. Nothing here may assume a specific username
# or home directory layout beyond $HOME, and nothing here may touch
# flake.nix/modules/*.nix/configuration.nix or the personal-mac path.
set -euo pipefail

CODESPACE_BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$CODESPACE_BOOTSTRAP_DIR/bootstrap.sh"

# Several tools below install into ~/.local/bin (nvim, stylua, ruff, the
# fd symlink, both npm tools), but this script does not run under the
# user's interactive shell - a Codespaces setup-script run starts from the
# image's default PATH, so work/zshrc's own export is not in effect here.
# Without this, every `command -v` gate would miss a previous run's work
# and re-download all of them on each re-run. It also stops third-party
# installers that offer to edit shell rc files from deciding they need to
# (see install_ruff).
export PATH="$HOME/.local/bin:$PATH"

# INSTALLED/SKIPPED_PRESENT/PENDING have no Mac equivalent - `brew bundle`
# either fully succeeds or the whole Mac bootstrap aborts, so it has no
# per-tool state to track the way this apt/npm/binary path does.
INSTALLED=()
SKIPPED_PRESENT=()
PENDING=()

# Memoizes both the fact of the update and its result: every caller after
# the first gets the same exit status back rather than a bare 0, so an
# `apt-get update` that actually failed keeps propagating instead of
# letting each apt_install proceed against a stale index. APT_UPDATED is
# set before the update runs, so a failure is never retried once per tool.
# install_gh deliberately resets it to force one fresh re-index after
# adding its own source, and scopes that re-index's failure back out
# again - apt refreshes each source independently, so an unreachable
# cli.github.com must not mark every later, unrelated install failed too.
APT_UPDATED=0
APT_UPDATE_STATUS=0
apt_update_once() {
  if [ "$APT_UPDATED" = 0 ]; then
    APT_UPDATED=1
    sudo apt-get update -y
    APT_UPDATE_STATUS=$?
  fi
  return "$APT_UPDATE_STATUS"
}

# Takes one or more package names - needed for node, whose apt package
# doesn't bundle npm the way the universal image's own Node (via nvm)
# does, so that fallback needs two packages installed together.
apt_install() {
  apt_update_once &&
    sudo apt-get install -y --no-install-recommends "$@"
}

# install_binary_tool CLI_NAME LABEL INSTALL_FN
# Skips INSTALL_FN entirely when CLI_NAME is already on PATH - this is
# what makes every tool here safe to re-run, and what lets the universal
# Codespaces image's own preinstalled tools (node, go, git, gh, rbenv, ...
# whichever it happens to ship) short-circuit without ever reaching apt,
# npm, or a binary download.
install_binary_tool() {
  local cli="$1" label="$2" install_fn="$3"
  if command -v "$cli" >/dev/null 2>&1; then
    echo "==> $label already present, skipping"
    SKIPPED_PRESENT+=("$label")
    return
  fi
  echo "==> installing $label"
  if "$install_fn"; then
    INSTALLED+=("$label")
  else
    echo "    WARN: could not install $label" >&2
    PENDING+=("$label")
  fi
}

# --- apt-packaged tools ------------------------------------------------

install_git() { apt_install git; }
install_jq() { apt_install jq; }
# Not a Brewfile entry, but install_gh/install_neovim/install_stylua/
# install_ruff/install_starship all shell out to it - the universal
# Codespaces image always ships it, so this only matters on a bare Ubuntu
# base, where without it those five land in PENDING with no explanation.
install_curl() { apt_install curl ca-certificates; }
install_ripgrep() { apt_install ripgrep; }
install_direnv() { apt_install direnv; }
install_zsh() { apt_install zsh; }

# Ubuntu's fd package is named fd-find and installs the binary as
# `fdfind` (a real `fd` already exists in Debian/Ubuntu, unrelated to
# this one) - symlink it under ~/.local/bin so `fd` resolves like it
# does everywhere else this repo is used.
install_fd() {
  local fdfind_path
  apt_install fd-find || return 1
  fdfind_path="$(command -v fdfind)" || return 1
  mkdir -p "$HOME/.local/bin"
  ln -sf "$fdfind_path" "$HOME/.local/bin/fd"
}

# rbenv itself is current via apt, but the bundled ruby-build plugin only
# knows older Ruby releases - acceptable here since this script only
# needs rbenv present for shell init (work/zshrc), not for
# installing a specific Ruby version. A human wanting a newer Ruby should
# update ruby-build by hand; that's a pre-existing rbenv/apt limitation,
# not something this script can fix without a git clone.
install_rbenv() { apt_install rbenv; }

install_zsh_plugin_packages() {
  local label="zsh-autosuggestions/zsh-syntax-highlighting"
  if dpkg -s zsh-autosuggestions >/dev/null 2>&1 && dpkg -s zsh-syntax-highlighting >/dev/null 2>&1; then
    echo "==> $label already present, skipping"
    SKIPPED_PRESENT+=("$label")
    return
  fi
  echo "==> installing $label"
  if apt_install zsh-autosuggestions && apt_install zsh-syntax-highlighting; then
    INSTALLED+=("$label")
  else
    echo "    WARN: could not install $label" >&2
    PENDING+=("$label")
  fi
}

# --- gh: official apt repo, no clone ------------------------------------

install_gh() {
  local tmp prior_update_status status keyring_status
  tmp="$(mktemp -d)"
  # Downloaded to a temp file and only then installed to its real path,
  # same shape as install_neovim/install_stylua: piping curl straight into
  # `sudo dd of=<keyring>` truncates the existing keyring the moment the
  # pipeline starts, so a failed download on a re-run zeroes a keyring the
  # already-published apt source still references - and every later
  # `apt-get update` on the machine fails with an unsigned-repository
  # error. Chained with && for the same reason those two are: this runs as
  # an `if` condition inside install_binary_tool, which suspends -e for its
  # whole dynamic extent, so nothing here aborts on its own.
  curl -fsSL -o "$tmp/githubcli-archive-keyring.gpg" \
    https://cli.github.com/packages/githubcli-archive-keyring.gpg &&
    sudo install -m 0644 "$tmp/githubcli-archive-keyring.gpg" \
      /usr/share/keyrings/githubcli-archive-keyring.gpg &&
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
    sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  keyring_status=$?
  rm -rf "$tmp"
  [ "$keyring_status" = 0 ] || return 1
  # apt_update_once already ran for the earlier apt tools, so the index
  # predates the source just written - without forcing a re-index, apt
  # silently installs the distro's own much older gh (Ubuntu noble ships
  # one), or fails outright on an image that has none.
  prior_update_status="$APT_UPDATE_STATUS"
  APT_UPDATED=0
  apt_install gh
  status=$?
  # Whether the forced re-index worked only decides gh's own fate: if the
  # earlier update had already succeeded, the distro's own sources are
  # still freshly indexed, so leave the memoized status usable for every
  # tool after this one.
  if [ "$prior_update_status" = 0 ]; then
    APT_UPDATE_STATUS=0
  fi
  return "$status"
}

# --- npm-packaged tools (Node already ships on the universal image) -----

# --prefix "$HOME/.local": npm's default global prefix is root-owned when
# Node came from apt (unlike the universal image's own nvm-managed Node,
# whose prefix is already user-owned) - a plain `npm install -g` here
# fails with EACCES. ~/.local/bin is on PATH both here (the export at the
# top of this file) and in the user's shell (work/zshrc), so this needs
# no separate npm config change.
install_prettierd() {
  command -v npm >/dev/null 2>&1 || return 1
  npm install -g --prefix "$HOME/.local" @fsouza/prettierd
}

install_claude_code() {
  command -v npm >/dev/null 2>&1 || return 1
  npm install -g --prefix "$HOME/.local" @anthropic-ai/claude-code
}

# --- direct release-binary downloads (packaged versions are too old / --
# --- absent from apt entirely) ------------------------------------------

# Ubuntu's neovim package lags upstream by several minor versions - fetch
# the latest stable release tarball straight from GitHub's release
# assets (not a git clone) and unpack it under ~/.local.
install_neovim() {
  local tmp status
  tmp="$(mktemp -d)"
  # Chained with && and the status captured explicitly: install_binary_tool
  # calls this as an `if` condition, which suspends -e for its whole
  # dynamic extent, so a failed curl/tar wouldn't otherwise abort here -
  # and if `rm -rf` (which always succeeds) were left as the last
  # statement, its exit status would silently overwrite a real failure
  # with success. Capturing status ourselves is what makes a real
  # download/extract failure actually get reported as pending.
  curl -fsSL -o "$tmp/nvim.tar.gz" \
    https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz &&
    mkdir -p "$HOME/.local" &&
    # The release tarball nests everything under one nvim-linux-x86_64/
    # directory (bin/, lib/, share/) - strip it so the contents land
    # directly under ~/.local, same layout as ~/.local/bin already expects.
    tar -C "$HOME/.local" --strip-components=1 -xzf "$tmp/nvim.tar.gz"
  status=$?
  rm -rf "$tmp"
  return "$status"
}

# stylua isn't packaged for apt at all - GitHub release zip is the
# official distribution method (see https://github.com/JohnnyMorganz/StyLua).
install_stylua() {
  local tmp status
  tmp="$(mktemp -d)"
  # See install_neovim's comment for why this is a && chain with an
  # explicitly captured status rather than a plain sequence of
  # statements ending in `rm -rf`.
  { command -v unzip >/dev/null 2>&1 || apt_install unzip; } &&
    curl -fsSL -o "$tmp/stylua.zip" \
      https://github.com/JohnnyMorganz/StyLua/releases/latest/download/stylua-linux-x86_64.zip &&
    unzip -q -o "$tmp/stylua.zip" -d "$tmp" &&
    mkdir -p "$HOME/.local/bin" &&
    install -m 0755 "$tmp/stylua" "$HOME/.local/bin/stylua"
  status=$?
  rm -rf "$tmp"
  return "$status"
}

# Official standalone installer - downloads a prebuilt binary from GitHub
# Releases, same as the ruff/starship cases below (see
# https://docs.astral.sh/ruff/installation/). Not a git clone.
#
# RUFF_NO_MODIFY_PATH=1: left to itself the cargo-dist installer appends
# `. "$HOME/.local/bin/env"` to the first of ~/.zshrc/~/.zshenv that
# exists - and after the first bootstrap ~/.zshrc is a symlink to this
# repo's tracked work/zshrc, so the append would write straight through
# into the checkout (and, if ever committed, onto the Mac work host too).
# On a first run it instead *creates* a ~/.zshrc that install_zshrc then
# has to back up for no reason. PATH is already handled by the export at
# the top of this file and by work/zshrc, so nothing is lost.
install_ruff() {
  curl -LsSf https://astral.sh/ruff/install.sh | RUFF_NO_MODIFY_PATH=1 sh
}

# Official installer - downloads a prebuilt binary from GitHub Releases
# (see https://starship.rs/guide/#%F0%9F%9A%80-installation). --yes skips
# the interactive confirmation prompt, required for a non-interactive
# codespace setup.
install_starship() {
  curl -fsSL https://starship.rs/install.sh | sh -s -- --yes
}

# # Official installer[](https://herdr.dev/docs/install/)
# # Puts the binary on PATH; works on the Codespaces Linux image.
install_herdr() {
  curl -fsSL https://herdr.dev/install.sh | sh
}

install_apt_tools() {
  # curl first: install_gh below and every release-binary install depend
  # on it.
  install_binary_tool curl curl install_curl
  install_binary_tool git git install_git
  install_binary_tool jq jq install_jq
  install_binary_tool rg ripgrep install_ripgrep
  install_binary_tool fd fd install_fd
  install_binary_tool direnv direnv install_direnv
  install_binary_tool rbenv rbenv install_rbenv
  install_binary_tool gh gh install_gh
  install_binary_tool zsh zsh install_zsh
  install_zsh_plugin_packages
}

# cli, label, and apt package(s) for each language runtime that ships on
# the universal Codespaces image already - apt here is only a safety net
# for a non-universal base image, and its versions may lag what the
# universal image ships, so it's a fallback rather than the primary path.
install_language_runtime_fallback() {
  local cli="$1" label="$2"
  shift 2
  if command -v "$cli" >/dev/null 2>&1; then
    SKIPPED_PRESENT+=("$label")
    return
  fi
  echo "==> $label not found, installing from apt (older than the universal image's own $label)"
  if apt_install "$@"; then
    INSTALLED+=("$label (apt fallback)")
  else
    echo "    WARN: could not install $label" >&2
    PENDING+=("$label")
  fi
}

install_language_runtimes() {
  # Ubuntu's nodejs package doesn't bundle npm the way the universal
  # image's own Node (via nvm) does - both packages, or install_claude_code
  # /install_prettierd (npm install -g) fail right after with npm missing.
  install_language_runtime_fallback node node nodejs npm
  install_language_runtime_fallback go go golang-go
  install_language_runtime_fallback python3 python3 python3
}

install_release_binaries() {
  install_binary_tool nvim neovim install_neovim
  install_binary_tool stylua stylua install_stylua
  install_binary_tool ruff ruff install_ruff
  install_binary_tool starship starship install_starship
  install_binary_tool herdr herdr install_herdr
  install_binary_tool claude "claude-code" install_claude_code
  install_binary_tool prettierd prettierd install_prettierd
}

# codespace-only: there is no equivalent in work/bootstrap.sh because the
# Mac's default shell is already zsh (has been since macOS Catalina), so
# it never needed to chsh.
set_zsh_as_default_shell() {
  local zsh_path
  zsh_path="$(command -v zsh)" || return 0
  if [ "${SHELL:-}" != "$zsh_path" ]; then
    sudo chsh -s "$zsh_path" "$(whoami)" || echo "    WARN: could not chsh to zsh (non-fatal)"
  fi
}

print_summary() {
  echo ""
  echo "==> done"
  if [ "${#INSTALLED[@]}" -gt 0 ]; then
    echo "Installed:"
    printf '  - %s\n' "${INSTALLED[@]}"
  fi
  if [ "${#SKIPPED_PRESENT[@]}" -gt 0 ]; then
    echo "Already present, skipped:"
    printf '  - %s\n' "${SKIPPED_PRESENT[@]}"
  fi
  echo "Deliberately not installed (macOS-only, no codespace equivalent):"
  echo "  - ghostty, docker-desktop, font-inconsolata-nerd-font"
  echo "Deliberately not synced: neovim plugins (nvim config is linked, but"
  echo "  Lazy is not pre-synced here - see AGENTS.md; first manual nvim"
  echo "  launch will bootstrap Lazy itself, same as the Mac work host today)"
  local git_gh_pending
  git_gh_pending="$(print_git_gh_pending)"
  if [ "${#PENDING[@]}" -gt 0 ] || [ -n "$git_gh_pending" ]; then
    echo "Still needs attention:"
    if [ "${#PENDING[@]}" -gt 0 ]; then
      printf '  - could not install: %s\n' "${PENDING[@]}"
    fi
    # if/fi, not a bare `[ ... ] && ...`: this is the last command of
    # print_summary, which is the last command of main, so a false test
    # here would become the whole script's exit status and fail the
    # codespace setup over a partial-but-reported install - the exact
    # pitfall AGENTS.md documents. Reachable whenever a download failed
    # but git identity and gh auth are both fine, the normal state in a
    # real work codespace.
    if [ -n "$git_gh_pending" ]; then
      printf '%s\n' "$git_gh_pending"
    fi
  else
    echo "Everything applied cleanly."
  fi
}

main() {
  local repo="${1:?usage: codespace-bootstrap.sh <repo-dir>}"
  install_apt_tools
  install_language_runtimes
  install_release_binaries
  install_symlinks "$repo"
  install_zshrc "$repo"
  install_claude_settings "$repo"
  # configure_git's interactive identity prompt only fires on a real TTY
  # (`[ -t 0 ]`), which a non-interactive Codespaces setup-script run
  # never has - it degrades to report-pending-don't-prompt here, exactly
  # what this path needs, with no codespace-specific override required.
  configure_git
  set_zsh_as_default_shell
  print_summary
}

# Allow work/codespace-bootstrap.test.sh to source this file and call
# individual functions without running the whole bootstrap.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
