#!/usr/bin/env bash
#
# inspector-sync - keep the globally installed Inspector CLI in step with
# the tip of its default branch, from home-manager activation.
#
# The sibling of modules/fabrica-sync.sh, with the same two rules and for
# the same reason - a machine that has just been switched should never be
# silently running an Inspector older than origin/main, and keeping it
# current is never worth losing an activation over:
#
#   - it never fails a switch. Every failure path - no network, no
#     credentials, a branch that moved, go itself erroring - warns on
#     stderr and exits 0, leaving whatever is installed in place.
#   - it only reinstalls when the installed revision differs from the
#     remote one, so the cost of a normal switch is one `git ls-remote`
#     plus one local `go version -m` read, and nothing else.
#
# What is installed is read straight out of the binary: `go install
# <pkg>@<commit>` records the module version it resolved the commit to in
# the binary's own build info, and `go version -m` prints it back. For a
# commit with no semver tag on it - which is every commit in inspector
# today, since the repository has no tags at all - that version is a
# pseudo-version whose last field is the first 12 characters of the
# commit, e.g. v0.0.0-20261020120900-4f297d8be50e, so comparing it against
# a 40-character `ls-remote` sha is a prefix comparison. No state file is
# needed for that, unlike Fabrica's npm install, which records the commit
# nowhere at all; see installed_version/last_install below for the one
# case that does fall back to a recorded value.
#
# Installing the right Inspector is only half of it: the one a shell finds
# has to be that same binary. So whatever this run decides to do - install,
# skip, or give up - it ends by calling guard_managed_binary (see
# modules/managed-bin-guard.sh), which moves aside any other Inspector in a
# directory that could shadow $gobin and says so loudly when one it cannot
# touch wins anyway. That runs on every path through this script, including
# the ones that install nothing: an unwatched machine that had nothing to
# install today is exactly where a stale ~/.local/bin/inspector survives.
#
# Run as: inspector-sync <gobin-directory> [guard-library]
# The directory is passed in rather than hardcoded so modules/inspector.nix
# holds the single definition of where the managed binary lives (it also
# puts that directory on PATH). The guard library is passed too because Nix
# gives each of these files its own store path, so the script cannot find
# its sibling by looking next to itself; the default is for running this by
# hand out of a checkout. That module runs this with go, git, awk, bash,
# zsh and coreutils put on PATH from the Nix store, so activation never
# depends on what a login shell happens to have active; run by hand, it
# uses whatever those names resolve to.
set -euo pipefail

gobin=${1:?usage: inspector-sync <gobin-directory> [guard-library]}
guard_lib=${2:-$(dirname "$0")/managed-bin-guard.sh}

repo_url=https://github.com/inactdev/inspector.git
pkg_path=github.com/inactdev/inspector/cmd/inspector
branch=main

bin=$gobin/inspector
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/inspector-sync
state_file=$state_dir/last-install

say() { printf 'inspector-sync: %s\n' "$*"; }
warn() { printf 'inspector-sync: %s\n' "$*" >&2; }

# A full commit as `git ls-remote` reports it. The upper bound covers a
# SHA-256 repository, so a future conversion reads as a commit rather than
# as garbage.
is_full_commit() { [[ $1 =~ ^[0-9a-f]{40}$ || $1 =~ ^[0-9a-f]{64}$ ]]; }

# The module version recorded in the installed binary's build info, or
# nothing when there is no binary, it is not a Go binary, or it was built
# outside module mode. `go version -m` prints one tab-indented line per
# record; the `mod` line is the main module's, holding path, version and
# hash in that order.
#
# The read is in its own step rather than piped straight into awk because
# a file that is not a Go binary makes go exit non-zero, and under
# `pipefail` that would take the whole script down with it instead of
# reading as "nothing usable is installed".
installed_version() {
  [ -x "$bin" ] || return 0
  local info
  info=$(go version -m "$bin" 2>/dev/null) || return 0
  printf '%s\n' "$info" | awk '$1 == "mod" { print $3; exit }'
}

# The commit out of a module version, when it is a pseudo-version: all
# three pseudo-version forms end in -<12 hex characters>, and only
# pseudo-versions do. Exactly 12, deliberately: a looser hex test would
# accept a pseudo-version's own 14-digit timestamp field, which is also
# all hex characters.
revision_of() {
  local revision=${1##*-}
  if [[ $revision =~ ^[0-9a-f]{12}$ ]]; then
    printf '%s' "$revision"
  fi
}

# The version/commit pair this script recorded the last time it installed,
# as "<module version> <commit>". Consulted only when the installed
# version carries no commit of its own - which today means only one thing:
# a tag was pushed onto the commit this step installed, so `go install
# <pkg>@<that commit>` resolved to the tag (e.g. v1.2.0) instead of to a
# pseudo-version. Without the record such a version would never match any
# sha and the step would reinstall on every single switch; with it, the
# reinstall happens once. The version is recorded alongside the commit so
# the record only vouches for the exact binary it was written for: an
# Inspector someone later installed by hand reads as a different version
# string, falls through, and gets brought back to the remote tip.
last_install() {
  [ -f "$state_file" ] || return 0
  cat "$state_file" 2>/dev/null
}

# Everything the install decision needs, as one function rather than as the
# top level of the script: every "nothing more to do here" below is a
# `return 0`, so the shadowing guard at the tail still runs after it. An
# `exit 0` would skip the guard on exactly the quiet paths - already
# current, no network - where a shadowing copy goes unnoticed longest.
sync_to_remote_tip() {
  local ls_remote remote_commit current_version current_revision installed

  # Read the remote tip. GIT_TERMINAL_PROMPT=0 so a host without
  # credentials for the repository fails instead of blocking a
  # non-interactive switch on a username prompt, and the low-speed
  # settings so a half-open connection gives up in seconds rather than
  # hanging the activation.
  if ! ls_remote=$(
    GIT_TERMINAL_PROMPT=0 git \
      -c http.lowSpeedLimit=1000 \
      -c http.lowSpeedTime=15 \
      ls-remote "$repo_url" "refs/heads/$branch" 2>&1
  ); then
    warn "could not read $branch from $repo_url, so the installed copy is left as it is."
    warn "git said: $ls_remote"
    return 0
  fi

  remote_commit=${ls_remote%%[[:space:]]*}
  if ! is_full_commit "$remote_commit"; then
    warn "no commit for $branch at $repo_url, so the installed copy is left as it is."
    return 0
  fi

  current_version=$(installed_version)
  current_revision=$(revision_of "$current_version")

  if [ -n "$current_revision" ]; then
    if [ "$current_revision" = "${remote_commit:0:12}" ]; then
      say "already on $branch ($current_version), nothing to install."
      return 0
    fi
  elif [ -n "$current_version" ] && [ "$(last_install)" = "$current_version $remote_commit" ]; then
    say "already on $branch ($current_version at $remote_commit), nothing to install."
    return 0
  fi

  say "installing $pkg_path@$remote_commit into $gobin (have: ${current_version:-nothing installed})"

  # GOBIN pins where the binary lands, so it matches the PATH entry
  # modules/inspector.nix adds, whatever GOPATH or GOBIN the machine's own
  # `go env` happens to say. GOPRIVATE keeps the fetch off the public proxy
  # and checksum database and on the repository itself, which is what `go
  # help private` prescribes for a module that is not publicly available -
  # so this keeps working if inspector is ever private, and costs nothing
  # while it is public, since the commit being installed was just read from
  # that same repository over the same transport. Only inactdev's own
  # modules are matched, so any dependency still goes through the proxy and
  # is still checksum-verified. GIT_TERMINAL_PROMPT=0 for the same reason as
  # above: go fetches with git, and a credential prompt must never be able
  # to block a switch.
  if ! GOBIN=$gobin \
    GOPRIVATE='github.com/inactdev/*' \
    GIT_TERMINAL_PROMPT=0 \
    go install "$pkg_path@$remote_commit"; then
    warn "go install $pkg_path@$remote_commit failed, so Inspector was not updated."
    warn "re-run the switch once the cause is cleared."
    return 0
  fi

  installed=$(installed_version)
  if ! (mkdir -p "$state_dir" && printf '%s %s\n' "$installed" "$remote_commit" >"$state_file"); then
    warn "installed $remote_commit but could not record it in $state_file;"
    warn "harmless - the record is only consulted for a tagged release (see the comments)."
  fi
  return 0
}

sync_to_remote_tip

# The guard is sourced this late, and its absence is survivable, for the
# same reason every other failure here is: a missing library is worth a
# warning, not a lost activation.
if [ -r "$guard_lib" ]; then
  # shellcheck source=./managed-bin-guard.sh
  . "$guard_lib"
  guard_managed_binary inspector "$bin"
else
  warn "no shadowing guard at $guard_lib, so nothing checked which inspector a login shell finds."
fi
