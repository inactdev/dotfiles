#!/usr/bin/env bash
#
# fabrica-sync - keep the globally installed Fabrica CLI in step with the
# tip of its default branch, from home-manager activation.
#
# `fabrica update` stays the day-to-day command; this exists only so a
# machine that has just been switched is never silently running a Fabrica
# older than origin/master. Two rules it never breaks:
#
#   - it never fails a switch. Every failure path - no network, no
#     credentials, a branch that moved, npm itself erroring - warns on
#     stderr and exits 0, leaving whatever is installed in place.
#   - it only reinstalls when the installed commit differs from the remote
#     one, so the cost of a normal switch is one `git ls-remote` and
#     nothing else.
#
# Installing the right Fabrica is only half of it: the one a shell finds
# has to be that same install. So whatever this run decides to do -
# install, skip, or give up - it ends by calling guard_managed_binary (see
# modules/managed-bin-guard.sh), which moves aside any other fabrica in a
# directory that could shadow <npm-prefix>/bin and says so loudly when one
# it cannot touch wins anyway. That runs on every path through this script,
# including the ones that install nothing: an unwatched machine that had
# nothing to install today is exactly where a stale ~/.local/bin/fabrica
# survives.
#
# Run as: fabrica-sync <npm-prefix> [guard-library]
# The prefix is passed in rather than hardcoded so modules/fabrica.nix
# holds the single definition of where the managed global install lives
# (it also puts <npm-prefix>/bin on PATH). The guard library is passed too
# because Nix gives each of these files its own store path, so the script
# cannot find its sibling by looking next to itself; the default is for
# running this by hand out of a checkout. That module runs this with git,
# node/npm, bash, zsh and coreutils put on PATH from the Nix store, so
# activation never depends on whatever node a login shell happens to have
# active; run by hand, it uses whatever those names resolve to.
set -euo pipefail

prefix=${1:?usage: fabrica-sync <npm-prefix> [guard-library]}
guard_lib=${2:-$(dirname "$0")/managed-bin-guard.sh}

repo_url=https://github.com/inactdev/fabrica.git
npm_spec=github:inactdev/fabrica
branch=master

pkg_dir=$prefix/lib/node_modules/fabrica
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/fabrica-sync
state_file=$state_dir/installed-commit

say() { printf 'fabrica-sync: %s\n' "$*"; }
warn() { printf 'fabrica-sync: %s\n' "$*" >&2; }

is_commit() { [[ $1 =~ ^[0-9a-f]{7,40}$ ]]; }

# True when the two commits name the same thing, allowing either side to
# be an abbreviated sha - build info often carries a short one.
same_commit() {
  case $2 in "$1"*) return 0 ;; esac
  case $1 in "$2"*) return 0 ;; esac
  return 1
}

# Pull a commit out of a JSON build-info file: first a key that names one
# (commit/sha/rev...), then any commit-shaped string nested below. Parsing
# with node rather than grep/jq keeps this exact and dependency-free -
# node is already here to run npm.
commit_from_json() {
  node -e '
    const fs = require("fs");
    const looksLikeCommit = (v) =>
      typeof v === "string" && /^[0-9a-f]{7,40}$/.test(v);
    const pick = (o) => {
      if (!o || typeof o !== "object") return null;
      for (const [k, v] of Object.entries(o))
        if (/commit|sha|rev/i.test(k) && looksLikeCommit(v)) return v;
      for (const v of Object.values(o)) {
        const hit = pick(v);
        if (hit) return hit;
      }
      return null;
    };
    let parsed;
    try {
      parsed = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    } catch {
      process.exit(1);
    }
    const commit = pick(parsed);
    if (!commit) process.exit(1);
    process.stdout.write(commit);
  ' "$1" 2>/dev/null
}

# What commit is the installed copy built from? Prefer Fabrica's own build
# info, which stays right even when the install came from `fabrica update`
# rather than from here. npm itself is no help: a global install from a git
# spec records the resolved commit nowhere - not in the installed
# package.json, not in a lockfile, not in `npm ls --json --long` - so the
# second source is the commit this script recorded when it last installed.
# When neither answers, the caller treats the installed copy as unknown and
# reinstalls once, which establishes the record for every later switch.
installed_commit() {
  [ -d "$pkg_dir" ] || return 0

  local candidate found
  for candidate in "$pkg_dir/build-info.json" "$pkg_dir/dist/build-info.json"; do
    if [ -f "$candidate" ]; then
      found=$(commit_from_json "$candidate") || found=
      if [ -n "$found" ] && is_commit "$found"; then
        printf '%s' "$found"
        return 0
      fi
    fi
  done

  if [ -f "$state_file" ]; then
    found=$(tr -d '[:space:]' <"$state_file") || found=
    if [ -n "$found" ] && is_commit "$found"; then
      printf '%s' "$found"
    fi
  fi
}

# Everything the install decision needs, as one function rather than as the
# top level of the script: every "nothing more to do here" below is a
# `return 0`, so the shadowing guard at the tail still runs after it. An
# `exit 0` would skip the guard on exactly the quiet paths - already
# current, no network - where a shadowing copy goes unnoticed longest.
sync_to_remote_tip() {
  local ls_remote remote_commit current_commit

  # Read the remote tip. GIT_TERMINAL_PROMPT=0 so a host without
  # credentials for a private repo fails instead of blocking a
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
  if ! is_commit "$remote_commit"; then
    warn "no commit for $branch at $repo_url, so the installed copy is left as it is."
    return 0
  fi

  current_commit=$(installed_commit)
  if [ -n "$current_commit" ] && same_commit "$current_commit" "$remote_commit"; then
    say "already on $branch ($remote_commit), nothing to install."
    return 0
  fi

  say "installing $npm_spec into $prefix (have: ${current_commit:-none recorded}, $branch: $remote_commit)"
  if ! npm install -g --prefix "$prefix" "$npm_spec"; then
    warn "npm install -g $npm_spec failed, so Fabrica was not updated to $remote_commit."
    warn "re-run the switch, or \`fabrica update\`, once the cause is cleared."
    return 0
  fi

  if ! (mkdir -p "$state_dir" && printf '%s\n' "$remote_commit" >"$state_file"); then
    warn "installed $remote_commit but could not record it in $state_file;"
    warn "the next switch will reinstall once more, which is wasteful but harmless."
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
  guard_managed_binary fabrica "$prefix/bin/fabrica"
else
  warn "no shadowing guard at $guard_lib, so nothing checked which fabrica a login shell finds."
fi
