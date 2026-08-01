#!/usr/bin/env bash
# GitHub Codespaces auto-install entry point. GitHub clones this repo and
# looks for one of a fixed set of filenames to run as the setup script,
# checked in this order: install.sh, install, bootstrap.sh, bootstrap,
# script/bootstrap, setup.sh, setup, script/setup. install.sh is checked
# first, so it's the canonical choice here.
#
# Fully non-interactive by construction: requires CODESPACES=true and never
# prompts. For a real machine (Mac or the captain's home Ubuntu box) use
# ./run.sh instead - see README.md. There is no work-linux host: a
# corporate/work codespace is detected automatically below and gets the
# locked-down posture instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

require_codespaces() {
  if [ "${CODESPACES:-}" != "true" ]; then
    echo "install.sh is the GitHub Codespaces auto-install entry point" >&2
    echo "(expects CODESPACES=true). For a real machine, run ./run.sh instead" >&2
    echo "- see README.md." >&2
    exit 1
  fi
}

# Personal vs work posture, structural and username-agnostic: compares the
# workspace repo's owner (GITHUB_REPOSITORY, set by Codespaces to whatever
# project this codespace was opened for) against this dotfiles repo's own
# origin owner. In a codespace, dotfiles are always cloned from the
# captain's own account, so that owner IS the personal identity - same
# owner means a personal project, anything else (including undeterminable)
# means work, the locked-down default.
detect_posture() {
  local dotfiles_dir="${1:-$SCRIPT_DIR}"
  local dotfiles_owner="" workspace_owner="" origin_url=""

  if origin_url="$(git -C "$dotfiles_dir" remote get-url origin 2>/dev/null)"; then
    dotfiles_owner="$(
      printf '%s\n' "$origin_url" |
        sed -E 's#^(git@github\.com:|https://github\.com/|ssh://git@github\.com/)##; s#\.git$##' |
        cut -d/ -f1
    )"
  fi

  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    workspace_owner="${GITHUB_REPOSITORY%%/*}"
  fi

  if [ -n "$dotfiles_owner" ] && [ -n "$workspace_owner" ] &&
    [ "$(printf '%s' "$dotfiles_owner" | tr '[:upper:]' '[:lower:]')" = \
      "$(printf '%s' "$workspace_owner" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "personal"
  else
    echo "work"
  fi
}

# Replaces $target with a symlink to $source, backing up a pre-existing
# real file or directory (not one of our own symlinks) exactly once. Same
# helper as work/bootstrap.sh's link_with_backup.
link_with_backup() {
  local source="$1" target="$2"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    mv "$target" "$target.pre-dotfiles-backup"
    echo "    backed up existing $target -> $target.pre-dotfiles-backup"
  fi
  ln -sfn "$source" "$target"
}

install_apt_packages() {
  echo "==> apt: base packages"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl unzip git zsh \
    ripgrep fd-find jq \
    zsh-autosuggestions zsh-syntax-highlighting direnv
}

# Ubuntu 24.04's apt nodejs is 18.x, too old for @anthropic-ai/claude-code
# and @fsouza/prettierd (both require Node >=22) - NodeSource's official
# setup script swaps in a current LTS instead.
install_node() {
  if command -v npm >/dev/null 2>&1 && \
    [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ]; then
    echo "==> node $(node -v) already installed, skipping"
    return
  fi
  echo "==> node 22.x (NodeSource - apt's nodejs is 18.x, too old for the npm tools below)"
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs
}

link_fd() {
  mkdir -p "$HOME/.local/bin"
  if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
    ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
  fi
}

# Ubuntu 24.04's apt neovim is 0.9.5; this config's lazy.nvim bootstrap
# calls vim.uv directly (see home/.config/nvim/lua/lazy_init.lua), which
# needs 0.10+. Installed from the official prebuilt tarball instead.
install_neovim() {
  local version="v0.11.7"
  local install_dir="$HOME/.local/opt/nvim-$version"
  if [ -x "$install_dir/bin/nvim" ]; then
    echo "==> neovim $version already installed, skipping"
  else
    echo "==> neovim $version (official tarball, not apt)"
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/nvim.tar.gz" \
      "https://github.com/neovim/neovim/releases/download/$version/nvim-linux-x86_64.tar.gz"
    mkdir -p "$install_dir"
    tar -xzf "$tmp/nvim.tar.gz" -C "$install_dir" --strip-components=1
    rm -rf "$tmp"
  fi
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$install_dir/bin/nvim" "$HOME/.local/bin/nvim"
}

configure_npm_prefix() {
  mkdir -p "$HOME/.local"
  npm config set prefix "$HOME/.local" >/dev/null
}

install_formatters() {
  echo "==> formatters: ruff, stylua, prettierd"
  curl -LsSf https://astral.sh/ruff/install.sh | sh >/dev/null

  local stylua_version="2.5.2" tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/stylua.zip" \
    "https://github.com/JohnnyMorganz/StyLua/releases/download/v$stylua_version/stylua-linux-x86_64.zip"
  mkdir -p "$HOME/.local/bin"
  (cd "$tmp" && unzip -oq stylua.zip && install -m755 stylua "$HOME/.local/bin/stylua")
  rm -rf "$tmp"

  npm install -g @fsouza/prettierd >/dev/null
}

install_starship() {
  echo "==> starship"
  mkdir -p "$HOME/.local/bin"
  curl -sS https://starship.rs/install.sh | sh -s -- --yes --bin-dir "$HOME/.local/bin" >/dev/null
}

install_claude_code() {
  echo "==> Claude Code CLI"
  npm install -g @anthropic-ai/claude-code >/dev/null
}

# Baseline config symlinks + zshrc. Ghostty/wezterm/tmux/herdr are all
# client-side terminal concerns (the terminal app runs on the developer's
# machine, not inside the codespace container) so none of them belong
# here - same reasoning as the "no font install" rule below.
install_symlinks() {
  echo "==> linking configs"
  mkdir -p "$HOME/.config" "$HOME/.claude"
  link_with_backup "$SCRIPT_DIR/home/.config/nvim" "$HOME/.config/nvim"
  link_with_backup "$SCRIPT_DIR/home/.config/starship.toml" "$HOME/.config/starship.toml"
  link_with_backup "$SCRIPT_DIR/home/AGENTS.md" "$HOME/AGENTS.md"
  link_with_backup "$SCRIPT_DIR/home/AGENTS.md" "$HOME/.claude/CLAUDE.md"
  link_with_backup "$SCRIPT_DIR/codespaces/zshrc" "$HOME/.zshrc"
}

# codespaces/claude-settings.json and work/claude-settings.json are both
# home/.claude/settings.json with the axi-tool hooks stripped (those tools
# are explicitly not installed in codespaces, personal or work); the work
# variant additionally drops skipDangerousModePermissionPrompt, since work
# posture's `cc` alias never uses --dangerously-skip-permissions.
install_claude_settings() {
  local posture="$1" source
  if [ "$posture" = "personal" ]; then
    source="$SCRIPT_DIR/codespaces/claude-settings.json"
  else
    source="$SCRIPT_DIR/work/claude-settings.json"
  fi
  mkdir -p "$HOME/.claude"
  link_with_backup "$source" "$HOME/.claude/settings.json"
}

# Personal posture gets the same --dangerously-skip-permissions `cc` alias
# as personal-mac/home-linux, layered on via .zshrc.local (never committed)
# rather than a second zshrc variant - codespaces/zshrc's plain `cc=claude`
# is the safe, locked-down default work posture keeps as-is.
configure_posture_shell() {
  local posture="$1"
  local line='alias cc="claude --dangerously-skip-permissions"'
  if [ "$posture" = "personal" ]; then
    touch "$HOME/.zshrc.local"
    grep -qxF "$line" "$HOME/.zshrc.local" || echo "$line" >>"$HOME/.zshrc.local"
  elif [ -f "$HOME/.zshrc.local" ]; then
    # A given codespace's workspace repo never actually changes, so this is
    # belt-and-suspenders rather than an expected real-world path - but a
    # rerun must never leave the personal skip-permissions alias behind
    # once posture has resolved to work.
    grep -vxF "$line" "$HOME/.zshrc.local" >"$HOME/.zshrc.local.tmp" || true
    mv "$HOME/.zshrc.local.tmp" "$HOME/.zshrc.local"
  fi
}

# Identity is deliberately left alone: GitHub Codespaces already sets
# GIT_COMMITTER_NAME/EMAIL (and the GIT_AUTHOR_* equivalents git also
# honors) and configures git auth itself - setting user.name/user.email
# here would fight that, not help it.
configure_git() {
  echo "==> git behavior config (identity left to Codespaces)"
  git config --global push.autoSetupRemote true
  git config --global core.editor nvim
}

set_zsh_as_default_shell() {
  local zsh_path
  zsh_path="$(command -v zsh)"
  if [ "${SHELL:-}" != "$zsh_path" ]; then
    sudo chsh -s "$zsh_path" "$(whoami)" || echo "    WARN: could not chsh to zsh (non-fatal)"
  fi
}

sync_neovim_plugins() {
  echo "==> headless nvim plugin sync (Lazy)"
  "$HOME/.local/bin/nvim" --headless "+Lazy! sync" +qa
}

main() {
  require_codespaces
  local posture
  posture="$(detect_posture)"
  echo "==> posture: $posture"

  install_apt_packages
  install_node
  link_fd
  install_neovim
  configure_npm_prefix
  install_formatters
  install_starship
  install_claude_code
  install_symlinks
  install_claude_settings "$posture"
  configure_posture_shell "$posture"
  configure_git
  set_zsh_as_default_shell
  sync_neovim_plugins

  echo ""
  echo "==> done in ${SECONDS}s (posture: $posture)"
}

# Allow install.test.sh to source this file and call individual functions
# without running the whole install.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
