#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_HOST="personal-mac"

usage() {
  cat <<'EOF'
Usage: ./run.sh <command> [host]

WHAT IS A "host"?
  A host is a named machine recipe defined in flake.nix — a label, not a
  folder. Every machine clones this same repo; the host name picks which
  recipe gets applied, so different machines can get different package
  lists from identical code.
  Hosts defined right now:
    personal-mac   everything (the default when [host] is omitted)
  Planned:
    work           work-safe subset (may use --no-nix, see FLAGS)
    ci             personal-mac minus Homebrew, for GitHub Actions

COMMANDS
  bootstrap [host]   First-time setup on a new machine. Installs Nix,
                     links this repo to ~/.dotfiles, applies the config.
                     Safe to re-run if it fails partway.
  plan [host]        Shows what WOULD change (packages added/removed)
                     without touching anything. Run before rebuild
                     whenever you're unsure. Needs Nix installed.
  rebuild [host]     Applies the config. Run after editing any .nix
                     file. Safe to re-run anytime.
  help               This screen.

FLAGS
  --no-nix           NOT BUILT YET. Fallback for machines where Nix is
                     not allowed: installs from a Brewfile and creates
                     the same symlinks with plain shell. Same repo,
                     same configs, no Nix.
EOF
}

cmd_bootstrap() {
  local host="${1:-$DEFAULT_HOST}"

  echo "==> 1/4 Nix"
  if command -v nix >/dev/null 2>&1; then
    echo "    already installed, skipping"
  else
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
      | sh -s -- install --no-confirm
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi

  echo "==> 2/4 link repo to ~/.dotfiles"
  ln -sfn "$DIR" ~/.dotfiles

  echo "==> 3/4 username check"
  local real_user
  real_user="$(whoami)"
  if ! grep -q "user = \"$real_user\"" "$DIR/flake.nix"; then
    echo "    flake.nix's 'user = ' line doesn't match '$real_user'."
    echo "    Edit that one line in flake.nix, then re-run ./run.sh bootstrap"
    exit 1
  fi
  echo "    flake.nix matches '$real_user'"

  echo "==> 4/4 first build + apply (10-20 min of downloads; will ask for sudo)"
  local nix_bin
  nix_bin="$(command -v nix)"
  sudo "$nix_bin" run github:nix-darwin/nix-darwin/nix-darwin-26.05#darwin-rebuild -- \
    switch --flake ~/.dotfiles#"$host"
  check_gh_auth
  echo "==> Done. Day-to-day command from now on: ./run.sh rebuild"
}

cmd_plan() {
  local host="${1:-$DEFAULT_HOST}"
  if ! command -v nix >/dev/null 2>&1; then
    echo "Nix isn't installed yet — run ./run.sh bootstrap first."
    exit 1
  fi
  echo "==> building '$host' config (nothing on this machine will change)"
  nix build "$DIR#darwinConfigurations.$host.system" -o /tmp/dotfiles-plan
  if [ -e /run/current-system ]; then
    echo "==> difference vs this machine right now:"
    nix store diff-closures /run/current-system /tmp/dotfiles-plan
  else
    echo "==> no nix-darwin system exists here yet; everything in the config is new."
  fi
}

cmd_rebuild() {
  local host="${1:-$DEFAULT_HOST}"
  ln -sfn "$DIR" ~/.dotfiles
  sudo darwin-rebuild switch --flake ~/.dotfiles#"$host"
  check_gh_auth
}

check_gh_auth() {
  local gh_bin
  gh_bin="$(command -v gh || echo "/etc/profiles/per-user/$(whoami)/bin/gh")"
  if [ -x "$gh_bin" ] && ! "$gh_bin" auth status >/dev/null 2>&1; then
    echo ""
    echo "⚠️  You're not logged into GitHub. Run: gh auth login"
  fi
}

case "${1:-help}" in
  bootstrap) shift; cmd_bootstrap "$@" ;;
  plan)      shift; cmd_plan "$@" ;;
  rebuild)   shift; cmd_rebuild "$@" ;;
  help|--help|-h|*) usage ;;
esac
