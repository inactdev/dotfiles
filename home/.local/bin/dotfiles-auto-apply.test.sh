#!/usr/bin/env bash
# Test suite for dotfiles-auto-apply. Runs the real script against a mocked
# `git`, a mocked `./run.sh` and mocked notifiers on a fully hermetic PATH
# and a scratch $HOME - the same shape the retired herdr marker's suite
# used, and for the same reason: nothing here may reach this machine's real
# ~/.dotfiles, its real origin, or a real `./run.sh rebuild`.
#
# Which of the two behaviours the script takes is decided by the scratch
# checkout's own .dotfiles-host, exactly as on a real machine, so every
# test below declares the host it is about: `home-linux` applies, and
# `personal-mac` only announces (it has no terminal for sudo to prompt at -
# see the script's header). `setup` writes home-linux; `set_host` overrides
# it.
#
# "Fully hermetic" is stricter than that suite's PATH, deliberately. The
# mock directory is the ENTIRE PATH (even bash, which the `#!/usr/bin/env
# bash` shebang resolves through it), with each real tool the script needs
# symlinked in by name. Two things depend on that: a real `git` must be
# unreachable, so a mock that mishandles an argument cannot fall through to
# the live repository; and `command -v notify-send` must answer "no" in the
# no-notifier test, which it would not on a runner that happens to have
# libnotify installed.
#
# Not deployed: modules/desktop.nix symlinks only the script itself.
#
# Usage: bash home/.local/bin/dotfiles-auto-apply.test.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPT="$SCRIPT_DIR/dotfiles-auto-apply"

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

OLD="1111111111111111111111111111111111111111"
NEW="2222222222222222222222222222222222222222"
OTHER="3333333333333333333333333333333333333333"

# --- mocks --------------------------------------------------------------
# Every mock is driven by files under $FIXTURES, written per test:
#   head        -> `git rev-parse HEAD`
#   remote      -> `git rev-parse refs/remotes/origin/master`
#   branch      -> `git symbolic-ref --short HEAD`; "DETACHED" = it fails
#   status      -> `git status --porcelain` output (empty file = clean)
#   relation    -> how the mock answers `merge-base --is-ancestor`:
#                  behind | ahead | diverged (ignored when head = remote)
#   fetch_rc    -> exit status of `git fetch`
#   merge_rc    -> exit status of `git merge --ff-only`
#   rebuild_rc  -> exit status of the mocked ./run.sh
# and, when they exist:
#   rebuild_output     -> extra text the mocked ./run.sh prints (a real
#                         switch's own output, e.g. sudo's refusal)
#   rebuild_calls_sudo -> the mocked ./run.sh runs `sudo true`, so the
#                         sudo guard the script installs can be observed
# and they record what was asked of them:
#   git.log     -> one line per git invocation (flags stripped)
#   rebuild.log -> one line per ./run.sh invocation, with its $PWD
#   notify.log  -> one line per osascript/notify-send invocation
#   sudo.log    -> one line per sudo invocation, as sudo itself saw it

mock_git() {
  cat >"$MOCK_DIR/git" <<'MOCK'
#!/bin/sh
set -eu
[ -n "${FIXTURES:-}" ] || { echo "mock git: FIXTURES not set" >&2; exit 1; }

# The real script passes `-c key=value` before some subcommands; drop those
# so the case below sees the subcommand, and record what is left.
while [ $# -gt 0 ]; do
  case "$1" in
    -c) shift 2 ;;
    *) break ;;
  esac
done
printf '%s\n' "$*" >>"$FIXTURES/git.log"

fixture() { cat "$FIXTURES/$1"; }

case "$1" in
  fetch)
    rc=$(fixture fetch_rc)
    if [ "$rc" != 0 ]; then
      echo "mock git: fatal: could not read from remote repository" >&2
      exit "$rc"
    fi
    ;;
  symbolic-ref)
    branch=$(fixture branch)
    [ "$branch" != DETACHED ] || exit 1
    printf '%s\n' "$branch"
    ;;
  rev-parse)
    case "$2" in
      HEAD) fixture head ;;
      refs/remotes/origin/master) fixture remote ;;
      *)
        echo "mock git: unhandled rev-parse: $*" >&2
        exit 1
        ;;
    esac
    ;;
  status) fixture status ;;
  merge-base)
    # merge-base --is-ancestor <maybe-ancestor> <descendant>
    [ "$2" = "--is-ancestor" ] || { echo "mock git: unhandled merge-base: $*" >&2; exit 1; }
    head=$(fixture head)
    remote=$(fixture remote)
    case "$(fixture relation)" in
      behind) [ "$3" = "$head" ] && [ "$4" = "$remote" ] ;;
      ahead) [ "$3" = "$remote" ] && [ "$4" = "$head" ] ;;
      *) false ;;
    esac
    ;;
  merge)
    rc=$(fixture merge_rc)
    if [ "$rc" != 0 ]; then
      echo "mock git: fatal: Not possible to fast-forward, aborting." >&2
      exit "$rc"
    fi
    # A real fast-forward moves HEAD, and a second run in the same test
    # must see that.
    fixture remote >"$FIXTURES/head"
    ;;
  *)
    echo "mock git: unhandled args: $*" >&2
    exit 1
    ;;
esac
MOCK
  chmod +x "$MOCK_DIR/git"
}

# A scratch ~/.dotfiles that looks enough like this repo for the script's
# own validation (run.sh + flake.nix), with run.sh standing in for the real
# switcher. It records its $PWD because the script must always invoke it
# from the checkout root.
mock_checkout() {
  mkdir -p "$HOME/.dotfiles"
  : >"$HOME/.dotfiles/flake.nix"
  cat >"$HOME/.dotfiles/run.sh" <<'MOCK'
#!/bin/sh
set -eu
printf '%s in %s\n' "$*" "$PWD" >>"$FIXTURES/rebuild.log"
echo "mock run.sh: $* (pretending to switch)"
if [ -f "$FIXTURES/rebuild_output" ]; then
  cat "$FIXTURES/rebuild_output"
fi
# Stands in for anything inside a real switch that shells out to sudo, so
# the guard the script puts on PATH before the rebuild can be observed.
if [ -f "$FIXTURES/rebuild_calls_sudo" ]; then
  sudo true
fi
exit "$(cat "$FIXTURES/rebuild_rc")"
MOCK
  chmod +x "$HOME/.dotfiles/run.sh"
}

# The marker run.sh writes and this job reads to know which host it is on.
# Line two is run.sh's nix/no-nix flag, which the job has no use for - it is
# written anyway so the fixture is the same file shape as the real one.
set_host() {
  printf '%s\nnix\n' "$1" >"$HOME/.dotfiles/.dotfiles-host"
}

# A `sudo` that cannot do anything but record how it was called. The guard
# the script installs resolves THIS as the real sudo and execs it with -n
# prepended, which is what the sudo tests assert.
mock_sudo() {
  cat >"$MOCK_DIR/sudo" <<'MOCK'
#!/bin/sh
printf 'sudo %s\n' "$*" >>"$FIXTURES/sudo.log"
exit 0
MOCK
  chmod +x "$MOCK_DIR/sudo"
}

mock_notifier() {
  local name=$1
  cat >"$MOCK_DIR/$name" <<MOCK
#!/bin/sh
set -eu
printf '$name %s\n' "\$*" >>"\$FIXTURES/notify.log"
MOCK
  chmod +x "$MOCK_DIR/$name"
}

# Only these reach the script, by name, from the mock directory - see the
# header for why the real PATH is never on it.
link_real_tools() {
  local tool path
  for tool in bash date mkdir chmod tail mv rm cat tr tee; do
    path=$(command -v "$tool") || {
      echo "test setup: $tool not found on PATH" >&2
      exit 1
    }
    ln -sf "$path" "$MOCK_DIR/$tool"
  done
}

# --- scaffolding --------------------------------------------------------
# Defaults describe the ordinary interesting case - a clean master that
# origin/master has moved ahead of - so each test overrides only the
# fixture it is about.
setup() {
  TMP=$(mktemp -d)
  export HOME="$TMP/home"
  export FIXTURES="$TMP/fixtures"
  MOCK_DIR="$TMP/bin"
  STATE_DIR="$HOME/.local/state/dotfiles-auto"
  LOG="$STATE_DIR/apply.log"
  APPLIED="$STATE_DIR/last-applied"
  ANNOUNCED="$STATE_DIR/last-announced"
  mkdir -p "$HOME" "$FIXTURES" "$MOCK_DIR"

  link_real_tools
  mock_git
  mock_checkout
  # The applying host, so every test that is not about the split reads as
  # it did before there was one.
  set_host home-linux

  printf '%s\n' "$OLD" >"$FIXTURES/head"
  printf '%s\n' "$NEW" >"$FIXTURES/remote"
  printf 'master\n' >"$FIXTURES/branch"
  printf 'behind\n' >"$FIXTURES/relation"
  : >"$FIXTURES/status"
  printf '0\n' >"$FIXTURES/fetch_rc"
  printf '0\n' >"$FIXTURES/merge_rc"
  printf '0\n' >"$FIXTURES/rebuild_rc"
  : >"$FIXTURES/git.log"
  : >"$FIXTURES/rebuild.log"
  : >"$FIXTURES/notify.log"
  : >"$FIXTURES/sudo.log"
}

teardown() {
  rm -rf "$TMP"
}

# Records this run's exit status in $rc and its stdout+stderr in $out.
# NIX_REMOTE is pre-set to what both Nix hosts really run with, which is
# also what makes the script skip sourcing /nix/.../nix-daemon.sh: that is
# the one file it would otherwise read from outside this temp directory on
# a machine that has Nix installed.
run_apply() {
  out=$(PATH="$MOCK_DIR" HOME="$HOME" FIXTURES="$FIXTURES" NIX_REMOTE=daemon "$SCRIPT" 2>&1)
  rc=$?
}

git_log() { cat "$FIXTURES/git.log"; }
rebuild_log() { cat "$FIXTURES/rebuild.log"; }
notify_log() { cat "$FIXTURES/notify.log"; }
sudo_log() { cat "$FIXTURES/sudo.log"; }
log_file() { cat "$LOG" 2>/dev/null; }
applied() { cat "$APPLIED" 2>/dev/null; }
announced() { cat "$ANNOUNCED" 2>/dev/null; }

# How many times a notification was raised - the difference between "told
# once" and "told every half hour" is the whole point of several tests.
# Every notifier mock writes exactly one line per invocation.
notify_count() { wc -l <"$FIXTURES/notify.log" | tr -d ' '; }

# Most tests want a machine that has already applied something, so the
# first-run shortcut is not what they are measuring.
seed_applied() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" >"$APPLIED"
}

# --- tests --------------------------------------------------------------

test_moved_and_clean_fast_forwards_and_rebuilds() {
  setup
  seed_applied "$OLD"
  run_apply
  assert_eq "moved+clean: exits 0" "0" "$rc"
  assert_contains "moved+clean: fetches origin master" "$(git_log)" "fetch --quiet origin master"
  assert_contains "moved+clean: fast-forwards to the remote ref" "$(git_log)" "merge --ff-only refs/remotes/origin/master"
  assert_eq "moved+clean: rebuilds once, from the checkout root" \
    "rebuild in $HOME/.dotfiles" "$(rebuild_log)"
  assert_contains "moved+clean: logs the fast-forward" "$(log_file)" "fast-forwarded master from 111111111111 to 222222222222"
  assert_contains "moved+clean: logs the apply" "$(log_file)" "applied 222222222222."
  assert_contains "moved+clean: the switch's own output is in the log too" "$(log_file)" "mock run.sh: rebuild"
  assert_eq "moved+clean: records the applied commit" "$NEW" "$(applied)"
  assert_eq "moved+clean: notifies nobody" "" "$(notify_log)"
  teardown
}

test_dirty_checkout_is_never_touched() {
  setup
  seed_applied "$OLD"
  mock_notifier notify-send
  printf ' M modules/core.nix\n?? scratch.txt\n' >"$FIXTURES/status"
  run_apply
  assert_eq "dirty: exits 0 (a work-in-progress checkout is not a failure)" "0" "$rc"
  assert_not_contains "dirty: never merges" "$(git_log)" "merge --ff-only"
  assert_eq "dirty: never rebuilds" "" "$(rebuild_log)"
  assert_contains "dirty: says what is in the way" "$(log_file)" "M modules/core.nix"
  assert_contains "dirty: names the untracked file too" "$(log_file)" "?? scratch.txt"
  assert_contains "dirty: says what it would have applied" "$(log_file)" "origin/master is at 222222222222"
  assert_eq "dirty: leaves the recorded commit alone" "$OLD" "$(applied)"
  assert_contains "dirty: never silent - the checkout needs a hand" "$(notify_log)" "uncommitted changes"
  assert_eq "dirty: notified once" "1" "$(notify_count)"

  # The same uncommitted edit half an hour later is the same occurrence:
  # logged again, not notified again.
  run_apply
  assert_eq "dirty: second run still exits 0" "0" "$rc"
  assert_eq "dirty: second run raises no second notification" "1" "$(notify_count)"
  assert_contains "dirty: second run still logs what is in the way" "$out" "M modules/core.nix"

  # Once it is out of the way the next blocked fetch is a new occurrence,
  # so it is notified about again rather than swallowed forever.
  : >"$FIXTURES/status"
  run_apply
  assert_eq "dirty: cleaning up lets the fast-forward happen" "0" "$rc"
  printf '%s\n' "$OTHER" >"$FIXTURES/remote"
  printf ' M modules/core.nix\n' >"$FIXTURES/status"
  run_apply
  assert_eq "dirty: a fresh occurrence notifies again" "2" "$(notify_count)"
  teardown
}

test_dirty_checkout_with_nothing_to_do_is_quiet() {
  setup
  seed_applied "$OLD"
  printf ' M modules/core.nix\n' >"$FIXTURES/status"
  printf '%s\n' "$OLD" >"$FIXTURES/remote"
  run_apply
  assert_eq "dirty+current: exits 0" "0" "$rc"
  assert_contains "dirty+current: logs nothing to apply" "$(log_file)" "nothing to apply"
  assert_eq "dirty+current: never rebuilds" "" "$(rebuild_log)"
  teardown
}

test_nothing_moved_does_nothing() {
  setup
  seed_applied "$OLD"
  printf '%s\n' "$OLD" >"$FIXTURES/remote"
  run_apply
  assert_eq "unmoved: exits 0" "0" "$rc"
  assert_contains "unmoved: still fetches" "$(git_log)" "fetch"
  assert_not_contains "unmoved: never merges" "$(git_log)" "merge --ff-only"
  assert_eq "unmoved: never rebuilds" "" "$(rebuild_log)"
  assert_contains "unmoved: logs that it is current" "$(log_file)" "already applied 111111111111"
  teardown
}

test_fetch_failure_is_logged_not_notified() {
  setup
  seed_applied "$OLD"
  printf '128\n' >"$FIXTURES/fetch_rc"
  run_apply
  assert_eq "fetch failure: exits non-zero" "1" "$rc"
  assert_not_contains "fetch failure: never merges" "$(git_log)" "merge --ff-only"
  assert_eq "fetch failure: never rebuilds" "" "$(rebuild_log)"
  assert_contains "fetch failure: logs why" "$(log_file)" "could not fetch master from origin"
  assert_contains "fetch failure: logs what git said" "$(log_file)" "could not read from remote repository"
  assert_eq "fetch failure: notifies nobody (network trouble needs no human)" "" "$(notify_log)"
  teardown
}

test_divergence_notifies_and_touches_nothing() {
  setup
  seed_applied "$OLD"
  mock_notifier notify-send
  printf 'diverged\n' >"$FIXTURES/relation"
  printf '%s\n' "$OTHER" >"$FIXTURES/remote"
  run_apply
  assert_eq "diverged: exits non-zero" "1" "$rc"
  assert_not_contains "diverged: never merges" "$(git_log)" "merge --ff-only"
  assert_eq "diverged: never rebuilds" "" "$(rebuild_log)"
  assert_contains "diverged: logs both commits" "$(log_file)" "share no descent"
  assert_contains "diverged: notifies, because only a human can fix it" "$(notify_log)" "notify-send"
  assert_contains "diverged: the notification says what happened" "$(notify_log)" "diverged"
  assert_eq "diverged: leaves the recorded commit alone" "$OLD" "$(applied)"
  assert_eq "diverged: notified once" "1" "$(notify_count)"

  run_apply
  assert_eq "diverged: second run still exits non-zero" "1" "$rc"
  assert_eq "diverged: second run raises no second notification" "1" "$(notify_count)"
  assert_contains "diverged: second run still logs it" "$out" "share no descent"
  teardown
}

test_local_ahead_notifies_once_and_exits_zero() {
  setup
  seed_applied "$OLD"
  mock_notifier notify-send
  printf 'ahead\n' >"$FIXTURES/relation"
  printf '%s\n' "$OTHER" >"$FIXTURES/remote"
  run_apply
  assert_eq "ahead: exits 0 (an unpushed commit is not a failure)" "0" "$rc"
  assert_not_contains "ahead: never merges" "$(git_log)" "merge --ff-only"
  assert_eq "ahead: never rebuilds" "" "$(rebuild_log)"
  assert_contains "ahead: logs that there is nothing to fast-forward" "$(log_file)" "nothing to fast-forward"
  assert_contains "ahead: says a fetch it could not act on, out loud" "$(notify_log)" "not on origin/master"
  assert_eq "ahead: once, not once per run" "1" "$(notify_count)"

  # Same situation 30 minutes later: the log still records it, the human is
  # not interrupted a second time.
  run_apply
  assert_eq "ahead: second run still exits 0" "0" "$rc"
  assert_eq "ahead: second run raises no second notification" "1" "$(notify_count)"
  assert_contains "ahead: second run says why it stayed quiet" "$out" "already notified about this"
  teardown
}

test_local_commit_on_master_is_applied_too() {
  setup
  # The record, not the fetch, is what decides a rebuild is due: a commit
  # made straight on local master (or a `git pull` somebody never applied)
  # leaves the machine behind just as much as a failed rebuild does, so it
  # is picked up even though nothing came in from origin.
  seed_applied "$OLD"
  printf 'ahead\n' >"$FIXTURES/relation"
  printf '%s\n' "$NEW" >"$FIXTURES/head"
  printf '%s\n' "$OLD" >"$FIXTURES/remote"
  run_apply
  assert_eq "local commit: exits 0" "0" "$rc"
  assert_not_contains "local commit: nothing to merge" "$(git_log)" "merge --ff-only"
  assert_eq "local commit: applies it" "rebuild in $HOME/.dotfiles" "$(rebuild_log)"
  assert_eq "local commit: records it" "$NEW" "$(applied)"
  teardown
}

# --- which host this machine is -----------------------------------------

test_missing_host_marker_refuses_before_fetching() {
  setup
  mock_notifier notify-send
  rm -f "$HOME/.dotfiles/.dotfiles-host"
  run_apply
  assert_eq "no marker: exits non-zero" "1" "$rc"
  assert_eq "no marker: never runs git at all" "" "$(git_log)"
  assert_eq "no marker: never rebuilds" "" "$(rebuild_log)"
  assert_contains "no marker: names the file it wanted" "$(log_file)" ".dotfiles-host"
  assert_contains "no marker: says it will not guess what run.sh would not" "$(log_file)" "will not"
  assert_contains "no marker: says how to record it" "$(log_file)" "./run.sh choose"
  teardown
}

test_unknown_host_marker_refuses_before_fetching() {
  setup
  set_host "some-other-box"
  run_apply
  assert_eq "unknown host: exits non-zero" "1" "$rc"
  assert_eq "unknown host: never runs git at all" "" "$(git_log)"
  assert_eq "unknown host: never rebuilds" "" "$(rebuild_log)"
  assert_contains "unknown host: names the host it found" "$(log_file)" "some-other-box"
  assert_contains "unknown host: names the file" "$(log_file)" ".dotfiles-host"
  teardown
}

test_work_host_marker_refuses_before_fetching() {
  setup
  set_host "work"
  run_apply
  assert_eq "work host: exits non-zero" "1" "$rc"
  assert_eq "work host: never runs git at all" "" "$(git_log)"
  assert_eq "work host: never rebuilds" "" "$(rebuild_log)"
  assert_contains "work host: says why there is nothing to schedule" "$(log_file)" "no Nix switch"
  teardown
}

test_host_marker_trailing_whitespace_is_not_a_different_host() {
  setup
  seed_applied "$OLD"
  printf 'personal-mac \r\nnix\n' >"$HOME/.dotfiles/.dotfiles-host"
  run_apply
  assert_eq "whitespace in the marker: still a known host" "0" "$rc"
  assert_contains "whitespace in the marker: announces" "$(log_file)" "an update is ready"
  teardown
}

# --- personal-mac: announce, never switch -------------------------------

test_personal_mac_announces_and_never_rebuilds() {
  setup
  set_host personal-mac
  seed_applied "$OLD"
  mock_notifier osascript
  run_apply
  assert_eq "mac: exits 0" "0" "$rc"
  assert_contains "mac: still fast-forwards the checkout" "$(git_log)" "merge --ff-only refs/remotes/origin/master"
  assert_eq "mac: never runs ./run.sh, so sudo is never reached" "" "$(rebuild_log)"
  assert_eq "mac: never runs sudo" "" "$(sudo_log)"
  assert_contains "mac: logs that an update is ready" "$(log_file)" "an update is ready"
  assert_contains "mac: logs the commit" "$(log_file)" "222222222222"
  assert_contains "mac: logs the one command to run" "$(log_file)" "cd ~/.dotfiles && ./run.sh rebuild"
  assert_contains "mac: notifies through osascript" "$(notify_log)" "display notification"
  assert_contains "mac: the notification carries the same command" "$(notify_log)" "cd ~/.dotfiles && ./run.sh rebuild"
  assert_contains "mac: the notification is titled" "$(notify_log)" "dotfiles update ready"
  assert_eq "mac: does NOT claim the update was applied" "$OLD" "$(applied)"
  assert_eq "mac: records which commit it announced" "$NEW" "$(announced)"
  teardown
}

test_personal_mac_notifies_once_per_upstream_commit() {
  setup
  set_host personal-mac
  seed_applied "$OLD"
  mock_notifier osascript
  run_apply
  assert_eq "mac: one notification for the first sighting" "1" "$(notify_count)"

  # Nothing new upstream, nothing applied yet: the log keeps the record on
  # every run, the human is interrupted once.
  run_apply
  assert_eq "mac: second run exits 0" "0" "$rc"
  assert_contains "mac: second run logs the reminder again" "$out" "an update is ready"
  assert_contains "mac: second run logs the command again" "$out" "cd ~/.dotfiles && ./run.sh rebuild"
  assert_eq "mac: second run raises no second notification" "1" "$(notify_count)"
  assert_contains "mac: second run says why it stayed quiet" "$out" "no second notification"
  assert_eq "mac: still never rebuilds" "" "$(rebuild_log)"

  # Master moves again: that is a new commit, so it is announced again.
  printf 'behind\n' >"$FIXTURES/relation"
  printf '%s\n' "$OTHER" >"$FIXTURES/remote"
  run_apply
  assert_eq "mac: a newer commit notifies again" "2" "$(notify_count)"
  assert_eq "mac: and records the newer commit" "$OTHER" "$(announced)"
  teardown
}

test_personal_mac_goes_quiet_once_the_rebuild_was_run() {
  setup
  set_host personal-mac
  seed_applied "$OLD"
  mock_notifier osascript
  run_apply
  assert_contains "mac: announced" "$(log_file)" "an update is ready"

  # What `./run.sh rebuild` itself records when a human finally runs it.
  seed_applied "$NEW"
  run_apply
  assert_eq "mac: exits 0 once the update was applied" "0" "$rc"
  assert_contains "mac: and says there is nothing to do" "$out" "already applied 222222222222"
  assert_not_contains "mac: the reminder stops" "$out" "an update is ready"
  assert_eq "mac: with no further notification" "1" "$(notify_count)"
  teardown
}

test_personal_mac_first_run_announces_nothing() {
  setup
  set_host personal-mac
  mock_notifier osascript
  printf '%s\n' "$OLD" >"$FIXTURES/remote"
  run_apply
  assert_eq "mac first run: exits 0" "0" "$rc"
  assert_eq "mac first run: installing the timer notifies nobody" "" "$(notify_log)"
  assert_eq "mac first run: records where the machine stands" "$OLD" "$(applied)"
  assert_contains "mac first run: says what it did" "$(log_file)" "first run on this machine"
  teardown
}

test_personal_mac_dirty_checkout_is_not_announced() {
  setup
  set_host personal-mac
  seed_applied "$OLD"
  mock_notifier osascript
  printf ' M modules/core.nix\n' >"$FIXTURES/status"
  run_apply
  assert_eq "mac dirty: exits 0" "0" "$rc"
  assert_not_contains "mac dirty: never merges" "$(git_log)" "merge --ff-only"
  assert_not_contains "mac dirty: announces nothing it did not fast-forward to" "$(log_file)" "an update is ready"
  assert_contains "mac dirty: says the checkout needs a hand instead" "$(notify_log)" "uncommitted changes"
  assert_eq "mac dirty: announced nothing" "" "$(announced)"
  teardown
}

# --- no password, ever --------------------------------------------------

test_sudo_is_never_allowed_to_prompt() {
  setup
  seed_applied "$OLD"
  mock_sudo
  : >"$FIXTURES/rebuild_calls_sudo"
  run_apply
  assert_eq "sudo guard: the rebuild still succeeds" "0" "$rc"
  assert_contains "sudo guard: sudo was reached" "$(sudo_log)" "sudo"
  assert_contains "sudo guard: and could not prompt (-n)" "$(sudo_log)" "sudo -n"
  teardown
}

test_a_sudo_password_prompt_is_called_out_in_the_log() {
  setup
  seed_applied "$OLD"
  mock_notifier notify-send
  printf '1\n' >"$FIXTURES/rebuild_rc"
  printf 'sudo: a terminal is required to read the password\n' >"$FIXTURES/rebuild_output"
  run_apply
  assert_eq "sudo failure: exits non-zero" "1" "$rc"
  assert_contains "sudo failure: the switch's own message is in the log" "$(log_file)" \
    "a terminal is required to read the password"
  assert_contains "sudo failure: and is explained rather than left raw" "$(log_file)" \
    "no terminal to answer"
  assert_contains "sudo failure: names the command to run by hand" "$(log_file)" \
    "cd ~/.dotfiles && ./run.sh rebuild"
  assert_eq "sudo failure: does NOT record the commit as applied" "$OLD" "$(applied)"
  teardown
}

test_an_ordinary_rebuild_failure_is_not_blamed_on_sudo() {
  setup
  seed_applied "$OLD"
  printf '1\n' >"$FIXTURES/rebuild_rc"
  printf 'error: builder for /nix/store/... failed with exit code 1\n' >"$FIXTURES/rebuild_output"
  run_apply
  assert_eq "other failure: exits non-zero" "1" "$rc"
  assert_contains "other failure: logs the failure" "$(log_file)" "./run.sh rebuild failed"
  assert_not_contains "other failure: says nothing about terminals" "$(log_file)" "no terminal to answer"
  teardown
}

test_rebuild_failure_notifies_and_is_retried() {
  setup
  seed_applied "$OLD"
  mock_notifier osascript
  printf '1\n' >"$FIXTURES/rebuild_rc"
  run_apply
  assert_eq "rebuild failure: exits non-zero" "1" "$rc"
  assert_contains "rebuild failure: logs it" "$(log_file)" "./run.sh rebuild failed"
  assert_contains "rebuild failure: notifies through osascript" "$(notify_log)" "display notification"
  assert_contains "rebuild failure: the notification names the log" "$(notify_log)" "apply.log"
  assert_eq "rebuild failure: does NOT record the commit as applied" "$OLD" "$(applied)"

  # The fast-forward already happened, so nothing new is fetched on the next
  # run - the recorded commit is the only thing that knows a rebuild is
  # still owed. This is the regression that makes the record worth keeping.
  : >"$FIXTURES/rebuild.log"
  printf 'behind\n' >"$FIXTURES/relation"
  printf '0\n' >"$FIXTURES/rebuild_rc"
  run_apply
  assert_eq "rebuild failure: the next run retries it" "0" "$rc"
  assert_eq "rebuild failure: retry rebuilds once" \
    "rebuild in $HOME/.dotfiles" "$(rebuild_log)"
  assert_eq "rebuild failure: retry records the commit" "$NEW" "$(applied)"
  teardown
}

test_osascript_wins_over_notify_send_where_both_exist() {
  setup
  seed_applied "$OLD"
  mock_notifier osascript
  mock_notifier notify-send
  printf '1\n' >"$FIXTURES/rebuild_rc"
  run_apply
  # A Mac has both once anything brings notify-send in; the AppleScript
  # route is the native one there, and only one notification should fire.
  assert_contains "both notifiers: osascript is used" "$(notify_log)" "osascript -e display notification"
  assert_not_contains "both notifiers: notify-send is not also used" "$(notify_log)" "notify-send"
  assert_contains "both notifiers: the notification is titled" "$(notify_log)" "with title"
  teardown
}

test_no_notifier_still_logs_and_fails() {
  setup
  seed_applied "$OLD"
  printf '1\n' >"$FIXTURES/rebuild_rc"
  run_apply
  assert_eq "headless: still exits non-zero" "1" "$rc"
  assert_contains "headless: records that there was nobody to notify" \
    "$(log_file)" "no desktop notifier on this machine"
  assert_contains "headless: the failure itself is still logged" "$(log_file)" "rebuild failed"
  teardown
}

test_non_master_branch_is_left_alone() {
  setup
  seed_applied "$OLD"
  printf 'fabrica/some-task\n' >"$FIXTURES/branch"
  run_apply
  assert_eq "topic branch: exits 0" "0" "$rc"
  assert_not_contains "topic branch: never even fetches" "$(git_log)" "fetch"
  assert_eq "topic branch: never rebuilds" "" "$(rebuild_log)"
  assert_contains "topic branch: says which branch it found" "$(log_file)" "on 'fabrica/some-task', not master"
  teardown
}

test_detached_head_is_left_alone() {
  setup
  seed_applied "$OLD"
  printf 'DETACHED\n' >"$FIXTURES/branch"
  run_apply
  assert_eq "detached: exits 0" "0" "$rc"
  assert_eq "detached: never rebuilds" "" "$(rebuild_log)"
  assert_contains "detached: says so" "$(log_file)" "a detached HEAD"
  teardown
}

test_failed_fast_forward_stops_before_the_rebuild() {
  setup
  seed_applied "$OLD"
  printf '1\n' >"$FIXTURES/merge_rc"
  run_apply
  assert_eq "ff failure: exits non-zero" "1" "$rc"
  assert_eq "ff failure: never rebuilds" "" "$(rebuild_log)"
  assert_contains "ff failure: logs what git said" "$(log_file)" "Not possible to fast-forward"
  assert_eq "ff failure: leaves the recorded commit alone" "$OLD" "$(applied)"
  teardown
}

test_first_run_with_nothing_new_records_without_rebuilding() {
  setup
  printf '%s\n' "$OLD" >"$FIXTURES/remote"
  run_apply
  assert_eq "first run: exits 0" "0" "$rc"
  assert_eq "first run: installing the timer does not trigger a switch" "" "$(rebuild_log)"
  assert_eq "first run: records where the machine stands" "$OLD" "$(applied)"
  assert_contains "first run: says what it did" "$(log_file)" "first run on this machine"
  teardown
}

test_first_run_with_something_to_apply_does_apply_it() {
  setup
  run_apply
  assert_eq "first run behind: exits 0" "0" "$rc"
  assert_contains "first run behind: fast-forwards" "$(git_log)" "merge --ff-only"
  assert_eq "first run behind: rebuilds" "rebuild in $HOME/.dotfiles" "$(rebuild_log)"
  assert_contains "first run behind: says nothing was applied before" "$(log_file)" "nothing applied on this machine yet"
  assert_eq "first run behind: records it" "$NEW" "$(applied)"
  teardown
}

test_missing_checkout_refuses() {
  setup
  rm -rf "$HOME/.dotfiles"
  run_apply
  assert_eq "no checkout: exits non-zero" "1" "$rc"
  assert_eq "no checkout: never runs git" "" "$(git_log)"
  assert_contains "no checkout: points at bootstrap" "$(log_file)" "./run.sh bootstrap"
  teardown
}

test_checkout_that_is_not_this_repo_refuses() {
  setup
  rm -f "$HOME/.dotfiles/flake.nix"
  run_apply
  assert_eq "wrong checkout: exits non-zero" "1" "$rc"
  assert_eq "wrong checkout: never runs git" "" "$(git_log)"
  assert_contains "wrong checkout: says what is missing" "$(log_file)" "no run.sh/flake.nix"
  teardown
}

test_log_is_trimmed_to_the_last_lines() {
  setup
  seed_applied "$OLD"
  printf '%s\n' "$OLD" >"$FIXTURES/remote"
  mkdir -p "$STATE_DIR"
  # 2500 lines of history, so this run's own lines plus the trim have to
  # bring it back under the cap.
  i=0
  while [ "$i" -lt 2500 ]; do
    printf 'old line %s\n' "$i" >>"$LOG"
    i=$((i + 1))
  done
  run_apply
  assert_eq "trim: exits 0" "0" "$rc"
  assert_eq "trim: log is capped at 2000 lines" "2000" "$(wc -l <"$LOG" | tr -d ' ')"
  assert_contains "trim: this run's lines survive" "$(log_file)" "already applied 111111111111"
  assert_not_contains "trim: the oldest lines are gone" "$(log_file)" "old line 0"
  teardown
}

test_log_is_trimmed_even_when_the_run_fails() {
  setup
  seed_applied "$OLD"
  printf '128\n' >"$FIXTURES/fetch_rc"
  mkdir -p "$STATE_DIR"
  i=0
  while [ "$i" -lt 2100 ]; do
    printf 'old line %s\n' "$i" >>"$LOG"
    i=$((i + 1))
  done
  run_apply
  assert_eq "trim on failure: still exits non-zero" "1" "$rc"
  assert_eq "trim on failure: log is still capped" "2000" "$(wc -l <"$LOG" | tr -d ' ')"
  assert_contains "trim on failure: the failure line survives the trim" "$(log_file)" "could not fetch"
  teardown
}

test_every_line_goes_to_stdout_as_well() {
  setup
  seed_applied "$OLD"
  printf '%s\n' "$OLD" >"$FIXTURES/remote"
  run_apply
  # The scheduler captures stdout (launchd's StandardOutPath, journald on
  # Linux), which is the only record on a box whose state dir is lost.
  assert_contains "stdout: carries the same lines as the log" "$out" "already applied 111111111111"
  teardown
}

test_moved_and_clean_fast_forwards_and_rebuilds
test_dirty_checkout_is_never_touched
test_dirty_checkout_with_nothing_to_do_is_quiet
test_nothing_moved_does_nothing
test_fetch_failure_is_logged_not_notified
test_divergence_notifies_and_touches_nothing
test_local_ahead_notifies_once_and_exits_zero
test_local_commit_on_master_is_applied_too
test_missing_host_marker_refuses_before_fetching
test_unknown_host_marker_refuses_before_fetching
test_work_host_marker_refuses_before_fetching
test_host_marker_trailing_whitespace_is_not_a_different_host
test_personal_mac_announces_and_never_rebuilds
test_personal_mac_notifies_once_per_upstream_commit
test_personal_mac_goes_quiet_once_the_rebuild_was_run
test_personal_mac_first_run_announces_nothing
test_personal_mac_dirty_checkout_is_not_announced
test_sudo_is_never_allowed_to_prompt
test_a_sudo_password_prompt_is_called_out_in_the_log
test_an_ordinary_rebuild_failure_is_not_blamed_on_sudo
test_rebuild_failure_notifies_and_is_retried
test_osascript_wins_over_notify_send_where_both_exist
test_no_notifier_still_logs_and_fails
test_non_master_branch_is_left_alone
test_detached_head_is_left_alone
test_failed_fast_forward_stops_before_the_rebuild
test_first_run_with_nothing_new_records_without_rebuilding
test_first_run_with_something_to_apply_does_apply_it
test_missing_checkout_refuses
test_checkout_that_is_not_this_repo_refuses
test_log_is_trimmed_to_the_last_lines
test_log_is_trimmed_even_when_the_run_fails
test_every_line_goes_to_stdout_as_well

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
