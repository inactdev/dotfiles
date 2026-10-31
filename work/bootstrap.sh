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
# check_docker/macos_write_default/configure_macos_defaults is plain shell
# with nothing macOS-specific about it and is reused as-is by the codespace
# path rather than copied - see AGENTS.md. check_docker is on that list for
# the same reason as install_ghostty_symlink: it looks for a macOS .app
# installed by the company's Self-Service app, and a container has neither.
#
# install_node_version/install_fabrica/write_fabrica_launcher/
# install_fabrica_home/check_fabrica_token/install_inspector are the
# exception to that rule: they are plain shell too (fnm and npm run on a
# container just as well), and the codespace path still does not call them.
# A container is a place work gets done, not a place it gets dispatched
# from or checked, which is the same reason flake.nix leaves
# modules/fabrica.nix and modules/inspector.nix out of both codespace
# hosts. Adding them later is a few lines in that script's own main().
set -euo pipefail

# Collected here so the final summary can tell the captain what still
# needs a human, instead of silently doing nothing.
#
# Everything from FABRICA_PENDING down is read only by this file's own
# print_summary. work/codespace-bootstrap.sh defines its own print_summary
# that shadows this one and installs none of these tools nor looks for
# Docker, so sourcing this file leaves it with a handful of counters it
# ignores - deliberately, rather than threading them through the shared
# print_git_gh_pending, which would put work-Mac-only state into the
# codespace summary.
#
# The last two are the only items in the whole bootstrap that no script is
# allowed to finish: `claude setup-token` is a browser OAuth flow, and
# Docker Desktop comes from the company's Self-Service app (see
# check_docker). Both are reported, never attempted.
GIT_IDENTITY_PENDING=0
MACOS_DEFAULTS_PENDING=0
GH_LOGIN_PENDING=0
FABRICA_PENDING=0
INSPECTOR_PENDING=0
NODE_PIN_PENDING=0
FABRICA_HOME_PENDING=0
CLAUDE_TOKEN_PENDING=0
DOCKER_PENDING=0

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

# The one Node version Fabrica is supported on, and the only one it is ever
# run with on this host: install_node_version downloads exactly this through
# fnm, and write_fabrica_launcher names it in the launcher it generates, so
# `fabrica` gets it no matter which directory (and therefore which
# .node-version) the shell is sitting in. Bumping Fabrica's supported Node
# is this one line plus a re-run of the bootstrap.
FABRICA_NODE_VERSION=24.18.0

# Fabrica's own state directory. Created by install_fabrica_home, and the
# only thing in this script that holds a secret (brain.env), which is why
# its mode is asserted rather than left to whatever umask is in effect.
FABRICA_HOME="$HOME/.fabrica"

# Where Docker Desktop lands when it is installed from the company's
# Self-Service app. Not installed by this script (see check_docker and
# work/Brewfile) - only looked for. Overridable solely so
# work/bootstrap.test.sh can point the check at a scratch directory and
# exercise both the present and the missing case on any machine; nothing
# in normal use sets it.
DOCKER_APP="${DOCKER_APP:-/Applications/Docker.app}"

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

# Downloads the one Node version Fabrica runs on. `fnm` comes from
# work/Brewfile, so this runs after install_packages.
#
# Gated on a probe rather than run blind, because `fnm install <version>`
# of an already-installed version exits non-zero ("version already
# installed") and this script has to stay re-runnable. The probe is
# `fnm exec --using=<version> node --version` - fnm's own documented way to
# run one command on one version - rather than a grep of `fnm list`, so
# what it proves is exactly the command line the generated launcher uses,
# not merely that some directory exists under fnm's base dir.
#
# Like every other install step here, a failure warns and lands in the
# closing summary instead of aborting: a work Mac with every config linked
# and every package installed is worth having even if this one download
# didn't make it.
install_node_version() {
  echo "==> installing Node $FABRICA_NODE_VERSION (fnm)"
  if ! command -v fnm >/dev/null 2>&1; then
    NODE_PIN_PENDING=1
    echo "    WARN: fnm is not on PATH, so Node $FABRICA_NODE_VERSION was not installed" >&2
    return 0
  fi
  if fnm exec --using="$FABRICA_NODE_VERSION" node --version >/dev/null 2>&1; then
    echo "    Node $FABRICA_NODE_VERSION already installed"
    return 0
  fi
  if ! fnm install "$FABRICA_NODE_VERSION"; then
    NODE_PIN_PENDING=1
    echo "    WARN: fnm install $FABRICA_NODE_VERSION failed, so Fabrica cannot be" >&2
    echo "          pinned to it" >&2
    return 0
  fi
  return 0
}

# Resolves $1 through however many symlinks it takes to name a real file,
# printing an absolute path with no symlinked or relative components left
# in it. `readlink -f` (or `realpath`) would be one call and is what a Linux
# script would reach for, but neither is dependable on a stock macOS: there
# is no `realpath` at all, and BSD `readlink` only grew `-f` recently
# enough that an older OS build would silently print an empty line - which,
# here, would produce a launcher that execs nothing.
resolve_link() {
  local path="$1" target dir hops=0
  while [ -L "$path" ] && [ "$hops" -lt 32 ]; do
    target="$(readlink "$path")"
    case "$target" in
      /*) path="$target" ;;
      *) path="$(dirname "$path")/$target" ;;
    esac
    hops=$((hops + 1))
  done
  if [ ! -f "$path" ]; then
    return 1
  fi
  dir="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}

# Replaces npm's own `fabrica` shim with a launcher that names the Node
# version to run it on, so a repository's .node-version can never decide
# which Node Fabrica gets. $1 is the CLI script npm's shim pointed at,
# resolved by install_fabrica before this overwrote it - npm stays the one
# authority on where its own package put its entry point, rather than this
# script guessing at lib/node_modules/fabrica/package.json's bin field.
#
# fnm's absolute path is baked in (with a PATH lookup as the fallback)
# because this launcher must also work where no interactive shell has run:
# work/zshrc's `fnm env` line is what puts Homebrew's bin dir on PATH for a
# login shell, and anything launched from a GUI agent or a cron-style job
# starts without it.
#
# Written to a temporary file and moved into place so the switch is atomic.
# What sits at that path when this runs is npm's own freshly linked shim,
# which works (just unpinned) - so a `fabrica` half-overwritten in place
# would be strictly worse than either end state, and `mv` never leaves one.
write_fabrica_launcher() {
  local entry="$1"
  local bin="$MANAGED_PREFIX/bin/fabrica"
  local fnm_bin tmp
  fnm_bin="$(command -v fnm 2>/dev/null)" || fnm_bin=""

  if [ -z "$fnm_bin" ] || [ -z "$entry" ]; then
    NODE_PIN_PENDING=1
    echo "    WARN: could not pin fabrica to Node $FABRICA_NODE_VERSION" >&2
    echo "          (fabrica will run on whatever node the shell has)" >&2
    return 0
  fi

  tmp="$bin.bootstrap-tmp.$$"
  cat >"$tmp" <<EOF
#!/bin/sh
# Generated by work/bootstrap.sh - do not edit. Every bootstrap and every
# ./run.sh rebuild on this host rewrites it from scratch.
#
# Fabrica runs on exactly Node $FABRICA_NODE_VERSION, from whatever directory it is
# invoked in: 'fnm exec --using=<version>' picks that version for this one
# command without touching the shell, so a repository's own .node-version
# (which fnm's cd hook in work/zshrc does act on) cannot change which Node
# Fabrica itself gets. It also puts that version first on PATH for
# everything Fabrica shells out to.
FNM="$fnm_bin"
if [ ! -x "\$FNM" ]; then
  FNM="\$(command -v fnm)" || {
    echo "fabrica: fnm is not installed, so Node $FABRICA_NODE_VERSION cannot be selected." >&2
    echo "         Re-run the dotfiles bootstrap: ./run.sh rebuild" >&2
    exit 127
  }
fi
exec "\$FNM" exec --using=$FABRICA_NODE_VERSION node "$entry" "\$@"
EOF
  chmod 755 "$tmp"
  if ! mv -f "$tmp" "$bin"; then
    rm -f "$tmp"
    NODE_PIN_PENDING=1
    echo "    WARN: could not write $bin, so fabrica is not pinned to Node $FABRICA_NODE_VERSION" >&2
    return 0
  fi
  echo "    fabrica pinned to Node $FABRICA_NODE_VERSION"
  return 0
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
  local tmpdir clone_dir candidate entry
  local previous=
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

  # The launcher this script generates (see write_fabrica_launcher) lives at
  # the exact path npm wants to put its own shim, and npm refuses to link a
  # global bin over a path it doesn't already own: bin-links' check-bin
  # rejects with "EEXIST: file already exists" for a global, top-level
  # install unless what's there is a symlink resolving into the package
  # being installed. Our launcher is a real file, so without this every
  # re-run after the first would fail the install. `npm install -g --force`
  # would buy the same single exemption by switching off every other check
  # npm has, so it isn't used.
  #
  # Moved aside rather than deleted, and moved back if the install fails:
  # before this step existed a failed `npm install -g` simply left the
  # previous copy alone, and that is still the right outcome on a machine
  # that is in the middle of real work. A bootstrap killed between the two
  # moves leaves a `fabrica.pre-bootstrap.*` next to no `fabrica` at all,
  # which the next run puts right.
  if [ -e "$MANAGED_PREFIX/bin/fabrica" ] || [ -L "$MANAGED_PREFIX/bin/fabrica" ]; then
    previous="$MANAGED_PREFIX/bin/fabrica.pre-bootstrap.$$"
    mv -f "$MANAGED_PREFIX/bin/fabrica" "$previous" || previous=
  fi

  # --prefix: see MANAGED_PREFIX above for why Fabrica goes under
  # ~/.local rather than into npm's own global prefix.
  if ! npm install -g --prefix "$MANAGED_PREFIX" "$tarball"; then
    rm -rf "$tmpdir"
    if [ -n "$previous" ]; then
      mv -f "$previous" "$MANAGED_PREFIX/bin/fabrica" || true
    fi
    FABRICA_PENDING=1
    echo "    WARN: npm install -g of the packed tarball failed, so Fabrica was not installed" >&2
    return 0
  fi

  rm -rf "$tmpdir"
  if [ -n "$previous" ]; then
    rm -f "$previous"
  fi

  # Read while npm's shim is still npm's: it names the CLI script, and
  # resolving it is how the launcher learns what to hand to node. An
  # unresolvable shim is reported by write_fabrica_launcher rather than
  # here, which keeps "Fabrica is installed" and "fabrica is pinned to one
  # Node" as the two separate pending items they are.
  entry="$(resolve_link "$MANAGED_PREFIX/bin/fabrica")" || entry=""
  write_fabrica_launcher "$entry"
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

# Appends one TOML block ($2 onwards, a line each) to the file named by $1,
# leaving whatever is already in that file exactly as it is: a file that
# doesn't end in a newline gets one first (otherwise a block header would be
# glued onto a hand-written last line), and a non-empty file gets a blank
# separator line. `$(tail -c 1 ...)` is empty precisely when the last byte
# is a newline, because command substitution strips trailing newlines.
append_toml_block() {
  local file="$1"
  shift
  if [ -s "$file" ]; then
    if [ -n "$(tail -c 1 "$file")" ]; then printf '\n' >>"$file"; fi
    printf '\n' >>"$file"
  fi
  printf '%s\n' "$@" >>"$file"
}

# Fabrica's own state directory, placed so that a fresh work Mac has
# somewhere for its config and its credential to live without anyone having
# to know the layout. Strictly additive, in every direction:
#
#   - 0700 on the directory and 0600 on brain.env, re-asserted every run:
#     brain.env is where CLAUDE_CODE_OAUTH_TOKEN goes, and a credential file
#     left at whatever the umask says is the kind of thing nobody notices
#     until it matters. Modes are permissions, not content, so asserting
#     them is not an overwrite.
#   - brain.env is created only when absent, and never written to. A
#     bootstrap that truncated it would destroy a working machine's token,
#     which is the one thing here a human had to do by hand.
#   - projects.toml grows a [caps] block or a [reader] block only when that
#     block's header is absent. Existing lines - including different values
#     inside a block that is already there - are left alone: this reconciles
#     nothing, it only fills in what was never there. A machine whose caps
#     have been tuned by hand must survive a re-run unchanged.
#
# Every step reports its own failure and returns instead of aborting, like
# the install steps above: a directory or a mode this script can't set
# (someone else owns it, a full disk) is a line in the summary, not a reason
# to abandon a bootstrap that has already linked every config.
install_fabrica_home() {
  local toml="$FABRICA_HOME/projects.toml"
  local env_file="$FABRICA_HOME/brain.env"

  echo "==> preparing $FABRICA_HOME"
  if ! mkdir -p "$FABRICA_HOME" || ! chmod 700 "$FABRICA_HOME"; then
    FABRICA_HOME_PENDING=1
    echo "    WARN: could not create $FABRICA_HOME with mode 700" >&2
    return 0
  fi

  if [ ! -e "$env_file" ]; then
    if : >"$env_file"; then
      echo "    created an empty brain.env"
    else
      FABRICA_HOME_PENDING=1
      echo "    WARN: could not create $env_file" >&2
      return 0
    fi
  fi
  # Not fatal, and deliberately not an early return: a brain.env left at the
  # wrong mode is worth reporting, but projects.toml can still be placed.
  if ! chmod 600 "$env_file"; then
    FABRICA_HOME_PENDING=1
    echo "    WARN: could not set mode 600 on $env_file" >&2
  fi

  if [ ! -e "$toml" ] && ! : >"$toml"; then
    FABRICA_HOME_PENDING=1
    echo "    WARN: could not create $toml" >&2
    return 0
  fi
  if ! grep -q '^[[:space:]]*\[caps\]' "$toml"; then
    append_toml_block "$toml" '[caps]' 'perTaskUsd = 20' 'perDayUsd = 200'
    echo "    added the [caps] block to projects.toml"
  fi
  if ! grep -q '^[[:space:]]*\[reader\]' "$toml"; then
    append_toml_block "$toml" '[reader]' 'vendor = "claude-code"' 'model = "sonnet"'
    echo "    added the [reader] block to projects.toml"
  fi
  return 0
}

# The one credential Fabrica cannot work without, and the one step in this
# whole bootstrap that a script must not even try: `claude setup-token`
# opens a browser, logs in as a human, and prints a token. So this only
# *looks* for the result, exactly like check_docker, and a miss is a line in
# the closing summary saying what to run and where to put it.
#
# The value is never read, printed, or logged - only the presence of a
# non-empty assignment of the name, with or without a leading `export`.
check_fabrica_token() {
  local env_file="$FABRICA_HOME/brain.env"
  echo "==> checking for Fabrica's Claude Code token"
  if [ -f "$env_file" ] &&
    grep -Eq '^[[:space:]]*(export[[:space:]]+)?CLAUDE_CODE_OAUTH_TOKEN[[:space:]]*=[[:space:]]*[^[:space:]]' "$env_file"; then
    echo "    CLAUDE_CODE_OAUTH_TOKEN already set in brain.env"
    return 0
  fi
  CLAUDE_TOKEN_PENDING=1
  return 0
}

# Docker Desktop is the one tool this host needs that Homebrew must not
# provide: the work Mac gets it from the company's Self-Service app, which
# installs and updates a managed copy. So this only *looks* for it, and a
# miss is a pending item in the closing summary rather than a failure -
# nothing else in the bootstrap depends on Docker, and Self-Service is a
# human, GUI step that no script here can drive.
#
# Both halves are checked because either one alone is a false positive:
# a `docker` on PATH with no Docker.app is usually a stray CLI from a
# former install (or a colima/podman shim), and a Docker.app that has
# never been launched has not yet created its CLI symlinks, so the daemon
# is there but `docker` is not.
check_docker() {
  echo "==> checking for Docker Desktop"
  if command -v docker >/dev/null 2>&1 && [ -d "$DOCKER_APP" ]; then
    echo "    Docker Desktop already installed"
    return
  fi
  DOCKER_PENDING=1
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
    [ "$INSPECTOR_PENDING" = 1 ] || [ "$DOCKER_PENDING" = 1 ] ||
    [ "$NODE_PIN_PENDING" = 1 ] || [ "$FABRICA_HOME_PENDING" = 1 ] ||
    [ "$CLAUDE_TOKEN_PENDING" = 1 ]; then
    echo "Still needs attention:"
    print_git_gh_pending
    # The two human-only items first: on a machine that installed cleanly
    # they are the whole list, and they are the only reason the captain has
    # to read this summary at all.
    if [ "$CLAUDE_TOKEN_PENDING" = 1 ]; then
      echo "  - Claude Code token: run 'claude setup-token', then add the token it"
      echo "      prints to $FABRICA_HOME/brain.env as:"
      echo "      CLAUDE_CODE_OAUTH_TOKEN=<the token>"
    fi
    if [ "$DOCKER_PENDING" = 1 ]; then
      echo "  - Docker Desktop: install it from Self-Service (not a Homebrew cask here)"
    fi
    if [ "$FABRICA_PENDING" = 1 ]; then
      echo "  - Fabrica: not installed; see the warning above, then re-run this bootstrap"
    fi
    if [ "$NODE_PIN_PENDING" = 1 ]; then
      echo "  - Node $FABRICA_NODE_VERSION: fabrica is not pinned to it; see the warning"
      echo "      above, then re-run this bootstrap"
    fi
    if [ "$FABRICA_HOME_PENDING" = 1 ]; then
      echo "  - $FABRICA_HOME: not prepared; see the warning above, then re-run this bootstrap"
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
  #
  # install_node_version before install_fabrica, because the launcher
  # install_fabrica generates names that Node version - writing a launcher
  # for a version that isn't downloaded yet would leave a `fabrica` that
  # fails on its first run instead of one that works.
  install_node_version
  install_fabrica
  install_inspector
  install_fabrica_home
  configure_macos_defaults
  # Last of the real steps: these two install nothing, they only report
  # what a human still has to do, so they belong next to the summary they
  # feed rather than up with the package installs. check_fabrica_token
  # needs install_fabrica_home to have run first - that is what creates the
  # brain.env it looks in.
  check_docker
  check_fabrica_token
  print_summary
}

# Allow work/bootstrap.test.sh to source this file and call individual
# functions without running the whole bootstrap.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
