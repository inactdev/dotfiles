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
# Installing the right Fabrica and finding it are still only two thirds of
# it: the Node it runs on has to be the one version Fabrica is supported
# on, whatever .node-version the directory it was invoked from declares.
# So between the install decision and the guard, pin_fabrica_to_node
# replaces npm's own `fabrica` shim with a launcher naming that version
# through `fnm exec --using` - the same thing work/bootstrap.sh's
# write_fabrica_launcher does for the work Mac, from the same pin
# (./fabrica-node-version at the repository root, which modules/fabrica.nix
# reads and passes in). That also runs on every path, for a reason of its
# own: `fabrica update` is the day-to-day way to move Fabrica forward and
# is an `npm install -g`, which puts npm's unpinned shim back.
#
# Run as: fabrica-sync <npm-prefix> <node-version> [guard-library]
# The prefix is passed in rather than hardcoded so modules/fabrica.nix
# holds the single definition of where the managed global install lives
# (it also puts <npm-prefix>/bin on PATH). The Node version is passed in
# so that module can read it from the one file the work host reads too,
# and so the value lands on the activation command line, where a bump
# changes the generation rather than only being noticed at run time. The
# guard library is passed too because Nix gives each of these files its
# own store path, so the script cannot find its sibling by looking next to
# itself; the default is for running this by hand out of a checkout. That
# module runs this with git, node/npm, fnm, bash, zsh and coreutils put on
# PATH from the Nix store, so activation never depends on whatever node a
# login shell happens to have active; run by hand, it uses whatever those
# names resolve to.
set -euo pipefail

usage='usage: fabrica-sync <npm-prefix> <node-version> [guard-library]'
prefix=${1:?"$usage"}
node_version=${2:?"$usage"}
guard_lib=${3:-$(dirname "$0")/managed-bin-guard.sh}

repo_url=https://github.com/inactdev/fabrica.git
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
# rather than from here. npm itself is no help: an install that started
# from a git spec records the resolved commit nowhere - not in the
# installed package.json, not in a lockfile, not in `npm ls --json --long`
# - so the second source is the commit this script recorded when it last
# installed.
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

# Install the remote tip into $prefix, in three steps: clone, pack the
# clone, install the tarball. Exit status says whether it worked; the
# caller owns the directory passed in and deletes it either way.
#
# `npm install -g <git spec>` cannot do this job, and not for any reason
# to do with this script's environment: npm clones the spec into a
# temporary directory of its own (under ~/.npm/_cacache/tmp), and in
# global mode it installs that clone by *symlinking* the prefix at it and
# then removing the clone - so a lifecycle script, Fabrica's own `prepare`
# or esbuild's `postinstall`, is asked to run in a directory that no
# longer exists. That is the `npm error enoent spawn sh ENOENT` the
# install dies with, and `--ignore-scripts` only trades it for a dangling
# symlink to a deleted git-clone directory with no node_modules under it.
#
# `npm pack <git spec>` is not the answer either, which is what the clone
# below is for. For a `github:owner/repo` spec npm does not clone at all:
# it fetches GitHub's tarball of the tree (codeload), which carries no
# `.git`. Fabrica's `prepare` is scripts/write-build-info.mjs, and all it
# does is `git rev-parse HEAD` into build-info.json - so with no
# repository there it writes `{"commit":null}`, the install lands with no
# commit recorded anywhere, and `fabrica doctor` fails on the copy this
# step just installed. Nothing errors on the way: pack succeeds, install
# succeeds, and the only symptom is doctor refusing to start work.
#
# So the clone is this script's own: `git clone --depth 1 --branch
# <branch>`, into a directory under the one the caller made, with the
# same no-prompt and low-speed settings as the `ls-remote` above. `npm
# pack` with no spec packs the package in the current directory (npm's
# own documentation), running prepack/prepare/postpack there - `.git` is
# present, so build-info.json gets the real commit - and writes the
# tarball where --pack-destination says. Installing that tarball is an
# ordinary install: real files under the prefix, dependencies resolved,
# scripts run in a directory that stays put.
#
# One thing npm's git-dep path did for us that this does not: it
# installed the package's dependencies *and* devDependencies in its clone
# before running `prepare`. Fabrica's `prepare` is dependency-free plain
# node on purpose, so packing a bare clone is enough; if it ever grows a
# build that needs its node_modules, this function has to run an install
# in the clone first.
#
# The tarball is found by globbing rather than by name: npm names it from
# the packed package.json (<name>-<version>.tgz), which this script has
# no other reason to know. The directory is this run's own and was just
# created, so exactly one .tgz in it is the one that was just packed -
# any other count means something happened that was not planned for, and
# nothing is installed. The clone is a directory, so it never enters that
# count.
install_from_pack() {
  local tmpdir=$1
  local clone_dir=$tmpdir/clone
  local candidate
  local bin=$prefix/bin/fabrica
  local previous=
  local -a tarballs=()

  if ! GIT_TERMINAL_PROMPT=0 git \
    -c http.lowSpeedLimit=1000 \
    -c http.lowSpeedTime=15 \
    clone --quiet --depth 1 --branch "$branch" "$repo_url" "$clone_dir"; then
    warn "could not clone $branch from $repo_url into $clone_dir."
    return 1
  fi

  if ! (cd "$clone_dir" && npm pack --pack-destination "$tmpdir" >/dev/null); then
    warn "npm pack of the clone at $clone_dir failed."
    return 1
  fi

  for candidate in "$tmpdir"/*.tgz; do
    [ -f "$candidate" ] || continue
    tarballs+=("$candidate")
  done
  if [ "${#tarballs[@]}" -ne 1 ]; then
    warn "npm pack left ${#tarballs[@]} tarballs in $tmpdir rather than one."
    return 1
  fi

  # The launcher pin_fabrica_to_node writes lives at the exact path npm
  # wants for its own shim, and npm refuses to link a global bin over a
  # path it does not already own: bin-links' check-bin rejects with
  # "EEXIST: file already exists" for a global, top-level install unless
  # what is there is a symlink resolving into the package being installed.
  # The launcher is a real file, so without this every install after the
  # first pin would fail. `npm install -g --force` would buy the same
  # single exemption by switching off every other check npm has, so it is
  # not used. A symlink is left alone: that is npm's own shim, which npm
  # is entitled to replace, and this is the only install path that ever
  # ran before the pin existed.
  #
  # Moved aside rather than deleted, and moved back if the install fails:
  # before the pin existed a failed `npm install -g` simply left the
  # previous copy alone, and that is still the right outcome on a machine
  # in the middle of real work. The same shape as work/bootstrap.sh's
  # install_fabrica, for the same reason.
  #
  # A run killed between the two moves - a ctrl-C in `./run.sh rebuild`, a
  # lid closed mid-switch - leaves the launcher under its moved-aside name
  # with no `fabrica` beside it. restore_abandoned_launcher puts that
  # right, and runs before the install decision rather than after it,
  # because the decision can conclude there is nothing to install on
  # exactly the machine that has no fabrica at all; see there.
  if [ -e "$bin" ] && [ ! -L "$bin" ]; then
    previous=$bin.fabrica-sync-previous.$$
    mv -f "$bin" "$previous" || previous=
  fi

  if ! npm install -g --prefix "$prefix" "${tarballs[0]}"; then
    if [ -n "$previous" ]; then
      mv -f "$previous" "$bin" || true
    fi
    warn "npm install -g ${tarballs[0]} failed."
    return 1
  fi

  if [ -n "$previous" ]; then
    rm -f "$previous"
  fi
}

# Everything the install decision needs, as one function rather than as the
# top level of the script: every "nothing more to do here" below is a
# `return 0`, so the shadowing guard at the tail still runs after it. An
# `exit 0` would skip the guard on exactly the quiet paths - already
# current, no network - where a shadowing copy goes unnoticed longest.
sync_to_remote_tip() {
  local ls_remote remote_commit current_commit installed_now tmpdir

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

  say "installing $repo_url into $prefix (have: ${current_commit:-none recorded}, $branch: $remote_commit)"

  # The clone, the pack and the install all happen in a directory of this
  # run's own, removed whichever way they go: a clone and a tarball left
  # in $TMPDIR would be mistaken for nothing, but between them they are
  # two full copies of Fabrica's source and there is no reason for either
  # to outlive the install it was made for.
  if ! tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fabrica-sync.XXXXXX"); then
    warn "could not make a temporary directory, so Fabrica was not updated to $remote_commit."
    return 0
  fi
  if ! install_from_pack "$tmpdir"; then
    rm -rf "$tmpdir"
    warn "so Fabrica was not updated to $remote_commit."
    warn "re-run the switch, or \`fabrica update\`, once the cause is cleared."
    return 0
  fi
  rm -rf "$tmpdir"

  # Did the copy that just landed come out carrying its own commit? This
  # is the one thing about the install that can go wrong quietly: when the
  # packed tree has no `.git` in it, Fabrica's `prepare` writes
  # `{"commit":null}`, every command above still exits 0, and the first
  # sign of it is `fabrica doctor` refusing to work on a machine that was
  # switched successfully an hour ago. installed_commit falls back to the
  # record written below, which still holds the *previous* commit at this
  # point, so a mismatch reads the same way as nothing at all - which is
  # what it is.
  installed_now=$(installed_commit)
  if [ -z "$installed_now" ] || ! same_commit "$installed_now" "$remote_commit"; then
    warn "installed $remote_commit, but the copy in $pkg_dir reports ${installed_now:-no commit of its own}."
    warn "\`fabrica doctor\` reads that commit, so expect it to complain; see build-info.json there."
  fi

  if ! (mkdir -p "$state_dir" && printf '%s\n' "$remote_commit" >"$state_file"); then
    warn "installed $remote_commit but could not record it in $state_file;"
    warn "the next switch will reinstall once more, which is wasteful but harmless."
  fi
  return 0
}

# Which CLI script `fabrica` is meant to hand to node, printed on stdout.
# Exit status 1 means "could not tell", and the caller then leaves whatever
# is installed exactly as it is.
#
# Two sources, because this runs on every activation and only some of them
# have just installed:
#
#   - $1 is a symlink: that is npm's own shim, and what it points at is
#     npm's answer to where the package it installed put its entry point.
#     npm stays the one authority on that, rather than this script reading
#     package.json's `bin` field and redoing npm's normalization itself.
#     The chain is followed by hand rather than with `readlink -f` or
#     `realpath`, because this has to behave identically on personal-mac
#     and home-linux and neither is dependable on a stock macOS: there is
#     no `realpath` at all, and BSD `readlink` only grew `-f` recently
#     enough that an older OS build prints an empty line - which here
#     would generate a launcher that execs nothing.
#   - $1 is a regular file this script wrote: it carries the answer on its
#     own FABRICA_CLI line, which is exactly why the launcher is written
#     with one. That is the only source available on an activation that
#     installs nothing - above all the one that bumps
#     ./fabrica-node-version while Fabrica's own commit has not moved,
#     where there is no npm shim left to ask.
#
# The same symlink walk exists in work/bootstrap.sh (resolve_link) and in
# modules/managed-bin-guard.sh (mbg_resolve). Not shared, because nothing
# here can share it: Nix gives every file in this directory its own store
# path, so this script cannot source a sibling it was not handed, and the
# one library it is handed is deliberately sourced at the very end of this
# file (see there) so its absence costs a warning rather than the pin.
cli_entry() {
  local path=$1 hops=0 target dir line

  if [ -L "$path" ]; then
    while [ -L "$path" ] && [ "$hops" -lt 32 ]; do
      target=$(readlink "$path") || return 1
      [ -n "$target" ] || return 1
      case $target in
        /*) path=$target ;;
        *) path=$(dirname "$path")/$target ;;
      esac
      hops=$((hops + 1))
    done
    [ -f "$path" ] || return 1
    # An absolute path with no symlinked or relative component left in it:
    # the launcher runs from arbitrary working directories, so npm's own
    # relative `../lib/node_modules/...` target would resolve differently
    # every time.
    dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s' "$dir" "$(basename "$path")"
    return 0
  fi

  [ -f "$path" ] || return 1
  # `|| [ -n "$line" ]` so a final line with no newline is still read.
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      'FABRICA_CLI="'*'"')
        line=${line#'FABRICA_CLI="'}
        line=${line%'"'}
        [ -f "$line" ] || return 1
        printf '%s' "$line"
        return 0
        ;;
    esac
  done <"$path"
  return 1
}

# Put back a launcher that an interrupted install left moved aside, when
# there is no `fabrica` left for it to clash with.
#
# install_from_pack has to move a non-symlink bin entry out of npm's way
# before installing (see there), and moves it back itself if the install
# fails. What neither it nor npm can undo is the run being killed in
# between. work/bootstrap.sh has the identical window and can leave it to
# the next run, because that script reinstalls Fabrica unconditionally
# every time it is invoked. This one installs only when the commit moved,
# and npm unpacks the package - build-info.json included - before it links
# the bin, so the very next activation can read that commit, find it
# already current, skip the install, and leave the machine with no
# `fabrica` and no reason to make one. Hence an explicit recovery, first
# thing, ahead of that decision.
#
# Three conditions, all of them about not making things worse than finding
# nothing: only when there is no `fabrica` to overwrite, only when exactly
# one abandoned launcher is there to be unambiguous about, and only when
# the CLI it names is still installed - one pointing into a package that
# has since gone is a `fabrica` that starts and then fails, which is
# harder to read than one that is plainly missing. Everything else warns
# and returns 0, like every other path through this script.
restore_abandoned_launcher() {
  local bin=$prefix/bin/fabrica
  local candidate
  local -a abandoned=()

  if [ -e "$bin" ] || [ -L "$bin" ]; then
    return 0
  fi

  # An unmatched glob stays literal here (no nullglob), which the -f test
  # filters out along with anything that is not a plain file.
  for candidate in "$bin".fabrica-sync-previous.*; do
    [ -f "$candidate" ] || continue
    abandoned+=("$candidate")
  done
  if [ "${#abandoned[@]}" -eq 0 ]; then
    return 0
  fi
  if [ "${#abandoned[@]}" -gt 1 ]; then
    warn "${#abandoned[@]} abandoned launchers sit next to a missing $bin, so none of them"
    warn "was put back - there is no telling which is current. They are named"
    warn "$bin.fabrica-sync-previous.<pid>; keep the newest as $bin, delete the rest."
    return 0
  fi

  if ! cli_entry "${abandoned[0]}" >/dev/null 2>&1; then
    warn "an interrupted install left ${abandoned[0]} where $bin should be, but the CLI it"
    warn "names is no longer installed, so it was left alone. A switch with the network up"
    warn "reinstalls Fabrica and writes a fresh one."
    return 0
  fi

  if mv -f "${abandoned[0]}" "$bin"; then
    say "put back the launcher an interrupted install left at ${abandoned[0]}."
  else
    warn "could not put ${abandoned[0]} back as $bin, so there is no fabrica to run."
  fi
  return 0
}

# The launcher's full text on stdout, so the caller can compare it against
# what is already installed and write only when the two differ - a switch
# that changes nothing should say nothing.
#
# Deliberately the same shape as the one work/bootstrap.sh's
# write_fabrica_launcher generates for the work Mac, fnm fallback included.
# fnm's absolute path is baked in because this launcher must also work
# where no interactive shell has run - a launchd agent, a systemd unit, a
# cron-style job - and nothing has put the home-manager profile's bin
# directory on PATH. On these hosts that absolute path is a store path, so
# the `command -v` fallback is what covers the window between a
# `nix-collect-garbage` that removed it and the next switch, which rewrites
# this file from scratch.
launcher_text() {
  local entry=$1 fnm_bin=$2
  cat <<EOF
#!/bin/sh
# Generated by modules/fabrica-sync.sh - do not edit. Every home-manager
# activation on this host rewrites it from scratch.
#
# Fabrica runs on exactly Node $node_version, from whatever directory it is
# invoked in: 'fnm exec --using=<version>' picks that version for this one
# command without touching the shell, so a repository's own .node-version
# (which fnm's cd hook in modules/core.nix does act on) cannot change which
# Node Fabrica itself gets. It also puts that version first on PATH for
# everything Fabrica shells out to.
#
# FABRICA_CLI is npm's own answer to where the package it installed put its
# entry point, read off npm's shim before this file replaced it. It is kept
# on a line of its own so a later activation can read it back out of here
# when there is no npm shim left to ask - see cli_entry in the generator.
FABRICA_CLI="$entry"
FNM="$fnm_bin"
if [ ! -x "\$FNM" ]; then
  FNM="\$(command -v fnm)" || {
    echo "fabrica: fnm is not installed, so Node $node_version cannot be selected." >&2
    echo "         Re-run the switch: ./run.sh rebuild" >&2
    exit 127
  }
fi
exec "\$FNM" exec --using=$node_version node "\$FABRICA_CLI" "\$@"
EOF
}

# Make `fabrica` run on exactly the pinned version whatever the current
# directory declares, by replacing npm's shim with the launcher above.
#
# Runs on every path through this script, like the guard below: `fabrica
# update` (and any other `npm install -g`) puts npm's unpinned shim back at
# this path, so a machine that had nothing to install today is exactly
# where an unpinned fabrica survives unnoticed.
#
# Every failure warns and returns 0, leaving whatever runs today running.
# One ordering detail is what keeps that true: the launcher is written only
# once `fnm exec --using=<version>` has been shown to work, because a
# launcher naming a version fnm has not got turns a working `fabrica` into
# one that cannot start at all. (work/bootstrap.sh writes its launcher
# either way and reports the missing download as a pending item instead -
# it can, because a bootstrap is a command someone ran on purpose and is
# watching; an activation is not.)
pin_fabrica_to_node() {
  local bin=$prefix/bin/fabrica
  local fnm_bin entry want tmp

  if [ ! -e "$bin" ] && [ ! -L "$bin" ]; then
    # Nothing installed at all. The guard below is what says so, in its
    # own words, on every path through this script.
    return 0
  fi

  fnm_bin=$(command -v fnm 2>/dev/null) || fnm_bin=
  if [ -z "$fnm_bin" ]; then
    warn "no fnm on PATH, so fabrica was left running on whatever node the shell that"
    warn "starts it happens to have, rather than on Node $node_version. fnm is part of"
    warn "modules/core.nix's package set, so a switch reporting this is one to look into."
    return 0
  fi

  entry=$(cli_entry "$bin") || entry=
  if [ -z "$entry" ]; then
    warn "could not tell which CLI script $bin runs, so it was left exactly as it is"
    warn "and fabrica is not pinned to Node $node_version."
    return 0
  fi

  # fnm's own documented way to run one command on one version, used as the
  # probe as well, so what is checked is exactly the command line the
  # launcher ends in rather than merely that some directory exists under
  # fnm's base dir. `fnm install` is needed because `fnm exec` has no
  # --install-if-missing of its own (only `fnm use` does).
  if ! fnm exec --using="$node_version" node --version >/dev/null 2>&1; then
    say "installing Node $node_version through fnm - the one version Fabrica runs on."
    if ! fnm install "$node_version"; then
      warn "fnm install $node_version failed, so fabrica was left unpinned rather than"
      warn "pointed at a version that is not there. Re-run the switch, or \`fnm install"
      warn "$node_version\` by hand, once the cause is cleared."
      return 0
    fi
    if ! fnm exec --using="$node_version" node --version >/dev/null 2>&1; then
      warn "fnm install $node_version reported success but that version still cannot be"
      warn "selected, so fabrica was left unpinned."
      return 0
    fi
  fi

  want=$(launcher_text "$entry" "$fnm_bin")
  if [ -f "$bin" ] && [ ! -L "$bin" ] && [ "$(cat "$bin")" = "$want" ]; then
    say "fabrica already runs on Node $node_version, nothing to re-pin."
    return 0
  fi

  # Written to a temporary file and moved into place so the switch is
  # atomic. What sits at that path right now works - npm's own shim, or a
  # launcher naming another version - so a half-written `fabrica` would be
  # strictly worse than either end state, and `mv` never leaves one.
  tmp=$bin.fabrica-sync-tmp.$$
  if ! (printf '%s\n' "$want" >"$tmp" && chmod 755 "$tmp"); then
    rm -f "$tmp"
    warn "could not write $tmp, so fabrica is not pinned to Node $node_version."
    return 0
  fi
  if ! mv -f "$tmp" "$bin"; then
    rm -f "$tmp"
    warn "could not move the launcher into place at $bin, so fabrica is not pinned to"
    warn "Node $node_version."
    return 0
  fi
  say "fabrica pinned to Node $node_version (running $entry)."
  return 0
}

# Recovery first: the install decision below is allowed to conclude that
# there is nothing to do, and on a machine left without a `fabrica` by an
# interrupted run that conclusion is right about the commit and wrong about
# the machine.
restore_abandoned_launcher
sync_to_remote_tip
pin_fabrica_to_node

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
