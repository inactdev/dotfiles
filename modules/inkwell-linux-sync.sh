#!/usr/bin/env bash
#
# inkwell-linux-sync - keep home-linux's Inkwell backend binary current and
# keep its systemd user service running on that binary, from home-manager
# activation.
#
# This is the Linux half of what modules/inkwell-sync.sh does on the Mac, and
# it is a wrapper rather than a copy: the *build* decision - read the tip of
# inkwell's main branch, compare it against the revision stamped into the
# installed binary, build only when they differ - is identical on both hosts
# and already written, tested and proven there, so this delegates it and owns
# only the half that cannot be shared. launchd and systemd have nothing in
# common beyond the idea of a user service.
#
# Why anything has to own that half at all: home-manager (re)starts exactly
# those units whose *unit text* changed, and this unit's text deliberately
# never changes - it names the fixed path ~/go/bin/inkwell-backend so that a
# new generation is not a reason to bounce the backend (see
# modules/inkwell-linux.nix, and notes/20261021-dotfiles-auto-apply.md for
# where that rule came from). A rebuilt binary behind an unchanged unit
# therefore restarts nothing, and whatever rebuilt it has to say so. That is
# this script: it notes what is installed, delegates the build, and compares.
#
# Like its sibling it never fails a switch. No network, no credentials, a
# failed build, no systemd user session, a refused restart: each warns on
# stderr and exits 0, leaving whatever is installed and running exactly as it
# was. Keeping the backend current is never worth losing the rest of an
# activation over - and the one hard refusal in this area is deliberately
# somewhere else, in the key-file guard the service runs before every start.
#
# Run as: inkwell-linux-sync <gobin-directory> <unit-name> [build-script]
# The first two come from modules/inkwell-linux.nix, which holds the one
# definition of where the managed binary lives and what the unit is called
# (it reads neither back from here). The build script is passed too, because
# a Nix store path has no siblings - run by hand from a checkout it defaults
# to the one next to this file.
set -euo pipefail

gobin=${1:?usage: inkwell-linux-sync <gobin-directory> <unit-name> [build-script]}
unit=${2:?usage: inkwell-linux-sync <gobin-directory> <unit-name> [build-script]}
build_script=${3:-"$(dirname -- "${BASH_SOURCE[0]}")/inkwell-sync.sh"}

bin_name=inkwell-backend
bin=$gobin/$bin_name

# Where a systemctl can be, in the order it is looked for: PATH first, then
# the fixed locations an activation's PATH is not guaranteed to carry (a
# scheduled switch is not a login shell), including NixOS'. Overridable only
# so the test suite gets the same answers on a machine that has systemd as on
# one that does not.
INKWELL_SYSTEMCTL_CANDIDATES=${INKWELL_SYSTEMCTL_CANDIDATES:-"systemctl /usr/bin/systemctl /bin/systemctl /run/current-system/sw/bin/systemctl"}

say() { printf 'inkwell-linux-sync: %s\n' "$*"; }
warn() { printf 'inkwell-linux-sync: %s\n' "$*" >&2; }

# What is installed right now, as a string to compare against the same string
# afterwards. Inode, size and mtime rather than a hash: the build script
# installs by renaming a freshly built file into place, so the inode alone
# already answers "is this a different binary than the one that was here",
# and this needs no second read of a 10MB file on every switch. "none" and
# "unreadable" are answers too - two unreadable reads compare equal, which is
# the conservative outcome: nothing is restarted on a machine where nothing
# can be measured.
binary_identity() {
  if [ ! -e "$bin" ]; then
    printf 'none\n'
    return 0
  fi
  stat -c '%i %s %Y' "$bin" 2>/dev/null || printf 'unreadable\n'
}

find_systemctl() {
  local candidate resolved
  # shellcheck disable=SC2086 # INKWELL_SYSTEMCTL_CANDIDATES is a deliberate word-split list
  for candidate in $INKWELL_SYSTEMCTL_CANDIDATES; do
    if resolved=$(command -v "$candidate" 2>/dev/null); then
      printf '%s\n' "$resolved"
      return 0
    fi
  done
  return 0
}

# The build, delegated. Run with "${BASH:-bash}" rather than by name because
# the PATH this gets from modules/inkwell-linux.nix carries the store's go,
# git, awk and coreutils - the things the build needs - and deliberately not
# a bash, since the module already passes one to run this script.
#
# No launchd label is passed, which is how that script is told to bring the
# binary up to date and start nothing: launchctl does not exist here, and
# the unit below is this script's business.
delegate_build() {
  if [ ! -f "$build_script" ]; then
    warn "no build script at $build_script, so nothing read the remote tip and"
    warn "the installed backend is left exactly as it is."
    return 0
  fi
  if ! "${BASH:-bash}" "$build_script" "$gobin"; then
    warn "$build_script exited non-zero, which it is written never to do; what is"
    warn "installed is left as it is."
  fi
  return 0
}

# The unit, on every path through this script including the ones that build
# nothing - a service that was stopped, or that failed because its key file
# was not there yet, is exactly the one nobody is watching.
ensure_service() {
  local rebuilt=$1
  local systemctl

  systemctl=$(find_systemctl)
  if [ -z "$systemctl" ]; then
    warn "no systemctl here, so nothing checked whether $unit is running."
    return 0
  fi

  # The same question modules/linux.nix asks before starting its timer: a
  # systemd user manager has to be up for `--user` to mean anything, and it
  # is not up in a container, during a build, or on a box where linger is
  # off and nobody is logged in.
  if ! "$systemctl" --user show-environment >/dev/null 2>&1; then
    warn "no systemd user session here, so $unit was not started; it starts at the"
    warn "next login - or at boot, on a box where linger is enabled for this user"
    warn "(which every home-linux switch does, see modules/linux.nix)."
    return 0
  fi

  if [ ! -x "$bin" ]; then
    warn "no backend installed at $bin, so $unit was not started - it would only"
    warn "fail to start and be retried every ten seconds. Re-run the switch once"
    warn "the build above works."
    return 0
  fi

  # Not redundant with home-manager's own reload: whether home-manager
  # reloads the user manager at all depends on systemd.user.startServices,
  # whose default has changed across releases (see the same note in
  # modules/linux.nix), and on the very first switch this unit is brand new.
  # Starting a unit the manager has not read yet is the one failure here that
  # would be nobody's fault but ours.
  "$systemctl" --user daemon-reload || true

  if [ "$rebuilt" = 1 ]; then
    if "$systemctl" --user restart "$unit"; then
      say "restarted $unit onto the newly built backend."
    else
      warn "could not restart $unit, so it is still running the previous backend."
      warn "its own reason is in:"
      warn "  journalctl --user -u $unit"
    fi
    return 0
  fi

  # Installed and unchanged: the only thing left to ask is whether it is
  # actually running. Asking keeps this quiet on the switches where
  # everything is fine, and starting is idempotent on the ones where it is
  # not - including a unit left `failed` by a key file that has since been
  # placed, which is the common first-day sequence on a new box.
  if "$systemctl" --user is-active --quiet "$unit"; then
    say "$unit is running the installed backend."
    return 0
  fi

  if "$systemctl" --user start "$unit"; then
    say "started $unit, which was not running."
  else
    warn "$unit is not running and could not be started. On a box that has never"
    warn "run it, a missing or too-open key file is the usual reason and the step"
    warn "before this one names the file; everything else is in:"
    warn "  journalctl --user -u $unit"
  fi
  return 0
}

main() {
  local before after rebuilt

  before=$(binary_identity)
  delegate_build
  after=$(binary_identity)

  rebuilt=0
  if [ "$before" != "$after" ]; then
    rebuilt=1
  fi

  ensure_service "$rebuilt"
}

main
