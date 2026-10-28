#!/usr/bin/env bash
# Test suite for modules/inkwell-linux-sync.sh - the activation step that
# keeps home-linux's Inkwell backend binary current and keeps its systemd
# user service running on that binary.
#
# Hermetic in every direction. The script's own decisions are two - did the
# binary change, and what does that mean for the unit - and both are made
# from things that are trivial to stand in for: `systemctl` here is a stub on
# a scratch PATH that answers from fixture files and appends every invocation
# to one call log, and the build it delegates to (modules/inkwell-sync.sh in
# real life, whose own decisions have their own suite) is a stub script that
# installs a binary, or doesn't, or fails, as each test asks. No systemd, no
# clone, no compiler, no network, and nothing that could touch a real
# ~/go/bin or a real service: $HOME and the Go bin directory live under one
# mktemp -d, and the candidate list the script searches for a systemctl is
# pointed at the scratch directory - which is also what makes the "no
# systemctl anywhere" case test the same on CI's systemd-having runner as on
# a Mac.
#
# Usage: bash modules/inkwell-linux-sync.test.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SYNC="$SCRIPT_DIR/inkwell-linux-sync.sh"

# The unit name modules/inkwell-linux.nix passes.
UNIT=inkwell-backend.service

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

# The fixture world: a scratch HOME with the Go bin directory under it, the
# systemctl stub and the stand-in build script, and the fixtures both answer
# from.
setup() {
  # Dropped before this run's mktemp, not merely reassigned: the previous
  # test's teardown has removed the directory TMPDIR still names, and mktemp
  # honours it.
  unset TMPDIR
  TMP=$(mktemp -d)
  HOME="$TMP/home"
  MOCK_DIR="$TMP/mock"
  STATE="$TMP/state"
  GOBIN="$HOME/go/bin"
  BIN="$GOBIN/inkwell-backend"
  BUILD="$TMP/build.sh"
  CALLS="$STATE/calls"
  mkdir -p "$HOME" "$MOCK_DIR" "$STATE" "$GOBIN"
  PATH="$MOCK_DIR:/usr/bin:/bin"
  # Only the stub is ever a candidate, so no real systemctl on the machine
  # running this can be reached - and "no systemctl here" is testable at all.
  INKWELL_SYSTEMCTL_CANDIDATES="$MOCK_DIR/systemctl"
  export HOME PATH STATE INKWELL_SYSTEMCTL_CANDIDATES

  : >"$CALLS"
  # Defaults, each overridden by the tests that care: there is a systemd user
  # session, the unit is active, and systemd does whatever it is asked.
  printf '0\n' >"$STATE/show-environment-exit"
  printf '0\n' >"$STATE/is-active-exit"
  printf '0\n' >"$STATE/daemon-reload-exit"
  printf '0\n' >"$STATE/restart-exit"
  printf '0\n' >"$STATE/start-exit"
  stub_systemctl
  stub_build installs-nothing
}

teardown() {
  rm -rf "$TMP"
}

# `systemctl`: records every call and answers each subcommand from its own
# fixture, so a test can say "this box has no user session" or "the restart
# was refused" without a systemd anywhere near it.
stub_systemctl() {
  cat >"$MOCK_DIR/systemctl" <<'STUB'
#!/bin/sh
echo "systemctl $*" >>"$STATE/calls"
for arg in "$@"; do
  case "$arg" in
    show-environment) exit "$(cat "$STATE/show-environment-exit")" ;;
    daemon-reload) exit "$(cat "$STATE/daemon-reload-exit")" ;;
    is-active) exit "$(cat "$STATE/is-active-exit")" ;;
    restart) exit "$(cat "$STATE/restart-exit")" ;;
    start) exit "$(cat "$STATE/start-exit")" ;;
  esac
done
exit 0
STUB
  chmod +x "$MOCK_DIR/systemctl"
}

# The stand-in for modules/inkwell-sync.sh. Records what it was handed - the
# delegation's shape is part of what this suite checks - and then does one of
# three things.
#
# "installs-a-binary" writes a *new* file and renames it into place, which is
# what the real script does and what makes the installed binary a different
# inode; a test that merely overwrote the same file in the same second would
# be testing nothing, since that is precisely the case the script must read
# as unchanged.
stub_build() {
  local behaviour=$1
  cat >"$BUILD" <<STUB
#!/bin/sh
echo "build \$*" >>"\$STATE/calls"
case "$behaviour" in
  installs-a-binary)
    echo "inkwell-sync: installed" >&2
    printf 'backend-%s\n' "\$\$" >"$BIN.new"
    chmod +x "$BIN.new"
    mv -f "$BIN.new" "$BIN"
    ;;
  fails)
    echo "inkwell-sync: something unexpected" >&2
    exit 1
    ;;
esac
exit 0
STUB
  chmod +x "$BUILD"
}

# A binary that was already installed before this switch.
install_existing_binary() {
  printf 'backend-already-here\n' >"$BIN"
  chmod +x "$BIN"
}

run_sync() {
  SYNC_OUT=$(bash "$SYNC" "$GOBIN" "$UNIT" "$BUILD" 2>"$TMP/err")
  SYNC_RC=$?
  SYNC_ERR=$(cat "$TMP/err")
  CALL_LOG=$(cat "$CALLS")
}

test_the_build_is_delegated_with_no_launchd_label() {
  setup
  install_existing_binary
  run_sync

  assert_eq "exits 0" 0 "$SYNC_RC"
  # Exactly the Go bin directory and nothing else: a second argument would be
  # a launchd label, and launchctl does not exist on this host.
  assert_contains "hands the build script the Go bin directory" "$CALL_LOG" "build $GOBIN"
  assert_not_contains "and no launchd label after it" "$CALL_LOG" "build $GOBIN "
  teardown
}

test_a_rebuilt_binary_restarts_the_unit() {
  setup
  install_existing_binary
  stub_build installs-a-binary
  run_sync

  assert_eq "exits 0" 0 "$SYNC_RC"
  assert_contains "restarts the unit" "$CALL_LOG" "systemctl --user restart $UNIT"
  assert_contains "and says so" "$SYNC_OUT" "restarted $UNIT onto the newly built backend"
  assert_contains "after making sure systemd has read the unit" "$CALL_LOG" \
    "systemctl --user daemon-reload"
  teardown
}

test_a_first_install_starts_the_unit_on_the_new_binary() {
  setup
  stub_build installs-a-binary
  run_sync

  assert_eq "exits 0" 0 "$SYNC_RC"
  # `restart` rather than `start`, deliberately: on a first switch the unit
  # has been retrying against a binary that did not exist yet, and restart
  # starts an inactive unit as well as bouncing a running one.
  assert_contains "restarts onto what was just installed" "$CALL_LOG" \
    "systemctl --user restart $UNIT"
  teardown
}

test_an_unchanged_binary_that_is_running_is_left_alone() {
  setup
  install_existing_binary
  run_sync

  assert_eq "exits 0" 0 "$SYNC_RC"
  assert_contains "says it is running" "$SYNC_OUT" "$UNIT is running the installed backend"
  assert_not_contains "restarts nothing" "$CALL_LOG" "--user restart"
  assert_not_contains "and starts nothing" "$CALL_LOG" "--user start"
  teardown
}

test_an_unchanged_binary_that_is_not_running_is_started() {
  setup
  install_existing_binary
  printf '3\n' >"$STATE/is-active-exit"
  run_sync

  assert_eq "exits 0" 0 "$SYNC_RC"
  assert_contains "starts it" "$CALL_LOG" "systemctl --user start $UNIT"
  assert_contains "and says it was not running" "$SYNC_OUT" "which was not running"
  assert_not_contains "without bouncing a binary nobody rebuilt" "$CALL_LOG" "--user restart"
  teardown
}

test_a_failed_unit_is_started_again() {
  setup
  install_existing_binary
  # What a unit left `failed` by a key file that had not been placed yet
  # looks like - the common sequence on a box's first day.
  printf '1\n' >"$STATE/is-active-exit"
  run_sync

  assert_contains "starts it rather than leaving it failed" "$CALL_LOG" \
    "systemctl --user start $UNIT"
  teardown
}

test_a_build_that_installs_nothing_starts_nothing() {
  setup
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_contains "says there is no backend to run" "$SYNC_ERR" "no backend installed at $BIN"
  assert_not_contains "and asks systemd for nothing" "$CALL_LOG" "--user restart"
  assert_not_contains "nothing at all" "$CALL_LOG" "--user start"
  teardown
}

test_a_build_that_fails_leaves_the_service_tended() {
  setup
  install_existing_binary
  stub_build fails
  printf '3\n' >"$STATE/is-active-exit"
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_contains "names the script that misbehaved" "$SYNC_ERR" "$BUILD exited non-zero"
  assert_contains "and still gets the backend running" "$CALL_LOG" "systemctl --user start $UNIT"
  teardown
}

test_a_missing_build_script_is_survivable() {
  setup
  install_existing_binary
  rm -f "$BUILD"
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_contains "says nothing read the remote tip" "$SYNC_ERR" "no build script at $BUILD"
  assert_contains "and still checks on the unit" "$SYNC_OUT" "is running the installed backend"
  teardown
}

test_no_systemctl_anywhere_is_reported_and_survivable() {
  setup
  install_existing_binary
  rm -f "$MOCK_DIR/systemctl"
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_contains "says nothing checked the unit" "$SYNC_ERR" "no systemctl here"
  assert_contains "but the build still ran" "$CALL_LOG" "build $GOBIN"
  teardown
}

test_no_systemd_user_session_is_reported_and_survivable() {
  setup
  install_existing_binary
  printf '1\n' >"$STATE/show-environment-exit"
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_contains "says there is no user session" "$SYNC_ERR" "no systemd user session here"
  assert_contains "and names what keeps one alive on a headless box" "$SYNC_ERR" "linger"
  assert_not_contains "asks systemd to start nothing" "$CALL_LOG" "--user start"
  assert_not_contains "and to reload nothing" "$CALL_LOG" "daemon-reload"
  teardown
}

test_a_refused_restart_is_a_warning_not_a_failure() {
  setup
  install_existing_binary
  stub_build installs-a-binary
  printf '1\n' >"$STATE/restart-exit"
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_contains "says the old backend is still the one running" "$SYNC_ERR" \
    "still running the previous backend"
  assert_contains "and where systemd's own reason is" "$SYNC_ERR" "journalctl --user -u $UNIT"
  teardown
}

test_a_refused_start_names_the_usual_cause() {
  setup
  install_existing_binary
  printf '3\n' >"$STATE/is-active-exit"
  printf '1\n' >"$STATE/start-exit"
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_contains "says it could not be started" "$SYNC_ERR" "could not be started"
  assert_contains "names the key file as the usual first-day reason" "$SYNC_ERR" "key file"
  assert_contains "and where to read the rest" "$SYNC_ERR" "journalctl --user -u $UNIT"
  teardown
}

test_a_refused_daemon_reload_does_not_stop_the_start() {
  setup
  install_existing_binary
  printf '1\n' >"$STATE/daemon-reload-exit"
  printf '3\n' >"$STATE/is-active-exit"
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_contains "still starts the unit" "$CALL_LOG" "systemctl --user start $UNIT"
  teardown
}

test_missing_arguments_are_a_usage_failure() {
  setup
  OUT=$(bash "$SYNC" "$GOBIN" 2>&1)
  RC=$?

  assert_eq "refuses" 1 "$RC"
  assert_contains "says how it is called" "$OUT" "usage: inkwell-linux-sync"
  teardown
}

test_the_build_is_delegated_with_no_launchd_label
test_a_rebuilt_binary_restarts_the_unit
test_a_first_install_starts_the_unit_on_the_new_binary
test_an_unchanged_binary_that_is_running_is_left_alone
test_an_unchanged_binary_that_is_not_running_is_started
test_a_failed_unit_is_started_again
test_a_build_that_installs_nothing_starts_nothing
test_a_build_that_fails_leaves_the_service_tended
test_a_missing_build_script_is_survivable
test_no_systemctl_anywhere_is_reported_and_survivable
test_no_systemd_user_session_is_reported_and_survivable
test_a_refused_restart_is_a_warning_not_a_failure
test_a_refused_start_names_the_usual_cause
test_a_refused_daemon_reload_does_not_stop_the_start
test_missing_arguments_are_a_usage_failure

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
