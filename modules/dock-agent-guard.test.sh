#!/usr/bin/env bash
# Test suite for modules/dock-agent-guard.sh - the activation step that
# leaves personal-mac with a running Dock after nix-darwin's defaults step
# has restarted it.
#
# Hermetic, and it has to be: the one thing this step must never do is
# bounce a real Dock from a dev or test session. So `launchctl` here is a
# stub that answers `print` from a fixture, records every call, and decides
# for itself when a `kickstart` is allowed to work; `id` is a stub that maps
# one name to one uid, so the test never depends on who is running it; and
# `sleep` is a stub that logs the duration it was asked for and returns at
# once, which is how the two-second settle wait is checkable without a suite
# that waits four seconds to prove it. The script's launchctl candidate list
# is pointed at the stub, so the "no launchctl anywhere" case answers the
# same on a Mac as on Linux.
#
# Usage: bash modules/dock-agent-guard.test.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
GUARD="$SCRIPT_DIR/dock-agent-guard.sh"
LABEL=com.apple.Dock.agent
# The primary user the guard is asked about, and the uid the `id` stub
# answers for it. Deliberately not this process's own user or uid: the
# activate script runs as root, so a guard that asked `id -u` instead of
# `id -u <user>` would look at gui/0 and find no Dock there.
USER_NAME=inactdev
USER_UID=501

pass_count=0
fail_count=0

assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
    printf 'ok - %s\n' "$desc"
  else
    fail_count=$((fail_count + 1))
    printf 'FAIL - %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
  fi
}

assert_contains() {
  local desc=$1 haystack=$2 needle=$3
  case "$haystack" in
    *"$needle"*)
      pass_count=$((pass_count + 1))
      printf 'ok - %s\n' "$desc"
      ;;
    *)
      fail_count=$((fail_count + 1))
      printf 'FAIL - %s\n  expected to contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack"
      ;;
  esac
}

assert_not_contains() {
  local desc=$1 haystack=$2 needle=$3
  case "$haystack" in
    *"$needle"*)
      fail_count=$((fail_count + 1))
      printf 'FAIL - %s\n  expected NOT to contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack"
      ;;
    *)
      pass_count=$((pass_count + 1))
      printf 'ok - %s\n' "$desc"
      ;;
  esac
}

setup() {
  unset TMPDIR
  TMP=$(mktemp -d)
  HOME="$TMP/home"
  MOCK_DIR="$TMP/mock"
  CLI_DIR="$TMP/cli"
  STATE="$TMP/state"
  LAUNCHCTL="$CLI_DIR/launchctl"
  CALLS="$STATE/calls"
  mkdir -p "$HOME" "$MOCK_DIR" "$CLI_DIR" "$STATE"
  PATH="$MOCK_DIR:/usr/bin:/bin"
  # Only the scratch stub is ever a candidate, so no real launchctl on the
  # machine running this can be reached.
  DOCK_GUARD_LAUNCHCTL_CANDIDATES=$LAUNCHCTL
  export HOME PATH STATE DOCK_GUARD_LAUNCHCTL_CANDIDATES

  : >"$CALLS"
  # The Dock is up, launchd knows the service, kickstart is never needed and
  # would not work if asked, and waiting changes nothing. Each test sets the
  # one or two knobs its own case is about.
  printf '1\n' >"$STATE/running"
  printf '0\n' >"$STATE/print-fails"
  printf '0\n' >"$STATE/kickstart-count"
  printf '0\n' >"$STATE/kickstart-works-on"
  printf '0\n' >"$STATE/kickstart-lies"
  printf '0\n' >"$STATE/sleep-starts-dock"
  stub_sleep
  stub_id
  make_launchctl
}

teardown() {
  rm -rf "$TMP"
}

# `sleep <seconds>`: records what it was asked to wait for and returns at
# once. Optionally stands in for a Dock that comes back by itself while the
# guard is waiting.
stub_sleep() {
  cat >"$MOCK_DIR/sleep" <<'STUB'
#!/bin/sh
echo "sleep $*" >>"$STATE/calls"
if [ "$(cat "$STATE/sleep-starts-dock")" = 1 ]; then
  echo 1 >"$STATE/running"
fi
exit 0
STUB
  chmod +x "$MOCK_DIR/sleep"
}

# `id -u <name>`: one known name, one uid, and a failure for anything else -
# which is what the guard sees for a user that does not exist on the
# machine. `id -u` with no name answers 0, the way it would for the root the
# activate script runs as, so a guard that forgot to pass the user name
# would be caught rather than silently asking about the wrong domain.
stub_id() {
  cat >"$MOCK_DIR/id" <<STUB
#!/bin/sh
echo "id \$*" >>"\$STATE/calls"
if [ "\${2:-}" = "" ]; then
  echo 0
  exit 0
fi
if [ "\${2:-}" = "$USER_NAME" ]; then
  echo $USER_UID
  exit 0
fi
echo "id: \${2:-}: no such user" >&2
exit 1
STUB
  chmod +x "$MOCK_DIR/id"
}

# The stub launchctl. Records every call; answers `print` out of
# $STATE/running (and refuses outright when $STATE/print-fails is set, which
# is what a service launchd no longer knows about looks like); and starts the
# Dock on the $STATE/kickstart-works-on'th kickstart, never if that is 0.
# $STATE/kickstart-lies makes a kickstart start the Dock and still report
# failure, which is a real launchctl answer and must not read as one.
make_launchctl() {
  cat >"$LAUNCHCTL" <<'STUB'
#!/bin/sh
echo "launchctl $*" >>"$STATE/calls"
case "${1:-}" in
  print)
    if [ "$(cat "$STATE/running")" = 1 ]; then
      if [ -f "$STATE/print-running" ]; then
        cat "$STATE/print-running"
      else
        printf 'com.apple.Dock.agent = {\n\tstate = running\n\tpid = 4213\n\tpath = /System/Library/LaunchAgents/com.apple.Dock.plist\n}\n'
      fi
      exit 0
    fi
    if [ "$(cat "$STATE/print-fails")" != 0 ]; then
      echo 'Could not find service "com.apple.Dock.agent" in domain for login' >&2
      exit 113
    fi
    if [ -f "$STATE/print-stopped" ]; then
      cat "$STATE/print-stopped"
    else
      printf 'com.apple.Dock.agent = {\n\tstate = not running\n\tactive count = 0\n\tpath = /System/Library/LaunchAgents/com.apple.Dock.plist\n}\n'
    fi
    exit 0
    ;;
  kickstart)
    count=$(($(cat "$STATE/kickstart-count") + 1))
    echo "$count" >"$STATE/kickstart-count"
    if [ "$(cat "$STATE/kickstart-lies")" = 1 ]; then
      echo 1 >"$STATE/running"
      echo "Could not kickstart service: 125: Unknown error: 125" >&2
      exit 125
    fi
    works_on=$(cat "$STATE/kickstart-works-on")
    if [ "$works_on" != 0 ] && [ "$count" -ge "$works_on" ]; then
      echo 1 >"$STATE/running"
      exit 0
    fi
    echo "Could not kickstart service: 3: No such process" >&2
    exit 3
    ;;
esac
exit 0
STUB
  chmod +x "$LAUNCHCTL"
}

run_guard() {
  GUARD_OUT=$(bash "$GUARD" ${1+"$1"} 2>"$TMP/err")
  GUARD_RC=$?
  GUARD_ERR=$(cat "$TMP/err")
  CALL_LOG=$(cat "$CALLS")
  KICKSTARTS=$(grep -c "launchctl kickstart" "$CALLS")
}

test_a_running_dock_is_left_alone() {
  setup
  run_guard "$USER_NAME"

  assert_eq "exits 0" 0 "$GUARD_RC"
  assert_eq "never asks launchd to start anything" 0 "$KICKSTARTS"
  assert_contains "it did ask about the primary user's domain" "$CALL_LOG" \
    "launchctl print gui/$USER_UID/$LABEL"
  assert_eq "and says nothing at all on the happy path" "" "$GUARD_OUT"
  assert_eq "on either stream" "" "$GUARD_ERR"
  teardown
}

test_a_stopped_dock_is_started() {
  setup
  printf '0\n' >"$STATE/running"
  printf '1\n' >"$STATE/kickstart-works-on"
  run_guard "$USER_NAME"

  assert_eq "exits 0" 0 "$GUARD_RC"
  assert_contains "kickstarts the Dock in the primary user's GUI domain" "$CALL_LOG" \
    "launchctl kickstart gui/$USER_UID/$LABEL"
  assert_eq "exactly once" 1 "$KICKSTARTS"
  assert_contains "says the Dock was missing" "$GUARD_OUT" "the Dock is not running after the defaults step"
  assert_contains "and that it is back" "$GUARD_OUT" "the Dock is running again"
  assert_eq "with nothing on stderr" "" "$GUARD_ERR"
  assert_eq "and never waits, because the pid was there at once" 0 \
    "$(grep -c '^sleep' "$CALLS")"
  teardown
}

test_the_primary_users_uid_is_used_not_the_callers() {
  setup
  printf '0\n' >"$STATE/running"
  printf '1\n' >"$STATE/kickstart-works-on"
  run_guard "$USER_NAME"

  assert_contains "resolves the uid from the name it was given" "$CALL_LOG" "id -u $USER_NAME"
  assert_not_contains "never looks at the root domain the activation runs in" "$CALL_LOG" "gui/0/"
  teardown
}

test_a_service_launchd_no_longer_knows_counts_as_stopped() {
  setup
  printf '0\n' >"$STATE/running"
  printf '1\n' >"$STATE/print-fails"
  printf '1\n' >"$STATE/kickstart-works-on"
  run_guard "$USER_NAME"

  assert_eq "exits 0" 0 "$GUARD_RC"
  assert_contains "starts it anyway" "$CALL_LOG" "launchctl kickstart gui/$USER_UID/$LABEL"
  assert_contains "and says so" "$GUARD_OUT" "the Dock is running again"
  teardown
}

test_a_pidless_service_counts_as_stopped() {
  setup
  printf '0\n' >"$STATE/running"
  printf '1\n' >"$STATE/kickstart-works-on"
  # An inactive service whose output mentions pids without reporting one -
  # "pid = <n>" is the only thing that counts as running.
  printf 'com.apple.Dock.agent = {\n\tstate = not running\n\tpids = {\n\t}\n\tspid = 0\n}\n' \
    >"$STATE/print-stopped"
  run_guard "$USER_NAME"

  assert_contains "starts it" "$CALL_LOG" "launchctl kickstart gui/$USER_UID/$LABEL"
  assert_contains "and says so" "$GUARD_OUT" "the Dock is running again"
  teardown
}

test_a_dock_that_comes_back_during_the_wait_is_enough() {
  setup
  printf '0\n' >"$STATE/running"
  # Nothing the guard asks for works, but the Dock turns up by itself while
  # it waits - which is a success, not a warning.
  printf '0\n' >"$STATE/kickstart-works-on"
  printf '1\n' >"$STATE/sleep-starts-dock"
  run_guard "$USER_NAME"

  assert_eq "exits 0" 0 "$GUARD_RC"
  assert_eq "asked launchd once" 1 "$KICKSTARTS"
  assert_contains "waited two seconds for it" "$CALL_LOG" "sleep 2"
  assert_contains "and reports it is back" "$GUARD_OUT" "the Dock is running again"
  assert_eq "with no warning" "" "$GUARD_ERR"
  teardown
}

test_a_dock_that_needs_a_second_ask() {
  setup
  printf '0\n' >"$STATE/running"
  printf '2\n' >"$STATE/kickstart-works-on"
  run_guard "$USER_NAME"

  assert_eq "exits 0" 0 "$GUARD_RC"
  assert_eq "retries exactly once" 2 "$KICKSTARTS"
  assert_contains "after a two-second wait" "$CALL_LOG" "sleep 2"
  assert_contains "says it took a second ask" "$GUARD_OUT" "it took a second ask"
  assert_eq "and warns about nothing" "" "$GUARD_ERR"
  teardown
}

test_a_kickstart_that_reports_failure_but_starts_the_dock_is_a_success() {
  setup
  printf '0\n' >"$STATE/running"
  printf '1\n' >"$STATE/kickstart-lies"
  run_guard "$USER_NAME"

  assert_eq "exits 0" 0 "$GUARD_RC"
  assert_eq "asked launchd once" 1 "$KICKSTARTS"
  assert_contains "reports the Dock as back, because it is" "$GUARD_OUT" "the Dock is running again"
  assert_eq "and says nothing about a failure" "" "$GUARD_ERR"
  teardown
}

test_a_dock_that_cannot_be_started_warns_and_never_fails_the_switch() {
  setup
  printf '0\n' >"$STATE/running"
  printf '0\n' >"$STATE/kickstart-works-on"
  run_guard "$USER_NAME"

  assert_eq "never fails the switch" 0 "$GUARD_RC"
  assert_eq "having asked launchd twice and then stopped" 2 "$KICKSTARTS"
  assert_contains "says plainly that the Dock is down" "$GUARD_ERR" \
    "the Dock is not running and could not be started"
  assert_contains "passes launchctl's own answer on" "$GUARD_ERR" "No such process"
  assert_contains "says the rest of the switch was applied" "$GUARD_ERR" \
    "everything else in this switch was applied"
  assert_contains "and names the exact command to run by hand" "$GUARD_ERR" \
    "launchctl kickstart gui/$USER_UID/$LABEL"
  assert_eq "with that command as the last thing it prints" \
    "dock-agent-guard:   launchctl kickstart gui/$USER_UID/$LABEL" \
    "$(printf '%s\n' "$GUARD_ERR" | tail -n 1)"
  assert_not_contains "and never claims the Dock is back" "$GUARD_OUT" "running again"
  teardown
}

test_an_unknown_primary_user_is_reported_and_survivable() {
  setup
  printf '0\n' >"$STATE/running"
  run_guard somebody-else

  assert_eq "never fails the switch" 0 "$GUARD_RC"
  assert_contains "says whose Dock it could not look at" "$GUARD_ERR" \
    "could not resolve a uid for 'somebody-else'"
  assert_contains "and how to start a missing Dock by hand" "$GUARD_ERR" \
    "launchctl kickstart gui/\$(id -u)/$LABEL"
  assert_eq "asks launchd nothing" "" "$(grep '^launchctl' "$CALLS")"
  teardown
}

test_no_launchctl_anywhere_is_reported_and_survivable() {
  setup
  rm -f "$LAUNCHCTL"
  run_guard "$USER_NAME"

  assert_eq "never fails the switch" 0 "$GUARD_RC"
  assert_contains "says there is no launchctl" "$GUARD_ERR" "no launchctl here"
  assert_eq "and does nothing else" "" "$CALL_LOG"
  teardown
}

test_the_first_launchctl_candidate_that_exists_wins() {
  setup
  # Two candidates, the first missing - the shape of an activation whose
  # PATH has no launchctl on it, falling through to /bin/launchctl.
  DOCK_GUARD_LAUNCHCTL_CANDIDATES="$TMP/nowhere/launchctl $LAUNCHCTL"
  export DOCK_GUARD_LAUNCHCTL_CANDIDATES
  printf '0\n' >"$STATE/running"
  printf '1\n' >"$STATE/kickstart-works-on"
  run_guard "$USER_NAME"

  assert_contains "falls through to the one that is there" "$CALL_LOG" \
    "launchctl kickstart gui/$USER_UID/$LABEL"
  teardown
}

test_no_user_argument_is_a_usage_error() {
  setup
  run_guard

  assert_eq "refuses rather than guessing a domain" 1 "$GUARD_RC"
  assert_contains "and says how it is called" "$GUARD_ERR" "usage: dock-agent-guard"
  assert_eq "asking launchd nothing" "" "$CALL_LOG"
  teardown
}

test_a_running_dock_is_left_alone
test_a_stopped_dock_is_started
test_the_primary_users_uid_is_used_not_the_callers
test_a_service_launchd_no_longer_knows_counts_as_stopped
test_a_pidless_service_counts_as_stopped
test_a_dock_that_comes_back_during_the_wait_is_enough
test_a_dock_that_needs_a_second_ask
test_a_kickstart_that_reports_failure_but_starts_the_dock_is_a_success
test_a_dock_that_cannot_be_started_warns_and_never_fails_the_switch
test_an_unknown_primary_user_is_reported_and_survivable
test_no_launchctl_anywhere_is_reported_and_survivable
test_the_first_launchctl_candidate_that_exists_wins
test_no_user_argument_is_a_usage_error

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
