#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || DIR=""
MARKER="$DIR/.dotfiles-host"

# Refuses to continue if $dir isn't a real path to this repo checkout. DIR
# can resolve empty (or to a stale/unrelated path) when run.sh's own
# directory is removed or replaced out from under it - e.g. a throwaway
# worktree cleaned up while a script invoked from it is still running. An
# empty DIR reaching the ln -sfn calls below is what wrote a symlink to
# nowhere over the live ~/.dotfiles (issue #9).
validate_dir() {
  local dir="$1"
  if [ -z "$dir" ] || [ ! -f "$dir/run.sh" ] || [ ! -f "$dir/flake.nix" ]; then
    echo "run.sh: can't verify its own directory (got '$dir')." >&2
    echo "This usually means the checkout run.sh lives in was moved or" >&2
    echo "deleted while it was still running, or \$DIR doesn't look like" >&2
    echo "this repo (missing run.sh/flake.nix). Refusing to continue -" >&2
    echo "writing ~/.dotfiles from a bad path is how issue #9 corrupted it." >&2
    return 1
  fi
}

validate_dir "$DIR" || exit 1

usage() {
  cat <<'EOF'
Usage: ./run.sh [command] [host] [--no-nix] [--relink]

With no command at all, ./run.sh behaves like `./run.sh bootstrap`.

WHAT IS A "host"?
  A host is a named machine recipe - a label, not a folder. Every machine
  clones this same repo; the host name picks which recipe gets applied,
  so different machines can get different package lists from identical
  code.
  Hosts defined right now:
    personal-mac   home Mac, everything via Nix + home-manager
    home-linux     home Ubuntu 24.04 box, via Nix + standalone home-manager
    work           work Mac, work-safe subset via plain Homebrew (--no-nix)
  Not picked here:
    codespaces     GitHub Codespaces auto-detects and runs install.sh at
                   clone time (see README.md) - fully non-interactive, never
                   goes through this menu. There is no work-linux host;
                   Codespaces covers work-on-Linux instead.
  Planned:
    ci             personal-mac minus Homebrew, for GitHub Actions

PICKING A HOST
  If you don't pass a host, ./run.sh figures one out in this order:
    1. A remembered choice from a previous run on this machine.
    2. On an interactive terminal with nothing remembered yet, it asks
       once: "home computer or work computer?". A "home" answer picks
       personal-mac or home-linux by auto-detecting `uname -s` - it never
       asks what it can detect. A "work" answer on Linux fails immediately
       with an explicit message: there is no work-linux host, Codespaces
       covers that case. Either way the answer is remembered.
    3. Otherwise it fails with an explicit instruction - it never hangs
       waiting on a prompt in a non-interactive session.
  Re-ask any time with: ./run.sh choose
  Skip the menu any time by passing a host and/or --no-nix explicitly -
  this is also the only way to drive the (planned) ci host.

COMMANDS
  bootstrap [host]   First-time setup on a new machine. Safe to re-run
                     if it fails partway. On the personal-mac host this
                     installs Nix, links this repo to ~/.dotfiles, and
                     applies the config. On the work host (--no-nix)
                     this installs from work/Brewfile and wires up
                     configs with plain shell - see README.md.
  plan [host]        Shows what WOULD change without touching anything.
                     Nix hosts only.
  rebuild [host]     Re-applies the config. Run after editing any
                     tracked config file. Safe to re-run anytime.
  choose             Re-run the home/work menu and remember the answer.
  help               This screen.

FLAGS
  --no-nix           Selects the work (brew-only) host explicitly,
                     bypassing both the remembered choice and the menu.
  --relink           If ~/.dotfiles is already a symlink pointing somewhere
                     other than this checkout, move it here instead of
                     refusing. Without this flag, an existing ~/.dotfiles
                     pointing elsewhere is left untouched. A ~/.dotfiles
                     that is a real file or directory is always refused,
                     --relink included - move it by hand first.
EOF
}

choose_host() {
  echo "Is this a home computer or a work computer?"
  echo "  1) home  (full Nix + home-manager setup - personal-mac or home-linux)"
  echo "  2) work  (brew-only, no Nix; Mac only - Linux work boxes use Codespaces)"
  local choice
  if ! read -r -p "Choose [1/2]: " choice; then
    echo "" >&2
    echo "No answer read - this doesn't look like an interactive session." >&2
    echo "Pick the host explicitly instead:" >&2
    echo "  ./run.sh bootstrap personal-mac" >&2
    echo "  ./run.sh bootstrap home-linux" >&2
    echo "  ./run.sh bootstrap work --no-nix" >&2
    exit 1
  fi
  case "$choice" in
    1)
      if [ "$(uname -s)" = "Linux" ]; then
        HOST="home-linux"
      else
        HOST="personal-mac"
      fi
      RESOLVED_NO_NIX=0
      ;;
    2)
      if [ "$(uname -s)" = "Linux" ]; then
        echo "" >&2
        echo "No work-linux host is defined. Work Linux machines are covered by" >&2
        echo "GitHub Codespaces (see README.md), which auto-runs install.sh - not" >&2
        echo "this menu." >&2
        exit 1
      fi
      HOST="work"; RESOLVED_NO_NIX=1
      ;;
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
    if [ "$HOST" = "work" ]; then RESOLVED_NO_NIX=1; fi
    return 0
  fi

  if [ "$explicit_no_nix" = 1 ]; then
    HOST="work"
    RESOLVED_NO_NIX=1
    return 0
  fi

  if [ -f "$MARKER" ]; then
    HOST="$(sed -n '1p' "$MARKER")"
    if [ "$(sed -n '2p' "$MARKER")" = "no-nix" ]; then
      RESOLVED_NO_NIX=1
    else
      RESOLVED_NO_NIX=0
    fi
    return 0
  fi

  if [ "$allow_menu" = 1 ] && [ -t 0 ]; then
    choose_host
    return 0
  fi

  echo "No host given, nothing remembered for this machine, and this isn't" >&2
  echo "an interactive session, so ./run.sh won't guess. Run explicitly:" >&2
  echo "  ./run.sh bootstrap personal-mac" >&2
  echo "  ./run.sh bootstrap home-linux" >&2
  echo "  ./run.sh bootstrap work --no-nix" >&2
  exit 1
}

# Points ~/.dotfiles at $target. Creates it when absent - first-run
# bootstrap on a fresh machine must keep working exactly as it does today.
# A silent no-op when it already resolves to $target, however that symlink
# happens to be spelled on disk (relative, trailing slash, hand-restored) -
# comparing raw `readlink` text against the physical $target would refuse a
# link that is already correct. When it exists and resolves somewhere else,
# refuses rather than silently clobbering it, unless $relink is 1 - see
# issue #9, where an unconditional `ln -sfn` here is what hijacked and then
# destroyed the live ~/.dotfiles. A ~/.dotfiles that is some OTHER real file
# or directory is refused, --relink included: --relink means "repoint an
# existing symlink", and `ln -sfn` against a real directory silently nests a
# stray symlink inside it and exits 0 - the same blind write issue #9 was
# about. The resolved-path comparison deliberately runs before that check,
# so a checkout cloned straight to ~/.dotfiles (DIR == $HOME/.dotfiles, a
# real directory that already resolves to $target) is the same silent no-op
# as a correct symlink instead of an unfixable refusal.
link_dotfiles() {
  local target="$1" relink="$2"
  local link="$HOME/.dotfiles"

  if [ ! -e "$link" ] && [ ! -L "$link" ]; then
    ln -sfn "$target" "$link"
    return 0
  fi

  local resolved
  resolved="$(cd "$link" 2>/dev/null && pwd -P)" || resolved=""

  if [ -n "$resolved" ] && [ "$resolved" = "$target" ]; then
    return 0
  fi

  if [ ! -L "$link" ]; then
    echo "$link already exists and is not a symlink - refusing to touch it." >&2
    echo "  proposed: $target" >&2
    echo "Move or remove it by hand, then re-run. --relink only repoints an" >&2
    echo "existing symlink; it will not clobber a real file or directory." >&2
    return 1
  fi

  local current
  current="$(readlink "$link")"

  if [ "$relink" = 1 ]; then
    echo "    relinking ~/.dotfiles: '$current' -> '$target'"
    ln -sfn "$target" "$link"
    return 0
  fi

  echo "$link already exists and doesn't point at this checkout - refusing to overwrite it." >&2
  echo "  current:  $current" >&2
  echo "  proposed: $target" >&2
  echo "Pass --relink to move it: ./run.sh bootstrap --relink" >&2
  return 1
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
  link_dotfiles "$DIR" "$relink"

  echo "==> 3/4 username check"
  local real_user
  real_user="$(whoami)"
  if ! grep -q "user = \"$real_user\"" "$DIR/flake.nix"; then
    echo "    flake.nix's 'user = ' line doesn't match '$real_user'."
    echo "    Edit that one line in flake.nix, then re-run ./run.sh bootstrap"
    exit 1
  fi
  echo "    flake.nix matches '$real_user'"

  local nix_bin
  nix_bin="$(command -v nix)"
  if [ "$host" = "home-linux" ]; then
    echo "==> 4/4 first build + apply (10-20 min of downloads)"
    "$nix_bin" run github:nix-community/home-manager/release-26.05#home-manager -- \
      switch --flake ~/.dotfiles#"$host"
  else
    echo "==> 4/4 first build + apply (10-20 min of downloads; will ask for sudo)"
    sudo "$nix_bin" run github:nix-darwin/nix-darwin/nix-darwin-26.05#darwin-rebuild -- \
      switch --flake ~/.dotfiles#"$host"
  fi
  check_gh_auth
  echo "==> Done. Day-to-day command from now on: ./run.sh rebuild"
}

cmd_bootstrap_no_nix() {
  local host="$1"
  if [ "$host" = "work" ] && [ "$(uname -s)" = "Linux" ]; then
    echo "No work-linux host is defined. Work Linux machines are covered by" >&2
    echo "GitHub Codespaces (see README.md), which auto-runs install.sh - the" >&2
    echo "work host's plain-Homebrew script only ever targets macOS." >&2
    exit 1
  fi
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
    local brew
    if command -v brew >/dev/null 2>&1; then
      brew="$(command -v brew)"
    elif [ -x /opt/homebrew/bin/brew ]; then
      brew=/opt/homebrew/bin/brew
    else
      brew=/usr/local/bin/brew
    fi
    "$brew" bundle check --file="$DIR/work/Brewfile" --verbose
    return
  fi
  if ! command -v nix >/dev/null 2>&1; then
    echo "Nix isn't installed yet - run ./run.sh bootstrap first."
    exit 1
  fi
  echo "==> building '$HOST' config (nothing on this machine will change)"
  if [ "$HOST" = "home-linux" ]; then
    nix build "$DIR#homeConfigurations.$HOST.activationPackage" -o /tmp/dotfiles-plan
    # Best-effort: home-manager's own generation-link path can vary by Nix
    # version, so a missing link here just means "nothing to diff against
    # yet", not that the build itself failed.
    if [ -e "$HOME/.local/state/nix/profiles/home-manager" ]; then
      echo "==> difference vs this machine right now:"
      nix store diff-closures "$HOME/.local/state/nix/profiles/home-manager" /tmp/dotfiles-plan
    else
      echo "==> no home-manager generation exists here yet; everything in the config is new."
    fi
    return
  fi
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
  link_dotfiles "$DIR" "$relink"
  if [ "$HOST" = "home-linux" ]; then
    nix run github:nix-community/home-manager/release-26.05#home-manager -- \
      switch --flake ~/.dotfiles#"$HOST"
  else
    sudo darwin-rebuild switch --flake ~/.dotfiles#"$HOST"
  fi
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

# Allow run.test.sh to source this file and call individual functions
# (choose_host, resolve_host, ...) without running the whole CLI.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  no_nix=0
  relink=0
  args=()
  for arg in "$@"; do
    if [ "$arg" = "--no-nix" ]; then
      no_nix=1
    elif [ "$arg" = "--relink" ]; then
      relink=1
    else
      args+=("$arg")
    fi
  done
  set -- ${args[@]+"${args[@]}"}

  case "${1:-bootstrap}" in
    bootstrap) if [ $# -gt 0 ]; then shift; fi; cmd_bootstrap "$@" ;;
    plan)      shift; cmd_plan "$@" ;;
    rebuild)   shift; cmd_rebuild "$@" ;;
    choose)    choose_host ;;
    help|--help|-h) usage ;;
    *)         usage; exit 1 ;;
  esac
fi
