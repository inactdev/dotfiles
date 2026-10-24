#!/usr/bin/env bash
# Test suite for modules/inkwell-sync.sh - the activation step that keeps
# the installed Inkwell backend in step with the tip of its main branch and
# keeps its launchd agent running on it.
#
# Hermetic in every direction, and that is the whole point: the script's two
# jobs are to decide *whether* to build and to decide *what to tell
# launchd*, and both decisions are made from the output of commands that are
# trivial to stand in for. `git`, `go` and `launchctl` are stubs on a
# scratch PATH that read their answers from fixture files and append every
# invocation to one call log, so each test is an assertion about what the
# script decided. No clone, no compiler, no launchd, no network - and
# nothing that could touch a real ~/go/bin or a real agent: $HOME, the Go
# bin directory and $TMPDIR all live under one mktemp -d.
#
# Linux-friendly on purpose (it runs on CI's ubuntu runner like the repo's
# other bash suites) even though the script it tests only ever runs on
# personal-mac: every macOS-only command it reaches is one of the stubs.
#
# Usage: bash modules/inkwell-sync.test.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SYNC="$SCRIPT_DIR/inkwell-sync.sh"

# The label modules/inkwell.nix passes (home-manager's own prefix plus the
# agent's attribute name), and two full-length commits to play tip-moved
# with.
LABEL=org.nix-community.home.inkwell-backend
REMOTE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

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

assert_file() {
  local desc=$1 path=$2
  if [ -f "$path" ]; then
    pass_count=$((pass_count + 1))
    printf 'ok - %s\n' "$desc"
  else
    fail_count=$((fail_count + 1))
    printf 'FAIL - %s\n  expected a file at: %s\n' "$desc" "$path"
  fi
}

assert_absent() {
  local desc=$1 path=$2
  if [ -e "$path" ] || [ -L "$path" ]; then
    fail_count=$((fail_count + 1))
    printf 'FAIL - %s\n  expected nothing at: %s\n' "$desc" "$path"
  else
    pass_count=$((pass_count + 1))
    printf 'ok - %s\n' "$desc"
  fi
}

# The fixture world: a scratch HOME (with the Go bin directory and the
# LaunchAgents directory under it), the stubs, the fixtures they answer
# from, and a scratch TMPDIR so the script's own throwaway clone directory
# is created somewhere this suite can prove it was cleaned up.
setup() {
  # Dropped before the first mktemp of the run, not just assigned below:
  # the previous test pointed TMPDIR at a directory its teardown has since
  # removed, and mktemp honours it.
  unset TMPDIR
  TMP=$(mktemp -d)
  HOME="$TMP/home"
  MOCK_DIR="$TMP/mock"
  STATE="$TMP/state"
  TMPDIR="$TMP/tmp"
  GOBIN="$HOME/go/bin"
  BIN="$GOBIN/inkwell-backend"
  AGENTS="$HOME/Library/LaunchAgents"
  PLIST="$AGENTS/$LABEL.plist"
  CALLS="$STATE/calls"
  UID_NOW=$(id -u)
  mkdir -p "$HOME" "$MOCK_DIR" "$STATE" "$TMPDIR" "$AGENTS"
  # A hermetic PATH: the stubs first, then just enough of the real system
  # for the script's own coreutils and awk use.
  PATH="$MOCK_DIR:/usr/bin:/bin"
  export HOME PATH STATE TMPDIR

  : >"$CALLS"
  # Defaults, each overridden by the tests that care: the remote tip is
  # readable and is REMOTE_SHA, a clone succeeds and lands on that same
  # commit, a build succeeds, and launchd does whatever it is asked.
  printf '%s\trefs/heads/main\n' "$REMOTE_SHA" >"$STATE/ls-remote"
  printf '0\n' >"$STATE/ls-remote-exit"
  printf '0\n' >"$STATE/clone-exit"
  printf '%s\n' "$REMOTE_SHA" >"$STATE/clone-head"
  printf '0\n' >"$STATE/build-exit"
  printf '0\n' >"$STATE/launchctl-exit"
  printf '0\n' >"$STATE/print-exit"
  printf '\tstate = running\n\tpid = 4242\n' >"$STATE/print-out"
  stub_git
  stub_go
  stub_launchctl
}

teardown() {
  rm -rf "$TMP"
}

# `git`: answers ls-remote from a fixture, makes a clone look like a clone
# (a directory with the backend module in it), and reports the cloned HEAD
# the test asked for. Option skipping mirrors how the script calls it -
# `-c name=value` pairs before the subcommand, and `-C <dir>` for the
# rev-parse.
stub_git() {
  cat >"$MOCK_DIR/git" <<'STUB'
#!/bin/sh
echo "git $*" >>"$STATE/calls"
while [ $# -gt 0 ]; do
  case $1 in
    -c | -C) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
case ${1:-} in
  ls-remote)
    cat "$STATE/ls-remote"
    exit "$(cat "$STATE/ls-remote-exit")"
    ;;
  clone)
    for arg in "$@"; do dst=$arg; done
    if [ "$(cat "$STATE/clone-exit")" != 0 ]; then
      echo "stub: clone refused" >&2
      exit "$(cat "$STATE/clone-exit")"
    fi
    mkdir -p "$dst/backend"
    echo 'module inkwell/backend' >"$dst/backend/go.mod"
    ;;
  rev-parse)
    cat "$STATE/clone-head"
    ;;
esac
exit 0
STUB
  chmod +x "$MOCK_DIR/git"
}

# `go`: prints the build info fixture for `go version -m`, and for `go
# build` writes something executable to the -o path and then promotes the
# "after" fixture to be what the next build-info read reports - so the
# script's own post-build check sees the commit it just built, exactly as a
# real stamped binary would make it.
stub_go() {
  cat >"$MOCK_DIR/go" <<'STUB'
#!/bin/sh
echo "go $*" >>"$STATE/calls"
case ${1:-} in
  version)
    [ -f "$STATE/go-version-out" ] || exit 1
    cat "$STATE/go-version-out"
    ;;
  build)
    echo "go-env CGO_ENABLED=${CGO_ENABLED:-unset}" >>"$STATE/calls"
    out=''
    prev=''
    for arg in "$@"; do
      if [ "$prev" = "-o" ]; then out=$arg; fi
      prev=$arg
    done
    if [ "$(cat "$STATE/build-exit")" != 0 ]; then
      echo "stub: build refused" >&2
      exit "$(cat "$STATE/build-exit")"
    fi
    printf '#!/bin/sh\necho inkwell-backend\n' >"$out"
    chmod +x "$out"
    if [ -f "$STATE/go-version-after" ]; then
      cp "$STATE/go-version-after" "$STATE/go-version-out"
    fi
    ;;
esac
exit 0
STUB
  chmod +x "$MOCK_DIR/go"
}

stub_launchctl() {
  cat >"$MOCK_DIR/launchctl" <<'STUB'
#!/bin/sh
echo "launchctl $*" >>"$STATE/calls"
case ${1:-} in
  print)
    cat "$STATE/print-out" 2>/dev/null
    exit "$(cat "$STATE/print-exit")"
    ;;
esac
exit "$(cat "$STATE/launchctl-exit")"
STUB
  chmod +x "$MOCK_DIR/launchctl"
}

# What `go version -m` should report about the installed binary: a stamped
# build at $1, modified or not per $2. Written as the real thing writes it,
# tab-indented records, with unrelated ones around the two that matter.
build_info() {
  local revision=$1 modified=$2 where=$3
  {
    printf '%s: go1.26.5\n' "$BIN"
    printf '\tpath\tinkwell/backend\n'
    printf '\tmod\tinkwell/backend\t(devel)\t\n'
    printf '\tbuild\tCGO_ENABLED=0\n'
    printf '\tbuild\tvcs=git\n'
    printf '\tbuild\tvcs.revision=%s\n' "$revision"
    printf '\tbuild\tvcs.time=2026-10-22T20:25:38Z\n'
    printf '\tbuild\tvcs.modified=%s\n' "$modified"
  } >"$where"
}

# An installed binary, with the build info the next read will report.
install_backend() {
  local revision=$1 modified=${2:-false}
  mkdir -p "$GOBIN"
  printf '#!/bin/sh\necho old-backend\n' >"$BIN"
  chmod +x "$BIN"
  build_info "$revision" "$modified" "$STATE/go-version-out"
}

make_plist() {
  printf '<plist>stub</plist>\n' >"$PLIST"
}

# Runs the real script, keeping stdout, stderr and the exit status apart:
# which stream a line lands on is part of what is being tested.
run_sync() {
  local label=${1-$LABEL}
  SYNC_OUT=$(bash "$SYNC" "$GOBIN" "$label" 2>"$TMP/err")
  SYNC_RC=$?
  SYNC_ERR=$(cat "$TMP/err")
  CALL_LOG=$(cat "$CALLS")
}

test_already_current_builds_nothing() {
  setup
  install_backend "$REMOTE_SHA" false
  make_plist
  run_sync

  assert_eq "exits 0" 0 "$SYNC_RC"
  assert_contains "says it is already on the tip" "$SYNC_OUT" "already on main ($REMOTE_SHA)"
  assert_not_contains "clones nothing" "$CALL_LOG" "git clone"
  assert_not_contains "builds nothing" "$CALL_LOG" "go build"
  assert_contains "still checks the agent" "$SYNC_OUT" "is loaded and running"
  assert_not_contains "and leaves a running agent alone" "$CALL_LOG" "kickstart"
  teardown
}

test_stale_binary_is_rebuilt_and_the_agent_restarted() {
  setup
  install_backend "$OLD_SHA" false
  build_info "$REMOTE_SHA" false "$STATE/go-version-after"
  make_plist
  run_sync

  assert_eq "exits 0" 0 "$SYNC_RC"
  assert_contains "says what it is building" "$SYNC_OUT" "building backend at main ($REMOTE_SHA)"
  assert_contains "clones the branch shallowly" "$CALL_LOG" "clone --quiet --depth 1 --branch main"
  assert_contains "builds with the VCS stamp demanded" "$CALL_LOG" "go build -buildvcs=true"
  assert_contains "builds with cgo off" "$CALL_LOG" "go-env CGO_ENABLED=0"
  assert_contains "reports the newly installed revision" "$SYNC_OUT" "$REMOTE_SHA false"
  assert_contains "restarts the agent onto it" "$CALL_LOG" \
    "launchctl kickstart -k gui/$UID_NOW/$LABEL"
  assert_contains "and says so" "$SYNC_OUT" "restarted $LABEL"
  assert_absent "leaves no half-built binary behind" "$GOBIN/.inkwell-backend.new"
  assert_eq "cleans up its scratch clone" "" "$(ls -A "$TMPDIR")"
  teardown
}

test_binary_built_from_a_dirty_tree_is_rebuilt() {
  setup
  # The right commit, but built from a worktree with edits in it - which is
  # not the same thing as being that commit.
  install_backend "$REMOTE_SHA" true
  build_info "$REMOTE_SHA" false "$STATE/go-version-after"
  make_plist
  run_sync

  assert_eq "exits 0" 0 "$SYNC_RC"
  assert_contains "rebuilds it" "$CALL_LOG" "go build"
  assert_not_contains "rather than calling it current" "$SYNC_OUT" "nothing to build"
  teardown
}

test_unstamped_binary_is_rebuilt() {
  setup
  # Something is installed, but `go version -m` cannot say what: a
  # hand-built copy, or one built with -buildvcs=false.
  mkdir -p "$GOBIN"
  printf '#!/bin/sh\necho mystery\n' >"$BIN"
  chmod +x "$BIN"
  printf '%s: go1.26.5\n\tpath\tinkwell/backend\n' "$BIN" >"$STATE/go-version-out"
  build_info "$REMOTE_SHA" false "$STATE/go-version-after"
  make_plist
  run_sync

  assert_contains "says it has nothing it can vouch for" "$SYNC_OUT" "have: nothing installed"
  assert_contains "and rebuilds" "$CALL_LOG" "go build"
  teardown
}

test_missing_binary_is_built_and_the_agent_bootstrapped() {
  setup
  build_info "$REMOTE_SHA" false "$STATE/go-version-after"
  make_plist
  printf '1\n' >"$STATE/print-exit"
  : >"$STATE/print-out"
  run_sync

  assert_eq "exits 0" 0 "$SYNC_RC"
  assert_file "installs the binary" "$BIN"
  assert_contains "loads the agent, which was not loaded yet" "$CALL_LOG" \
    "launchctl bootstrap gui/$UID_NOW $PLIST"
  assert_contains "and says it now runs at every login" "$SYNC_OUT" "starts at every login"
  teardown
}

test_no_network_leaves_the_binary_alone_and_still_checks_the_agent() {
  setup
  install_backend "$OLD_SHA" false
  make_plist
  printf '1\n' >"$STATE/ls-remote-exit"
  printf 'fatal: unable to access\n' >"$STATE/ls-remote"
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_contains "warns on stderr" "$SYNC_ERR" "could not read main"
  assert_contains "quoting git's own reason" "$SYNC_ERR" "unable to access"
  assert_not_contains "builds nothing" "$CALL_LOG" "go build"
  assert_contains "but still checks the agent" "$SYNC_OUT" "is loaded and running"
  teardown
}

test_failed_build_keeps_the_installed_binary() {
  setup
  install_backend "$OLD_SHA" false
  make_plist
  printf '1\n' >"$STATE/build-exit"
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_contains "warns that nothing was updated" "$SYNC_ERR" "so the backend was not updated"
  assert_eq "keeps the binary that was there" "old-backend" "$(bash "$BIN")"
  assert_absent "leaves no half-built binary behind" "$GOBIN/.inkwell-backend.new"
  assert_eq "cleans up its scratch clone" "" "$(ls -A "$TMPDIR")"
  assert_not_contains "and never restarts the agent onto nothing new" "$CALL_LOG" "kickstart -k"
  teardown
}

test_failed_clone_keeps_the_installed_binary() {
  setup
  install_backend "$OLD_SHA" false
  make_plist
  printf '1\n' >"$STATE/clone-exit"
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_contains "warns about the clone" "$SYNC_ERR" "could not clone main"
  assert_not_contains "and never reaches the build" "$CALL_LOG" "go build"
  assert_eq "cleans up its scratch clone" "" "$(ls -A "$TMPDIR")"
  teardown
}

test_nothing_installed_and_a_failed_build_starts_nothing() {
  setup
  make_plist
  printf '1\n' >"$STATE/build-exit"
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_contains "says there is nothing to run" "$SYNC_ERR" "no backend installed at $BIN"
  assert_not_contains "and asks launchd for nothing" "$CALL_LOG" "launchctl"
  teardown
}

test_missing_plist_is_reported_rather_than_guessed_at() {
  setup
  install_backend "$REMOTE_SHA" false
  printf '1\n' >"$STATE/print-exit"
  : >"$STATE/print-out"
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_contains "names the file that is missing" "$SYNC_ERR" "no agent plist at $PLIST"
  assert_not_contains "and bootstraps nothing" "$CALL_LOG" "bootstrap"
  teardown
}

test_loaded_but_not_running_agent_is_started() {
  setup
  install_backend "$REMOTE_SHA" false
  make_plist
  # Loaded, with no pid - a job that exited and is waiting on its throttle,
  # or one whose binary was missing when it was asked to start.
  printf '\tstate = not running\n\tlast exit code = 1\n' >"$STATE/print-out"
  run_sync

  assert_contains "starts it" "$CALL_LOG" "launchctl kickstart gui/$UID_NOW/$LABEL"
  assert_not_contains "without killing anything" "$CALL_LOG" "kickstart -k"
  assert_contains "and says why" "$SYNC_OUT" "loaded but not running"
  teardown
}

test_launchctl_refusing_is_a_warning_not_a_failure() {
  setup
  install_backend "$OLD_SHA" false
  build_info "$REMOTE_SHA" false "$STATE/go-version-after"
  make_plist
  printf '1\n' >"$STATE/launchctl-exit"
  run_sync

  assert_eq "never fails the switch" 0 "$SYNC_RC"
  assert_file "the new binary is installed all the same" "$BIN"
  assert_contains "warns that the old one is still running" "$SYNC_ERR" \
    "still running the previous backend"
  assert_contains "and names the command to fix it by hand" "$SYNC_ERR" \
    "launchctl kickstart -k gui/$UID_NOW/$LABEL"
  teardown
}

test_without_a_label_nothing_is_started() {
  setup
  install_backend "$REMOTE_SHA" false
  run_sync ""

  assert_eq "exits 0" 0 "$SYNC_RC"
  assert_contains "says so" "$SYNC_OUT" "no launchd label passed"
  assert_not_contains "and asks launchd for nothing" "$CALL_LOG" "launchctl"
  teardown
}

test_a_tip_that_moved_mid_run_reports_what_was_built() {
  setup
  install_backend "$OLD_SHA" false
  # The clone landed on a later commit than ls-remote reported.
  printf '%s\n' "cccccccccccccccccccccccccccccccccccccccc" >"$STATE/clone-head"
  build_info "cccccccccccccccccccccccccccccccccccccccc" false "$STATE/go-version-after"
  make_plist
  run_sync

  assert_contains "says the branch moved" "$SYNC_OUT" "moved while this ran"
  assert_contains "and which commit was built" "$SYNC_OUT" \
    "building cccccccccccccccccccccccccccccccccccccccc, the tip as cloned"
  teardown
}

test_already_current_builds_nothing
test_stale_binary_is_rebuilt_and_the_agent_restarted
test_binary_built_from_a_dirty_tree_is_rebuilt
test_unstamped_binary_is_rebuilt
test_missing_binary_is_built_and_the_agent_bootstrapped
test_no_network_leaves_the_binary_alone_and_still_checks_the_agent
test_failed_build_keeps_the_installed_binary
test_failed_clone_keeps_the_installed_binary
test_nothing_installed_and_a_failed_build_starts_nothing
test_missing_plist_is_reported_rather_than_guessed_at
test_loaded_but_not_running_agent_is_started
test_launchctl_refusing_is_a_warning_not_a_failure
test_without_a_label_nothing_is_started
test_a_tip_that_moved_mid_run_reports_what_was_built

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
