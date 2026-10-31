#!/usr/bin/env bash
# Test suite for modules/managed-key-file.sh - the step that makes sure there
# is exactly one key file on a machine for every Fabrica and Inkwell job to
# read, placed privately by the switch and never duplicated by hand
# (inkwell#46).
#
# Hermetic, and it needs nothing but a scratch directory to be: every answer
# the script gives is a function of what is at two paths, so each test is
# those two paths created one particular way. Nothing here reads or writes a
# real ~/.fabrica/brain.env or a real ~/.inkwell/env, and no test needs a
# real service, a real switch, or a real key.
#
# The emphasis is deliberately on what must *not* happen: the fixtures below
# carry distinctive contents, and the lossless cases assert the key's bytes
# are still readable afterwards while every refusal asserts both files came
# out of the run exactly as they went in. A step that deletes the only copy
# of a key would pass a test that only checked its messages.
#
# The one case not covered: a key file owned by another account. Creating one
# needs root, which no test in this repository has or should ask for; the
# comparison it exercises is bash's own `-O`.
#
# Usage: bash modules/managed-key-file.test.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
STEP="$SCRIPT_DIR/managed-key-file.sh"

KEY_LINE='OPENROUTER_API_KEY=not-a-real-key'
OTHER_KEY_LINE='OPENROUTER_API_KEY=a-different-not-real-key'

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

assert_true() {
  local desc=$1
  shift
  if "$@"; then
    pass_count=$((pass_count + 1))
    printf 'ok - %s\n' "$desc"
  else
    fail_count=$((fail_count + 1))
    printf 'FAIL - %s\n' "$desc"
  fi
}

setup() {
  # Dropped before this run's mktemp, not merely reassigned: the previous
  # test's teardown has removed the directory TMPDIR still names, and mktemp
  # honours it (the same sharp edge the other inkwell suites document).
  unset TMPDIR
  TMP=$(mktemp -d)
  HOME="$TMP/home"
  CANON_DIR="$HOME/.fabrica"
  CANON="$CANON_DIR/brain.env"
  LINK_DIR="$HOME/.inkwell"
  LINK="$LINK_DIR/env"
  mkdir -p "$HOME"
  export HOME
}

teardown() {
  rm -rf "$TMP"
}

run_step() {
  STEP_OUT=$(bash "$STEP" "$CANON" "$LINK" 2>"$TMP/err")
  STEP_RC=$?
  STEP_ERR=$(cat "$TMP/err")
}

mode_of() { stat -c '%a' "$1" 2>/dev/null; }

# Where the symlink resolves to, which is the only question that matters
# about it - a relative link and an absolute one to the same file are the
# same answer.
resolves_to_canonical() {
  [ -L "$LINK" ] && [ "$(readlink -f "$LINK" 2>/dev/null)" = "$(readlink -f "$CANON" 2>/dev/null)" ]
}

place_file() {
  local path=$1 mode=$2 contents=${3-}
  mkdir -p "$(dirname -- "$path")"
  if [ -n "$contents" ]; then
    printf '%s\n' "$contents" >"$path"
  else
    : >"$path"
  fi
  chmod "$mode" "$path"
}

# --- a machine that has never had a key file -------------------------------

test_a_fresh_machine_gets_one_private_empty_key_file_and_the_link() {
  setup
  run_step

  assert_eq "exits 0" 0 "$STEP_RC"
  assert_true "places the canonical key file" test -f "$CANON"
  assert_eq "already private, so the key is never written into a readable file" \
    600 "$(mode_of "$CANON")"
  assert_eq "and empty - the key itself is never placed by this repository" \
    0 "$(wc -c <"$CANON")"
  assert_eq "the directory it is in is the owner's alone" 700 "$(mode_of "$CANON_DIR")"
  assert_true "the old Inkwell path is a symlink to it" resolves_to_canonical
  assert_contains "says it placed the file, by name" "$STEP_OUT" "placed $CANON"
  assert_contains "says what to put in it" "$STEP_OUT" "\$EDITOR $CANON"
  assert_contains "says the link is there so both jobs read one file" "$STEP_OUT" \
    "linked $LINK to $CANON"
  teardown
}

test_a_second_run_changes_nothing_and_says_nothing() {
  setup
  run_step
  printf '%s\n' "$KEY_LINE" >"$CANON"
  run_step

  assert_eq "exits 0" 0 "$STEP_RC"
  assert_eq "says nothing on stdout - every switch after the first is quiet" \
    "" "$STEP_OUT"
  assert_eq "and nothing on stderr" "" "$STEP_ERR"
  assert_eq "leaves the key where it is" "$KEY_LINE" "$(cat "$CANON")"
  assert_eq "leaves its mode alone" 600 "$(mode_of "$CANON")"
  assert_true "leaves the link alone" resolves_to_canonical
  teardown
}

test_an_existing_key_file_is_never_rewritten() {
  setup
  place_file "$CANON" 600 "$KEY_LINE"
  run_step

  assert_eq "the key is untouched" "$KEY_LINE" "$(cat "$CANON")"
  assert_eq "and still 600" 600 "$(mode_of "$CANON")"
  assert_true "the link is added to it" resolves_to_canonical
  teardown
}

test_a_read_only_key_file_is_left_read_only() {
  setup
  place_file "$CANON" 400 "$KEY_LINE"
  run_step

  assert_eq "0400 is private too, so nothing is changed" 400 "$(mode_of "$CANON")"
  assert_eq "silently" "" "$STEP_ERR"
  teardown
}

test_a_directory_in_the_way_of_the_canonical_file_is_refused() {
  setup
  mkdir -p "$CANON"
  run_step

  assert_eq "exits 0 - a refusal is never a failed switch" 0 "$STEP_RC"
  assert_contains "says what it is" "$STEP_ERR" "$CANON is not a regular file"
  assert_true "leaves it exactly as it was" test -d "$CANON"
  assert_true "and links nothing to it" test ! -e "$LINK"
  teardown
}

test_a_canonical_path_that_is_itself_a_symlink_is_refused_before_any_loop() {
  setup
  place_file "$LINK" 600 "$KEY_LINE"
  mkdir -p "$CANON_DIR"
  ln -s "$LINK" "$CANON"
  run_step

  assert_contains "says the canonical path is a symlink" "$STEP_ERR" \
    "$CANON is itself a symlink"
  assert_contains "and why that cannot be linked to" "$STEP_ERR" "would be a"
  assert_true "the old path is still the real file" test -f "$LINK"
  assert_eq "with the key still in it" "$KEY_LINE" "$(cat "$LINK")"
  assert_true "and the canonical path is still the link it was" test -L "$CANON"
  assert_eq "pointing where it did" "$LINK" "$(readlink "$CANON")"
  teardown
}

# --- a key file that other accounts can read -------------------------------

test_a_group_readable_key_file_is_tightened_and_said_out_loud() {
  setup
  place_file "$CANON" 640 "$KEY_LINE"
  run_step

  assert_eq "tightened to 600" 600 "$(mode_of "$CANON")"
  assert_eq "the key itself is untouched" "$KEY_LINE" "$(cat "$CANON")"
  assert_contains "names the mode it found" "$STEP_ERR" "$CANON was mode 0640"
  assert_contains "says who could read it" "$STEP_ERR" "readable by other accounts"
  assert_contains "and that the key should be treated as seen" "$STEP_ERR" "rotate it"
  teardown
}

test_a_world_readable_key_file_is_tightened_too() {
  setup
  place_file "$CANON" 644 "$KEY_LINE"
  run_step

  assert_eq "tightened to 600" 600 "$(mode_of "$CANON")"
  assert_contains "naming the mode it found" "$STEP_ERR" "mode 0644"
  teardown
}

# --- the duplicate from inkwell#46 -----------------------------------------

test_a_byte_identical_duplicate_is_removed_and_replaced_by_the_link() {
  setup
  place_file "$CANON" 600 "$KEY_LINE"
  place_file "$LINK" 600 "$KEY_LINE"
  run_step

  assert_true "the duplicate is a symlink now" resolves_to_canonical
  assert_eq "and the key is still readable through it" "$KEY_LINE" "$(cat "$LINK")"
  assert_eq "out of the one file that holds it" "$KEY_LINE" "$(cat "$CANON")"
  assert_contains "says which duplicate it removed" "$STEP_OUT" \
    "removed the duplicate key file at $LINK"
  assert_contains "and why that lost nothing" "$STEP_OUT" "byte-identical"
  teardown
}

test_a_duplicate_is_moved_in_when_the_canonical_file_does_not_exist_yet() {
  setup
  place_file "$LINK" 600 "$KEY_LINE"
  run_step

  assert_eq "the key is in the canonical file now" "$KEY_LINE" "$(cat "$CANON")"
  assert_eq "private" 600 "$(mode_of "$CANON")"
  assert_true "and the old path resolves to it" resolves_to_canonical
  assert_contains "says it moved the key rather than copying it" "$STEP_OUT" \
    "moved the key from $LINK into $CANON"
  teardown
}

test_a_duplicate_is_moved_in_when_the_canonical_file_is_empty() {
  setup
  place_file "$CANON" 600
  place_file "$LINK" 600 "$KEY_LINE"
  run_step

  assert_eq "overwriting nothing loses nothing, so the key moves in" \
    "$KEY_LINE" "$(cat "$CANON")"
  assert_true "and the old path resolves to it" resolves_to_canonical
  teardown
}

test_a_hand_made_duplicate_with_a_loose_mode_comes_in_private() {
  setup
  place_file "$LINK" 644 "$KEY_LINE"
  run_step

  assert_eq "the key moved in" "$KEY_LINE" "$(cat "$CANON")"
  assert_eq "and was tightened on the way" 600 "$(mode_of "$CANON")"
  teardown
}

test_two_different_non_empty_key_files_are_both_left_alone() {
  setup
  place_file "$CANON" 600 "$KEY_LINE"
  place_file "$LINK" 600 "$OTHER_KEY_LINE"
  run_step

  assert_eq "exits 0 - this never fails a switch" 0 "$STEP_RC"
  assert_true "the duplicate is still a real file" test -f "$LINK"
  assert_true "not a symlink" test ! -L "$LINK"
  assert_eq "with its own key still in it" "$OTHER_KEY_LINE" "$(cat "$LINK")"
  assert_eq "and the canonical file still has its own" "$KEY_LINE" "$(cat "$CANON")"
  assert_contains "names the file it refused to touch" "$STEP_ERR" \
    "$LINK holds a key of its own"
  assert_contains "says neither was touched" "$STEP_ERR" "neither file was touched"
  assert_contains "gives the command that shows the difference" "$STEP_ERR" \
    "diff $CANON $LINK"
  assert_contains "the command that drops the duplicate" "$STEP_ERR" "rm $LINK"
  assert_contains "and how to finish afterwards" "$STEP_ERR" "./run.sh rebuild"
  teardown
}

# --- whatever else is at the old path --------------------------------------

test_a_relative_symlink_that_already_resolves_correctly_is_left_as_it_is() {
  setup
  place_file "$CANON" 600 "$KEY_LINE"
  mkdir -p "$LINK_DIR"
  ln -s "../.fabrica/brain.env" "$LINK"
  run_step

  assert_eq "says nothing - resolved paths are compared, not link text" "" "$STEP_OUT"
  assert_eq "and nothing on stderr" "" "$STEP_ERR"
  assert_eq "the relative link is not rewritten" "../.fabrica/brain.env" \
    "$(readlink "$LINK")"
  teardown
}

test_a_symlink_to_a_second_copy_of_the_same_key_is_repointed() {
  setup
  place_file "$CANON" 600 "$KEY_LINE"
  place_file "$TMP/elsewhere/env" 600 "$KEY_LINE"
  mkdir -p "$LINK_DIR"
  ln -s "$TMP/elsewhere/env" "$LINK"
  run_step

  assert_true "the link points at the canonical file now" resolves_to_canonical
  assert_contains "and says so" "$STEP_OUT" "repointed $LINK at $CANON"
  assert_true "the file it used to point at is left where it is" \
    test -f "$TMP/elsewhere/env"
  teardown
}

test_a_symlink_to_a_different_key_is_refused_and_left_pointing_there() {
  setup
  place_file "$CANON" 600 "$KEY_LINE"
  place_file "$TMP/elsewhere/env" 600 "$OTHER_KEY_LINE"
  mkdir -p "$LINK_DIR"
  ln -s "$TMP/elsewhere/env" "$LINK"
  run_step

  assert_eq "the link is untouched" "$TMP/elsewhere/env" "$(readlink "$LINK")"
  assert_eq "its target keeps its own key" "$OTHER_KEY_LINE" "$(cat "$TMP/elsewhere/env")"
  assert_contains "and the refusal names both files" "$STEP_ERR" \
    "$LINK holds a key of its own"
  teardown
}

test_a_symlink_to_nothing_is_repointed() {
  setup
  place_file "$CANON" 600 "$KEY_LINE"
  mkdir -p "$LINK_DIR"
  ln -s "$TMP/gone" "$LINK"
  run_step

  assert_true "a dangling link holds nothing, so repointing it loses nothing" \
    resolves_to_canonical
  assert_contains "and says what it found" "$STEP_OUT" "was a symlink to nothing"
  teardown
}

test_a_directory_at_the_old_path_is_refused() {
  setup
  place_file "$CANON" 600 "$KEY_LINE"
  mkdir -p "$LINK"
  run_step

  assert_eq "exits 0" 0 "$STEP_RC"
  assert_true "the directory is left alone" test -d "$LINK"
  assert_contains "and named" "$STEP_ERR" "$LINK is not a regular file or a symlink"
  teardown
}

test_a_file_in_the_way_of_the_key_directory_is_refused() {
  setup
  : >"$CANON_DIR"
  run_step

  assert_eq "exits 0" 0 "$STEP_RC"
  assert_contains "names the thing in the way" "$STEP_ERR" \
    "$CANON_DIR exists and is not a directory"
  assert_true "which is left as it was" test -f "$CANON_DIR"
  teardown
}

# --- usage ------------------------------------------------------------------

test_it_refuses_to_run_without_both_paths() {
  setup
  local out rc
  out=$(bash "$STEP" "$CANON" 2>&1)
  rc=$?

  assert_eq "a missing argument is an error, not a guess" 1 "$rc"
  assert_contains "with the usage line" "$out" "usage: managed-key-file"
  teardown
}

test_a_fresh_machine_gets_one_private_empty_key_file_and_the_link
test_a_second_run_changes_nothing_and_says_nothing
test_an_existing_key_file_is_never_rewritten
test_a_read_only_key_file_is_left_read_only
test_a_directory_in_the_way_of_the_canonical_file_is_refused
test_a_canonical_path_that_is_itself_a_symlink_is_refused_before_any_loop
test_a_group_readable_key_file_is_tightened_and_said_out_loud
test_a_world_readable_key_file_is_tightened_too
test_a_byte_identical_duplicate_is_removed_and_replaced_by_the_link
test_a_duplicate_is_moved_in_when_the_canonical_file_does_not_exist_yet
test_a_duplicate_is_moved_in_when_the_canonical_file_is_empty
test_a_hand_made_duplicate_with_a_loose_mode_comes_in_private
test_two_different_non_empty_key_files_are_both_left_alone
test_a_relative_symlink_that_already_resolves_correctly_is_left_as_it_is
test_a_symlink_to_a_second_copy_of_the_same_key_is_repointed
test_a_symlink_to_a_different_key_is_refused_and_left_pointing_there
test_a_symlink_to_nothing_is_repointed
test_a_directory_at_the_old_path_is_refused
test_a_file_in_the_way_of_the_key_directory_is_refused
test_it_refuses_to_run_without_both_paths

printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
