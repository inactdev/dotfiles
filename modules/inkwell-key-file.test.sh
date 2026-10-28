#!/usr/bin/env bash
# Test suite for modules/inkwell-key-file.sh - the one definition of whether
# the hand-placed key file for Inkwell's backend is there and private enough
# to start the backend with, used both by the service's ExecStartPre= and by
# the activation step that warns during a switch (modules/inkwell-linux.nix).
#
# Hermetic, and it needs nothing but a scratch directory to be: every answer
# the script gives is a function of one file's existence, owner, mode and
# emptiness, so each test is that file created one particular way. Nothing
# here reads or writes a real ~/.inkwell/env, and no test needs a real
# service, systemd, or the backend itself.
#
# Two cases are deliberately exercised through the candidate-list override
# rather than by breaking the machine: no stat command at all, and a stat
# that answers something unreadable. Both must fail *closed* - a key file
# whose privacy could not be confirmed must not start the backend - and
# neither is reachable on a machine that has a working stat on PATH.
#
# The one case not covered: a key file owned by another account. Creating one
# needs root, which no test in this repository has or should ask for; the
# comparison it exercises is a string compare against $EUID.
#
# Usage: bash modules/inkwell-key-file.test.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CHECK="$SCRIPT_DIR/inkwell-key-file.sh"

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

setup() {
  # Dropped before this run's mktemp, not merely reassigned: the previous
  # test's teardown has removed the directory TMPDIR still names, and mktemp
  # honours it (the same sharp edge the other inkwell suites document).
  unset TMPDIR
  TMP=$(mktemp -d)
  HOME="$TMP/home"
  KEY_DIR="$HOME/.inkwell"
  KEY="$KEY_DIR/env"
  mkdir -p "$KEY_DIR"
  unset INKWELL_STAT_CANDIDATES
  export HOME
}

teardown() {
  rm -rf "$TMP"
}

# A key file with the given mode and contents - the shape the captain places
# by hand.
place_key() {
  local mode=$1 contents=${2-INKWELL_API_KEY=not-a-real-key}
  printf '%s\n' "$contents" >"$KEY"
  chmod "$mode" "$KEY"
}

run_check() {
  CHECK_OUT=$(bash "$CHECK" "$@" 2>"$TMP/err")
  CHECK_RC=$?
  CHECK_ERR=$(cat "$TMP/err")
}

test_a_private_key_file_is_accepted_silently() {
  setup
  place_key 600
  run_check "$KEY"

  assert_eq "exits 0" 0 "$CHECK_RC"
  assert_eq "says nothing on stdout" "" "$CHECK_OUT"
  assert_eq "and nothing on stderr - this runs before every single start" "" "$CHECK_ERR"
  teardown
}

test_read_only_for_the_owner_is_accepted_too() {
  setup
  place_key 400
  run_check "$KEY"

  assert_eq "exits 0 - a key only ever read may be read-only" 0 "$CHECK_RC"
  assert_eq "silently" "" "$CHECK_ERR"
  teardown
}

test_a_missing_key_file_is_refused_by_name() {
  setup
  run_check "$KEY"

  assert_eq "refuses" 1 "$CHECK_RC"
  assert_contains "names the file it wants" "$CHECK_ERR" "there is no key file at $KEY"
  assert_contains "says the backend was not started" "$CHECK_ERR" "was not started"
  assert_contains "names the directory to make" "$CHECK_ERR" "mkdir -p $KEY_DIR"
  assert_contains "gives the command that creates it privately" "$CHECK_ERR" \
    "install -m 600 /dev/null $KEY"
  assert_contains "and says the repository deliberately holds no key" "$CHECK_ERR" \
    "nothing in ~/.dotfiles holds it"
  teardown
}

test_a_group_readable_key_file_is_refused() {
  setup
  place_key 640
  run_check "$KEY"

  assert_eq "refuses" 1 "$CHECK_RC"
  assert_contains "names the file and its mode" "$CHECK_ERR" "$KEY is mode 0640"
  assert_contains "says why that is not good enough" "$CHECK_ERR" \
    "readable by other accounts on this machine"
  assert_contains "and names the one command that fixes it" "$CHECK_ERR" "chmod 600 $KEY"
  teardown
}

test_a_world_readable_key_file_is_refused() {
  setup
  place_key 604
  run_check "$KEY"

  assert_eq "refuses a mode with only an other-bit set" 1 "$CHECK_RC"
  assert_contains "names the mode" "$CHECK_ERR" "is mode 0604"
  teardown
}

test_a_wide_open_key_file_is_refused() {
  setup
  place_key 666
  run_check "$KEY"

  assert_eq "refuses" 1 "$CHECK_RC"
  assert_contains "names the mode" "$CHECK_ERR" "is mode 0666"
  teardown
}

test_an_empty_key_file_is_refused() {
  setup
  : >"$KEY"
  chmod 600 "$KEY"
  run_check "$KEY"

  assert_eq "refuses - a 0600 file with no key in it is not a key" 1 "$CHECK_RC"
  assert_contains "says it is empty" "$CHECK_ERR" "$KEY is empty"
  teardown
}

test_a_directory_in_place_of_the_key_file_is_refused() {
  setup
  mkdir -p "$KEY"
  run_check "$KEY"

  assert_eq "refuses" 1 "$CHECK_RC"
  assert_contains "says what it found instead" "$CHECK_ERR" "is not a regular file"
  teardown
}

test_a_symlink_to_a_private_key_file_is_accepted() {
  setup
  printf 'INKWELL_API_KEY=not-a-real-key\n' >"$TMP/elsewhere"
  chmod 600 "$TMP/elsewhere"
  ln -s "$TMP/elsewhere" "$KEY"
  run_check "$KEY"

  assert_eq "exits 0 - the mode that matters is the one it resolves to" 0 "$CHECK_RC"
  teardown
}

test_a_symlink_to_a_readable_key_file_is_refused() {
  setup
  printf 'INKWELL_API_KEY=not-a-real-key\n' >"$TMP/elsewhere"
  chmod 644 "$TMP/elsewhere"
  ln -s "$TMP/elsewhere" "$KEY"
  run_check "$KEY"

  assert_eq "refuses - a private name over a public file is still public" 1 "$CHECK_RC"
  assert_contains "names the mode it resolved to" "$CHECK_ERR" "is mode 0644"
  teardown
}

test_no_stat_anywhere_fails_closed() {
  setup
  place_key 600
  INKWELL_STAT_CANDIDATES="$TMP/nowhere/stat"
  export INKWELL_STAT_CANDIDATES
  run_check "$KEY"

  assert_eq "refuses rather than assuming the file is private" 1 "$CHECK_RC"
  assert_contains "says what it could not do" "$CHECK_ERR" "could not find a stat command"
  assert_contains "and that this is the PATH's fault, not the key file's" "$CHECK_ERR" \
    "broken PATH rather than a broken key file"
  teardown
}

test_an_unreadable_mode_fails_closed() {
  setup
  place_key 600
  # A stat that answers something that is not an octal mode - the shape of a
  # stat whose -c is not this stat's -c.
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/stat" <<'STUB'
#!/bin/sh
echo "rw-------"
STUB
  chmod +x "$TMP/bin/stat"
  INKWELL_STAT_CANDIDATES="$TMP/bin/stat"
  export INKWELL_STAT_CANDIDATES
  run_check "$KEY"

  assert_eq "refuses rather than reading it as private" 1 "$CHECK_RC"
  assert_contains "says it could not confirm the key is private" "$CHECK_ERR" \
    "could not read $KEY's owner and permissions"
  teardown
}

test_no_argument_is_a_usage_failure() {
  setup
  run_check

  assert_eq "refuses" 1 "$CHECK_RC"
  assert_contains "says how it is called" "$CHECK_ERR" "usage: inkwell-key-file"
  teardown
}

test_a_private_key_file_is_accepted_silently
test_read_only_for_the_owner_is_accepted_too
test_a_missing_key_file_is_refused_by_name
test_a_group_readable_key_file_is_refused
test_a_world_readable_key_file_is_refused
test_a_wide_open_key_file_is_refused
test_an_empty_key_file_is_refused
test_a_directory_in_place_of_the_key_file_is_refused
test_a_symlink_to_a_private_key_file_is_accepted
test_a_symlink_to_a_readable_key_file_is_refused
test_no_stat_anywhere_fails_closed
test_an_unreadable_mode_fails_closed
test_no_argument_is_a_usage_failure

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
