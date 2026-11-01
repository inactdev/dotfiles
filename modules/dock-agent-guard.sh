#!/usr/bin/env bash
#
# dock-agent-guard - leave personal-mac with a running Dock after a
# nix-darwin switch.
#
# Applying `system.defaults` restarts the Dock, and on this macOS the
# restart can be the end of it: the agent exits cleanly, and launchd - which
# only revives a job that died - leaves the service inactive.
#
#   com.apple.Dock.agent exited due to exit(0)
#   ... service inactive
#
# What that leaves behind is a machine with no Dock and no Spaces swiping
# until the next login or reboot, from a switch that reported success. So
# this runs after the defaults step, asks launchd whether the Dock agent is
# actually running for the primary user, and starts it when it is not.
#
# Three things it never does, which is why this is a guarded step rather
# than a bare `launchctl kickstart` line in the activation:
#
#   - it never touches a Dock that is running. The check comes first and
#     `kickstart -k` is never used: killing a healthy Dock on every rebuild
#     is the failure this exists to end, not a cheaper way to fix it.
#   - it never fails the switch. Every path exits 0, because everything else
#     in the switch has already been applied by the time this runs and a
#     non-zero exit here would wrongly read as "the switch did not happen".
#     A Dock it could not start is reported instead, naming the one command
#     to run by hand.
#   - it never speaks on the happy path, so the rebuild output only grows a
#     line on the rebuilds where the Dock actually went missing.
#
# Run as: dock-agent-guard <primary-user>
#
# The user name is passed in rather than read from the environment because
# the activate script runs as root: `id -u` here is 0, and the Dock lives in
# the *primary user's* GUI domain. configuration.nix passes
# `config.system.primaryUser`, read back off the option rather than written
# out a second time, so this is always asked about the same user nix-darwin
# applied the defaults for even if that option is later pointed somewhere
# else. It also puts coreutils on PATH from the Nix store for `id` and
# `sleep`, since the activate script's own PATH is minimal (see
# notes/2026-10-17-personal-mac-ac-no-sleep.md).
set -euo pipefail

user=${1:?usage: dock-agent-guard <primary-user>}

label=com.apple.Dock.agent

# How long to give launchd and the Dock before asking again, in seconds.
# Two, because a Dock that is on its way back takes a moment to report a
# pid, and a warning printed before it got there would be false.
settle=2

# And how long to go on waiting after the retry, before saying it could not
# be started. This is the only wait whose length decides whether a warning
# is true or false - by the time it runs, two kickstarts have been asked for
# and the one thing that would make the warning wrong is a Dock still on its
# way up on a loaded machine - so it is the generous one. Both waits are
# polled a second at a time (see wait_for_dock) and end the moment a pid
# appears, so neither costs anything on a machine that is keeping up.
grace=5

say() { printf 'dock-agent-guard: %s\n' "$*"; }
warn() { printf 'dock-agent-guard: %s\n' "$*" >&2; }

# Where a launchctl can be, in the order it is looked for: whatever PATH
# says, then /bin/launchctl by absolute path, because launchctl is a macOS
# fixture that an activation's minimal PATH is not guaranteed to carry. Same
# lookup as modules/inkwell-sync.sh's ensure_agent.
#
# Overridable only so the test suite can point this at a stub and get the
# same answers on a machine that has a real launchctl as on one that does
# not - nothing in normal use sets it.
DOCK_GUARD_LAUNCHCTL_CANDIDATES=${DOCK_GUARD_LAUNCHCTL_CANDIDATES:-"launchctl /bin/launchctl"}

# Set by kickstart_once to whatever launchctl said when it refused, so the
# final warning can pass launchd's own words on. Empty when it said nothing.
last_error=

# Resolved in main before anything below is called.
launchctl=
domain=

find_launchctl() {
  local candidate resolved
  # shellcheck disable=SC2086 # deliberate word-split list, as in modules/inkwell-sync.sh
  for candidate in $DOCK_GUARD_LAUNCHCTL_CANDIDATES; do
    if resolved=$(command -v "$candidate" 2>/dev/null); then
      printf '%s\n' "$resolved"
      return 0
    fi
  done
  return 0
}

# Whether the Dock agent is running in $domain.
#
# Two independent ways `launchctl print` says yes, either of which is taken
# as a yes: a pid - `pid = <n>`, reported for a running job and absent for
# one that is merely loaded, the same predicate modules/inkwell-sync.sh uses
# for the Inkwell agent - and `state = running`, the same answer in words.
# Both, rather than the pid alone, so that this reads a future launchctl
# which drops or renames one of them correctly as long as it still prints the
# other. `state = not running` cannot match: the pattern requires `running`
# immediately after the equals sign.
#
# Positive evidence only, deliberately: a `print` that fails at all (the
# inactive service this guards against is not always still in the domain)
# and output carrying neither signal both count as not running. That is the
# safe direction on both counts - asking launchd to start a Dock that is
# already up never restarts it (`kickstart` is only asked to kill a running
# instance when it is given `-k`, which this never does), while believing a
# dead Dock is alive is the entire bug. The worst an unreadable future
# format can do is a needless pair of start requests and a warning that was
# not true; it cannot take a working Dock away.
dock_running() {
  local out
  if ! out=$("$launchctl" print "$domain/$label" 2>&1); then
    return 1
  fi
  [[ $out =~ (^|[^[:alnum:]])pid[[:space:]]*=[[:space:]]*[0-9]+ ]] && return 0
  [[ $out =~ (^|[^[:alnum:]])state[[:space:]]*=[[:space:]]*running ]]
}

# Wait up to $1 seconds for the Dock to turn up, a second at a time, and
# stop the moment it does. Polled rather than slept through in one go for
# both reasons: a Dock that is already back costs no wait at all, and the
# length of the wait stops being a race - a loaded machine that needs four
# seconds is seen at four seconds instead of being declared broken at two.
wait_for_dock() {
  local budget=$1 waited=0
  while [ "$waited" -lt "$budget" ]; do
    sleep 1
    waited=$((waited + 1))
    if dock_running; then
      return 0
    fi
  done
  return 1
}

# One attempt: ask launchd to start the agent, then look for it - at once,
# and again through the settle wait. The kickstart's own exit status is only
# ever a message: what decides is whether the Dock turns up, so a kickstart
# that reports failure while the Dock comes up anyway counts as a success,
# and one that reports success while nothing starts does not.
#
# The wait is also what makes "the Dock came back by itself" a success rather
# than a warning, which is the other way this resolves on a slow machine.
kickstart_once() {
  local out
  if out=$("$launchctl" kickstart "$domain/$label" 2>&1); then
    last_error=
  else
    last_error=$out
  fi
  if dock_running; then
    return 0
  fi
  wait_for_dock "$settle"
}

main() {
  local uid

  launchctl=$(find_launchctl)
  if [ -z "$launchctl" ]; then
    warn "no launchctl here, so nothing checked whether the Dock is running."
    return 0
  fi

  if ! uid=$(id -u "$user" 2>/dev/null) || [ -z "$uid" ]; then
    warn "could not resolve a uid for '$user', so nothing checked whether the Dock"
    warn "is running. If it is missing, start it by hand as that user with:"
    warn "  launchctl kickstart gui/\$(id -u)/$label"
    return 0
  fi

  domain="gui/$uid"

  if dock_running; then
    return 0
  fi

  say "the Dock is not running after the defaults step - starting $label..."

  if kickstart_once; then
    say "the Dock is running again."
    return 0
  fi

  # The one retry, which by now comes after the settle wait kickstart_once
  # already took. A second ask is cheap next to leaving the machine without
  # a Dock, and this is the path a Dock that was still shutting down when
  # the first kickstart arrived takes.
  if kickstart_once; then
    say "the Dock is running again - it took a second ask."
    return 0
  fi

  # Nothing is asked of launchd again here: this only goes on looking, for
  # the grace period above, so that a Dock which was simply slower than the
  # two settle waits is reported as back rather than as broken. A false
  # warning naming a command to run by hand is worse than a few seconds.
  if wait_for_dock "$grace"; then
    say "the Dock is running again - it took a moment longer than expected."
    return 0
  fi

  warn "the Dock is not running and could not be started.${last_error:+ launchctl said: $last_error}"
  warn "everything else in this switch was applied. Start the Dock by hand with:"
  warn "  launchctl kickstart $domain/$label"
  return 0
}

main
