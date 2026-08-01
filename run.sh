#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MARKER="$DIR/.dotfiles-host"

usage() {
  cat <<'EOF'
Usage: ./run.sh [command] [host] [--no-nix]

With no command at all, ./run.sh behaves like `./run.sh bootstrap`.

WHAT IS A "host"?
  A host is a named machine recipe — a label, not a folder. Every machine
  clones this same repo; the host name picks which recipe gets applied,
  so different machines can get different package lists from identical
  code.
  Hosts defined right now:
    personal-mac   everything, via Nix + home-manager
    work           work-safe subset, via plain Homebrew (--no-nix)
  Planned:
    ci             personal-mac minus Homebrew, for GitHub Actions

PICKING A HOST
  If you don't pass a host, ./run.sh figures one out in this order:
    1. A remembered choice from a previous run on this machine.
    2. On an interactive terminal with nothing remembered yet, it asks
       once: "home computer or work computer?" and remembers the answer.
    3. Otherwise it fails with an explicit instruction — it never hangs
       waiting on a prompt in a non-interactive session.
  Re-ask any time with: ./run.sh choose
  Skip the menu any time by passing a host and/or --no-nix explicitly —
  this is also the only way to drive the (planned) ci host.

COMMANDS
  bootstrap [host]   First-time setup on a new machine. Safe to re-run
                     if it fails partway. On the personal-mac host this
                     installs Nix, links this repo to ~/.dotfiles, and
                     applies the config. On the work host (--no-nix)
                     this installs from work/Brewfile and wires up
                     configs with plain shell — see README.md.
  plan [host]        Shows what WOULD change without touching anything.
                     Nix hosts only.
  rebuild [host]     Re-applies the config. Run after editing any
                     tracked config file. Safe to re-run anytime.
  choose             Re-run the home/work menu and remember the answer.
  help               This screen.

FLAGS
  --no-nix           Selects the work (brew-only) host explicitly,
                     bypassing both the remembered choice and the menu.
EOF
}

choose_host() {
  echo "Is this a home computer or a work computer?"
  echo "  1) home  (personal-mac: full Nix + home-manager setup)"
  echo "  2) work  (brew-only, no Nix)"
  local choice
  read -r -p "Choose [1/2]: " choice
  case "$choice" in
    1) HOST="personal-mac"; RESOLVED_NO_NIX=0 ;;
    2) HOST="work"; RESOLVED_NO_NIX=1 ;;
    *) echo "Not a valid choice." >&2; exit 1 ;;
  esac
  {
    echo "$HOST"
    if [ "$RESOLVED_NO_NIX" = 1 ]; then echo "no-nix"; else echo "nix"; fi
  } > "$MARKER"
  echo "    remembered '$HOST' for this machine (re-choose with ./run.sh choose)"
}

# Sets HOST and RESOLVED_NO_NIX (0/1) from, in order: explicit args, the
# remembered marker, or (if allowed and interactive) the menu.
resolve_host() {
  local explicit_host="$1" explicit_no_nix="$2" allow_menu="$3"

  if [ -n "$explicit_host" ]; then
    HOST="$explicit_host"
    RESOLVED_NO_NIX="$explicit_no_nix"
    # "work" only exists as a --no-nix host today; treat it as such even
    # if --no-nix wasn't repeated on the command line.
    [ "$HOST" = "work" ] && RESOLVED_NO_NIX=1
    return
  fi

  if [ "$explicit_no_nix" = 1 ]; then
    HOST="work"
    RESOLVED_NO_NIX=1
    return
  fi

  if [ -f "$MARKER" ]; then
    HOST="$(sed -n '1p' "$MARKER")"
    if [ "$(sed -n '2p' "$MARKER")" = "no-nix" ]; then
      RESOLVED_NO_NIX=1
    else
      RESOLVED_NO_NIX=0
    fi
    return
  fi

  if [ "$allow_menu" = 1 ] && [ -t 0 ]; then
    choose_host
    return
  fi

  echo "No host given, nothing remembered for this machine, and this isn't" >&2
  echo "an interactive session, so ./run.sh won't guess. Run explicitly:" >&2
  echo "  ./run.sh bootstrap personal-mac" >&2
  echo "  ./run.sh bootstrap work --no-nix" >&2
  exit 1
}

cmd_bootstrap_nix() {
  local host="$1"

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

cmd_bootstrap_no_nix() {
  local host="$1"
  echo "==> no-nix bootstrap for host '$host'"
  "$DIR/work/bootstrap.sh" "$DIR"
}

cmd_bootstrap() {
  resolve_host "${1:-}" "$no_nix" 1
  if [ "$RESOLVED_NO_NIX" = 1 ]; then
    cmd_bootstrap_no_nix "$HOST"
  else
    cmd_bootstrap_nix "$HOST"
  fi
}

cmd_plan() {
  resolve_host "${1:-}" "$no_nix" 1
  if [ "$RESOLVED_NO_NIX" = 1 ]; then
    echo "==> work host has no Nix-style dry-run; showing missing brew packages instead"
    "$(command -v brew || echo /opt/homebrew/bin/brew)" bundle check --file="$DIR/work/Brewfile" --verbose
    return
  fi
  if ! command -v nix >/dev/null 2>&1; then
    echo "Nix isn't installed yet — run ./run.sh bootstrap first."
    exit 1
  fi
  echo "==> building '$HOST' config (nothing on this machine will change)"
  nix build "$DIR#darwinConfigurations.$HOST.system" -o /tmp/dotfiles-plan
  if [ -e /run/current-system ]; then
    echo "==> difference vs this machine right now:"
    nix store diff-closures /run/current-system /tmp/dotfiles-plan
  else
    echo "==> no nix-darwin system exists here yet; everything in the config is new."
  fi
}

cmd_rebuild() {
  resolve_host "${1:-}" "$no_nix" 1
  if [ "$RESOLVED_NO_NIX" = 1 ]; then
    cmd_bootstrap_no_nix "$HOST"
    return
  fi
  ln -sfn "$DIR" ~/.dotfiles
  sudo darwin-rebuild switch --flake ~/.dotfiles#"$HOST"
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

no_nix=0
args=()
for arg in "$@"; do
  if [ "$arg" = "--no-nix" ]; then
    no_nix=1
  else
    args+=("$arg")
  fi
done
set -- ${args[@]+"${args[@]}"}

case "${1:-bootstrap}" in
  bootstrap) shift; cmd_bootstrap "$@" ;;
  plan)      shift; cmd_plan "$@" ;;
  rebuild)   shift; cmd_rebuild "$@" ;;
  choose)    choose_host ;;
  help|--help|-h) usage ;;
  *)         usage; exit 1 ;;
esac
