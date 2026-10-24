#!/usr/bin/env bash
#
# inkwell-sync - keep the installed Inkwell backend binary in step with the
# tip of its default branch, and keep its launchd agent running on it, from
# home-manager activation.
#
# The sibling of modules/inspector-sync.sh and modules/fabrica-sync.sh, with
# the same two rules and for the same reason - a machine that has just been
# switched should never be silently running a backend older than
# origin/main, and keeping it current is never worth losing an activation
# over:
#
#   - it never fails a switch. Every failure path - no network, no
#     credentials, a branch that moved, go itself erroring, launchctl
#     refusing - warns on stderr and exits 0, leaving whatever is installed
#     and running exactly as it was.
#   - it only rebuilds when the installed revision differs from the remote
#     one, so the cost of a normal switch is one `git ls-remote` plus one
#     local `go version -m` read, and nothing else.
#
# Why this builds instead of `go install`-ing, which is the one way it is
# NOT its siblings' shape: inkwell's backend declares `module
# inkwell/backend`, a module path with no dot in its first element, and Go
# refuses such a path for a remote install outright -
#
#   go: inkwell/backend@<commit>: malformed module path "inkwell/backend":
#   missing dot in first path element
#
# - so `go install inkwell/backend/...@<commit>` cannot work at all, however
# the repository is published. A throwaway shallow clone plus `go build` is
# what is left, and it gives up nothing: the module is standard-library
# only, so the build fetches no dependencies.
#
# What is installed is still read straight out of the binary rather than out
# of a state file. `go build` stamps the VCS revision of the checkout it
# built from into the binary's own build info (`-buildvcs`, on by default
# and asked for explicitly below), and `go version -m` prints it back as a
# full 40-character commit - so the comparison against `git ls-remote` is
# exact, needs no bookkeeping of its own, and stays truthful even if the
# binary is later replaced by hand. `vcs.modified` is read alongside it: a
# binary built from somebody's dirty worktree reports the commit it sat on,
# which is not the same thing as being that commit, so it is rebuilt.
#
# Installing the right backend is only half of it: the launchd agent has to
# be running that binary. home-manager (re)loads an agent only when the
# agent's *plist text* changes, and this plist deliberately never changes -
# it names a fixed path, ~/go/bin/inkwell-backend, so that it is stable
# across generations (see modules/inkwell.nix). A rebuild therefore leaves
# the old process running the old binary unless something restarts it, which
# is what ensure_agent does, on every path through this script including the
# ones that build nothing: a machine whose agent was booted out, or whose
# binary arrived before the agent existed, is exactly the machine nobody is
# watching.
#
# Run as: inkwell-sync <gobin-directory> [launchd-label]
# The directory is passed in rather than hardcoded so modules/inkwell.nix
# holds the single definition of where the managed binary lives (it also
# puts that directory on PATH, via modules/core.nix). The label likewise
# comes from the module, which reads it off the launchd agent it defines, so
# the two cannot drift apart; with no label, the binary is brought up to
# date and nothing is started.
#
# That module runs this with go, git, awk and coreutils put on PATH from the
# Nix store, so activation never depends on what a login shell happens to
# have active; run by hand, it uses whatever those names resolve to.
set -euo pipefail

gobin=${1:?usage: inkwell-sync <gobin-directory> [launchd-label]}
label=${2:-}

repo_url=https://github.com/inactdev/inkwell.git
branch=main
# The backend is its own Go module inside the repository, not the repository
# root.
module_subdir=backend
bin_name=inkwell-backend
bin=$gobin/$bin_name

# Set when a build actually replaced the binary, read by ensure_agent to
# decide between restarting the agent and merely making sure it is up.
rebuilt=0

# The throwaway clone, removed on every exit path. Assigned before use so
# the trap can run at any point.
tmp=

say() { printf 'inkwell-sync: %s\n' "$*"; }
warn() { printf 'inkwell-sync: %s\n' "$*" >&2; }

# `if`, not `[ -n "$tmp" ] && rm -rf "$tmp"`: this is the last command the
# script runs, and a bare `&&` test that evaluates false there would become
# the script's own exit status (see AGENTS.md).
cleanup() {
  if [ -n "$tmp" ]; then
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT

# A full commit as `git ls-remote` reports it. The upper bound covers a
# SHA-256 repository, so a future conversion reads as a commit rather than
# as garbage.
is_full_commit() { [[ $1 =~ ^[0-9a-f]{40}$ || $1 =~ ^[0-9a-f]{64}$ ]]; }

# "<revision> <modified>" out of the installed binary's build info, or
# nothing when there is no binary, it is not a Go binary, or it carries no
# VCS stamp (a `-buildvcs=false` build, or one made outside a checkout).
# `go version -m` prints one tab-indented record per line; the VCS stamp
# arrives as `build vcs.revision=<sha>` and `build vcs.modified=<bool>`.
#
# The read is in its own step rather than piped straight into awk because a
# file that is not a Go binary makes go exit non-zero, and under `pipefail`
# that would take the whole script down with it instead of reading as
# "nothing usable is installed".
installed_stamp() {
  [ -x "$bin" ] || return 0
  local info
  info=$(go version -m "$bin" 2>/dev/null) || return 0
  printf '%s\n' "$info" | awk '
    $1 == "build" && index($2, "vcs.revision=") == 1 {
      revision = substr($2, length("vcs.revision=") + 1)
    }
    $1 == "build" && index($2, "vcs.modified=") == 1 {
      modified = substr($2, length("vcs.modified=") + 1)
    }
    END {
      if (revision != "") {
        printf "%s %s\n", revision, (modified == "" ? "unknown" : modified)
      }
    }
  '
}

# Everything the build decision needs, as one function rather than as the
# top level of the script: every "nothing more to do here" below is a
# `return 0`, so ensure_agent at the tail still runs after it. An `exit 0`
# would skip it on exactly the quiet paths - already current, no network -
# where a stopped agent goes unnoticed longest.
build_to_remote_tip() {
  local ls_remote remote_commit stamp current_revision current_modified
  local src built_commit new_bin new_stamp

  # Read the remote tip. GIT_TERMINAL_PROMPT=0 so a host without
  # credentials for the repository fails instead of blocking a
  # non-interactive switch on a username prompt, and the low-speed settings
  # so a half-open connection gives up in seconds rather than hanging the
  # activation.
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

  stamp=$(installed_stamp)
  current_revision=${stamp%% *}
  current_modified=${stamp##* }

  if [ "$current_revision" = "$remote_commit" ] && [ "$current_modified" != "true" ]; then
    say "already on $branch ($remote_commit), nothing to build."
    return 0
  fi

  say "building $module_subdir at $branch ($remote_commit) into $bin (have: ${current_revision:-nothing installed})"

  if ! tmp=$(mktemp -d "${TMPDIR:-/tmp}/inkwell-sync.XXXXXX"); then
    tmp=
    warn "could not make a scratch directory to build in, so the installed copy is left as it is."
    return 0
  fi
  src=$tmp/src

  # A fresh shallow clone of the branch rather than a managed long-lived
  # checkout: there is no work to save (the Go build cache lives elsewhere
  # and is reused either way), and a checkout nobody edits cannot drift,
  # go stale, or stamp the binary as built from a modified tree.
  #
  # The branch is cloned and then asked what its HEAD is, rather than the
  # commit from ls-remote being fetched directly, so this needs nothing of
  # the server beyond an ordinary shallow clone. If the branch moved in
  # between, the binary is stamped with what was actually built and the next
  # switch brings it forward - never with a commit that was not built.
  if ! GIT_TERMINAL_PROMPT=0 git \
    -c advice.detachedHead=false \
    -c http.lowSpeedLimit=1000 \
    -c http.lowSpeedTime=15 \
    clone --quiet --depth 1 --branch "$branch" "$repo_url" "$src"; then
    warn "could not clone $branch from $repo_url, so the backend was not updated."
    warn "re-run the switch once the cause is cleared."
    return 0
  fi

  built_commit=$(git -C "$src" rev-parse HEAD 2>/dev/null) || built_commit=
  if [ -n "$built_commit" ] && [ "$built_commit" != "$remote_commit" ]; then
    say "$branch moved while this ran; building $built_commit, the tip as cloned."
  fi

  if ! mkdir -p "$gobin"; then
    warn "could not create $gobin, so the backend was not updated."
    return 0
  fi

  # Built next to the real path and moved into place, never written over it:
  # replacing the file a running agent is executing in place is what gives
  # "text file busy", and a rename is atomic, so no window exists in which
  # the agent could start a half-written binary. The temporary name is in
  # $gobin for that rename to stay on one filesystem.
  new_bin=$gobin/.$bin_name.new

  # CGO_ENABLED=0 because the backend is pure Go and this step must not need
  # a C compiler: an activation step's PATH is only the store packages its
  # module lists (see modules/inspector-sync.sh, where leaving cgo on
  # stopped the build with `cgo: C compiler gcc not found` on a host that
  # had one installed).
  #
  # -buildvcs=true, not the default `auto`: the stamp is this script's only
  # record of what is installed, so a build that cannot read the checkout's
  # revision must fail loudly here rather than quietly produce a binary
  # whose provenance is unreadable - which would make every future switch
  # rebuild it, forever, without ever saying why.
  #
  # -trimpath keeps the throwaway clone's path out of the binary, so two
  # builds of the same commit are the same binary.
  if ! (
    cd "$src/$module_subdir" \
      && CGO_ENABLED=0 GIT_TERMINAL_PROMPT=0 go build -buildvcs=true -trimpath -o "$new_bin" .
  ); then
    warn "go build of $module_subdir at ${built_commit:-$remote_commit} failed, so the backend was not updated."
    warn "re-run the switch once the cause is cleared."
    rm -f "$new_bin"
    return 0
  fi

  if ! mv -f "$new_bin" "$bin"; then
    warn "built the backend but could not move it to $bin, so the old copy is still installed."
    rm -f "$new_bin"
    return 0
  fi

  rebuilt=1
  new_stamp=$(installed_stamp)
  say "installed $bin (${new_stamp:-no VCS stamp})"
  return 0
}

# The launchd agent, on every path through this script. Resolved against
# /bin as well as PATH because launchctl is a macOS fixture that an
# activation's PATH is not guaranteed to carry, and absent entirely on
# Linux - where this module is never composed in, and where the only
# honest thing to do is say so and stop.
ensure_agent() {
  local domain plist launchctl candidate resolved print_out
  launchctl=

  if [ -z "$label" ]; then
    say "no launchd label passed, so no agent was started."
    return 0
  fi

  for candidate in launchctl /bin/launchctl; do
    if resolved=$(command -v "$candidate" 2>/dev/null); then
      launchctl=$resolved
      break
    fi
  done
  if [ -z "$launchctl" ]; then
    warn "no launchctl here, so nothing checked whether $label is running."
    return 0
  fi

  if [ ! -x "$bin" ]; then
    warn "no backend installed at $bin, so $label was not started - it would only"
    warn "fail to spawn and be retried. Re-run the switch once the build above works."
    return 0
  fi

  domain="gui/$(id -u)"
  plist="$HOME/Library/LaunchAgents/$label.plist"

  if ! print_out=$("$launchctl" print "$domain/$label" 2>&1); then
    # Not loaded. On an ordinary switch home-manager has already written and
    # bootstrapped the plist by the time this runs (this step is ordered
    # after its setupLaunchAgents, see modules/inkwell.nix), so reaching
    # here means either the very first switch on a machine where that failed
    # for the usual first-run reason - the binary did not exist yet - or an
    # agent somebody booted out by hand. Both are fixed by bootstrapping it
    # now, with the binary in place.
    if [ ! -f "$plist" ]; then
      warn "no agent plist at $plist, so the backend is installed but nothing runs it."
      warn "that file is written by the same switch as this step; re-run the switch."
      return 0
    fi
    if "$launchctl" bootstrap "$domain" "$plist"; then
      say "loaded $label, so the backend is running and starts at every login."
    else
      warn "could not load $label from $plist; it starts at the next login."
    fi
    return 0
  fi

  if [ "$rebuilt" = 1 ]; then
    if "$launchctl" kickstart -k "$domain/$label"; then
      say "restarted $label onto the newly built backend."
    else
      warn "could not restart $label, so it is still running the previous backend"
      warn "until the next login. Restart it by hand with:"
      warn "  launchctl kickstart -k $domain/$label"
    fi
    return 0
  fi

  # Loaded and unchanged: the only thing left to check is that it is
  # actually running. `launchctl print` reports a pid for a running job and
  # none for one that is merely loaded, and kickstart is asked for only in
  # the second case - a job that is already up needs nothing, and not asking
  # keeps this quiet on the switches where everything is fine.
  if [[ $print_out =~ (^|[^[:alnum:]])pid[[:space:]]*=[[:space:]]*[0-9]+ ]]; then
    say "$label is loaded and running."
    return 0
  fi

  if "$launchctl" kickstart "$domain/$label"; then
    say "started $label, which was loaded but not running."
  else
    warn "$label is loaded but not running, and could not be started; it starts at"
    warn "the next login. $HOME/Library/Logs/$bin_name.log has its own reason."
  fi
  return 0
}

build_to_remote_tip
ensure_agent
