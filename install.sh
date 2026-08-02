#!/usr/bin/env bash
# GitHub Codespaces auto-install entry point. GitHub clones this repo and
# looks for one of a fixed set of filenames to run as the setup script,
# checked in this order: install.sh, install, bootstrap.sh, bootstrap,
# script/bootstrap, setup.sh, setup, script/setup. install.sh is checked
# first, so it's the canonical choice here.
#
# Fully non-interactive by construction: requires CODESPACES=true and never
# prompts. For a real machine (Mac or the captain's home Ubuntu box) use
# ./run.sh instead - see README.md.
#
# A thin launcher, not a second package manifest: it installs Nix, then
# applies one of two home-manager profiles (flake.nix's
# homeConfigurations."codespace-personal"/"codespace-work", both built from
# modules/core.nix + modules/codespace.nix) that carry the actual package
# list - the same one personal-mac and home-linux use. Posture only picks
# which of the two small deltas modules/codespace.nix still varies by hand
# (the Claude settings file, and the `cc` alias) - see README.md and
# AGENTS.md. Work Mac's separate --no-nix path (work/bootstrap.sh) is a
# different host entirely and untouched by this.
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

# Determinate Nix's own installer script, --init none: a codespace is
# already a running container with no devcontainer.json control over it
# (unlike a fresh container build, there's no hook to add a systemd unit),
# so this is the "no init system to hand the daemon to" container-safe
# mode - see https://github.com/DeterminateSystems/nix-installer, and
# install.container-test.sh, which exercises this for real.
install_nix() {
  if command -v nix >/dev/null 2>&1; then
    echo "==> Nix already installed, skipping"
    return
  fi
  echo "==> installing Nix (Determinate installer, container-safe mode)"
  # sandbox = false: a codespace container's own seccomp/cgroup setup
  # commonly can't nest Nix's build sandbox (it needs to create its own
  # user+mount namespaces) - see install.container-test.sh, which hit
  # "unable to load seccomp BPF program" without this.
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix |
    sh -s -- install linux --init none --extra-conf "sandbox = false" --no-confirm
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
}

# --init none means nothing starts/supervises nix-daemon for us; without it
# running, every Nix command from a non-root user fails to reach the store.
#
# Liveness is a real daemon round-trip, not a socket-file existence test:
# the socket file outlives a dead daemon (nothing restarts it after a
# codespace stop/resume, while /nix - stale socket included - persists), so
# an existence test would make a repair rerun skip startup and then fail
# later at the home-manager step with a bare connection error.
nix_daemon_alive() {
  /nix/var/nix/profiles/default/bin/nix store info --store daemon >/dev/null 2>&1
}

start_nix_daemon() {
  if nix_daemon_alive; then
    echo "==> nix-daemon already running"
    return
  fi
  echo "==> starting nix-daemon (--init none leaves no service manager to do it)"
  sudo rm -f /nix/var/nix/daemon-socket/socket
  # shellcheck disable=SC2024 # /tmp/nix-daemon.log is written by us, not
  # sudo - only the daemon process itself needs to run as root.
  sudo -b /nix/var/nix/profiles/default/bin/nix-daemon >/tmp/nix-daemon.log 2>&1
  local _i
  for _i in $(seq 1 30); do
    if nix_daemon_alive; then
      echo "==> nix-daemon up"
      return
    fi
    sleep 1
  done
  echo "nix-daemon did not start within 30s - see /tmp/nix-daemon.log" >&2
  exit 1
}

# The out-of-store symlinks in modules/core.nix (nvim config, AGENTS.md, ...)
# resolve through ~/.dotfiles, exactly like run.sh's Nix path sets up on
# personal-mac/home-linux - so editing ~/.dotfiles/home/... in a running
# codespace IS editing this clone, same as everywhere else.
apply_home_manager_profile() {
  local posture="$1" nix_bin
  echo "==> linking repo to ~/.dotfiles"
  ln -sfn "$SCRIPT_DIR" "$HOME/.dotfiles"
  nix_bin="$(command -v nix)"
  echo "==> applying the codespace-$posture home-manager profile"
  # --impure: flake.nix reads USER from the environment for this profile
  # rather than hardcoding the captain's own username (see flake.nix) -
  # export it explicitly since not every codespace base image is
  # guaranteed to have it set.
  #
  # -b hm-backup MUST precede `switch`: home-manager's `[OPTION] COMMAND`
  # CLI shape means `-b` is a top-level flag, not one `switch` itself
  # accepts - `switch --flake ... -b hm-backup` silently drops it instead
  # of erroring, so a base image that happens to ship a default ~/.zshrc
  # (or any other file this profile also manages) would abort the whole
  # activation instead of getting backed up - see install.container-test.sh.
  USER="$(whoami)" "$nix_bin" run github:nix-community/home-manager/release-26.05#home-manager -- \
    -b hm-backup switch --flake "$HOME/.dotfiles#codespace-$posture" --impure
  # A bare `[ cond ] && cmd` here would make this function's own return
  # status depend on that test - fine everywhere it's used, but a trap for
  # future callers where this ends up as the last statement (see AGENTS.md).
  if [ -f "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
  fi
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
  "$(command -v nvim)" --headless "+Lazy! sync" +qa
}

main() {
  require_codespaces
  local posture
  posture="$(detect_posture)"
  echo "==> posture: $posture"

  install_nix
  start_nix_daemon
  apply_home_manager_profile "$posture"
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
