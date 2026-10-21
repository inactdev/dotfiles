#!/usr/bin/env bash
# Test suite for modules/managed-bin-guard.sh - the shared check both sync
# scripts end with: that the copy of a managed tool a fresh login shell
# finds is the managed one, that any other copy under $HOME is moved into
# the timestamped quarantine directory, and that a copy it must not touch
# (outside $HOME, or resolving into the Nix store) is warned about and left
# exactly where it is.
#
# Hermetic in every direction. Every test runs against a scratch $HOME
# under mktemp -d, with the login shells themselves mocked: the guard
# locates `bash`/`zsh` with `command -v`, so a stub on a hermetic PATH is
# the whole substitution. Each stub reads the login PATH the test gave it
# from a fixture under its scratch $HOME (which survives the guard's
# `env -i`), then answers `command -v <tool>` by walking that PATH exactly
# as a shell would - so a quarantined copy really does change the answer
# the second time it is asked. No real bash/zsh startup file, no real
# ~/.local/bin, no network, no Nix.
#
# The last two tests run the real modules/inspector-sync.sh and
# modules/fabrica-sync.sh end to end against a `git` that cannot reach the
# network, which is the path that matters most: it proves the guard still
# runs when the sync itself gave up early and installed nothing.
#
# Usage: bash modules/managed-bin-guard.test.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
GUARD="$SCRIPT_DIR/managed-bin-guard.sh"
# Resolved before any test puts a stub `bash` on PATH: the two end-to-end
# tests have to run the sync scripts with a real bash, not with the stub
# login shell the guard is meant to find.
REAL_BASH=$(command -v bash)

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

# TMP holds the whole fixture world: the scratch HOME, the stub shells, and
# an "outside $HOME" bin directory for the copies the guard must refuse to
# move.
setup() {
  TMP=$(mktemp -d)
  HOME="$TMP/home"
  OUTSIDE="$TMP/outside/bin"
  MOCK_DIR="$TMP/mock"
  mkdir -p "$HOME" "$OUTSIDE" "$MOCK_DIR" "$HOME/.probe"
  # A hermetic PATH: the stubs first, then just enough of the real system
  # for the guard's own coreutils use (readlink, dirname, env, date, mv).
  PATH="$MOCK_DIR:/usr/bin:/bin"
  export HOME PATH
}

teardown() {
  rm -rf "$TMP"
}

# A stub login shell. It ignores -l/-i, pulls the tool name out of the
# script the guard passes to -c, and answers `command -v` by walking the
# login PATH the test declared for it - the same first-executable-wins rule
# a real shell uses, so it stays honest across the guard's second probe
# after a quarantine. Writing $HOME/.probe/<name>.override makes it answer
# that instead, for the cases a path walk cannot produce (an alias, or a
# winner in a directory the bounded scan never looks at).
mock_shell() {
  local name=$1 login_path=$2
  printf '%s\n' "$login_path" >"$HOME/.probe/$name.path"
  cat >"$MOCK_DIR/$name" <<'STUB'
#!/bin/sh
# stub login shell for managed-bin-guard.test.sh
name=${0##*/}
for arg in "$@"; do script=$arg; done
tool=$(printf '%s' "$script" | sed -n 's/.*command -v \([A-Za-z0-9._-]*\).*/\1/p')
login_path=$(cat "$HOME/.probe/$name.path")
if [ -f "$HOME/.probe/$name.override" ]; then
  found=$(cat "$HOME/.probe/$name.override")
else
  found=''
  saved_ifs=$IFS
  IFS=:
  for dir in $login_path; do
    IFS=$saved_ifs
    if [ -f "$dir/$tool" ] && [ -x "$dir/$tool" ]; then
      found=$dir/$tool
      break
    fi
    IFS=:
  done
  IFS=$saved_ifs
fi
printf '\nmbg-which=%s\n' "$found"
printf 'mbg-path=%s\n' "$login_path"
STUB
  chmod +x "$MOCK_DIR/$name"
}

mock_shell_override() {
  local name=$1 answer=$2
  printf '%s\n' "$answer" >"$HOME/.probe/$name.override"
}

# An executable standing in for a tool binary.
make_tool() {
  local path=$1 label=$2
  mkdir -p "$(dirname "$path")"
  printf '#!/bin/sh\necho %s\n' "$label" >"$path"
  chmod +x "$path"
}

# Both stub shells, with the PATH order modules/core.nix now produces:
# the managed Go bin directory ahead of ~/.local/bin.
mock_both_shells_managed_first() {
  local login_path="$HOME/go/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$OUTSIDE"
  mock_shell bash "$login_path"
  mock_shell zsh "$login_path"
}

# Runs the guard in a subshell, so each test gets its own say/warn capture
# and none of the guard's globals leak into the next one. stdout and stderr
# are returned separately: which stream a line lands on is part of what is
# being tested (the loud warnings have to be on stderr).
run_guard() {
  local tool=$1 managed=$2
  (
    set -euo pipefail
    say() { printf 'sync: %s\n' "$*"; }
    warn() { printf 'sync: %s\n' "$*" >&2; }
    # shellcheck disable=SC1090
    . "$GUARD"
    guard_managed_binary "$tool" "$managed"
    printf 'guard-rc=%s\n' "$?"
  )
}

quarantine_copy() {
  # The one timestamped directory this run created, plus the path below it.
  local relative=$1 dir
  for dir in "$HOME/.cache/dotfiles-shadowed"/*; do
    if [ -d "$dir" ]; then
      printf '%s/%s\n' "$dir" "$relative"
      return 0
    fi
  done
  printf '%s\n' "$HOME/.cache/dotfiles-shadowed/none/$relative"
}

test_managed_copy_winning_is_left_alone() {
  setup
  make_tool "$HOME/go/bin/inspector" managed
  mock_both_shells_managed_first

  out=$(run_guard inspector "$HOME/go/bin/inspector" 2>"$TMP/err")
  err=$(cat "$TMP/err")

  assert_contains "reports the guard returned 0" "$out" "guard-rc=0"
  assert_contains "names both shells in one line" "$out" "in: bash zsh."
  assert_eq "says nothing on stderr" "" "$err"
  assert_file "managed copy still there" "$HOME/go/bin/inspector"
  assert_absent "nothing was quarantined" "$HOME/.cache/dotfiles-shadowed"
  teardown
}

test_shadowing_copy_under_home_is_quarantined() {
  setup
  make_tool "$HOME/go/bin/inspector" managed
  make_tool "$HOME/.local/bin/inspector" stale
  # The PATH order of the bug this fixes: ~/.local/bin first, so the stale
  # copy is what the shell answers until it is moved out of the way.
  mock_shell bash "$HOME/.local/bin:$HOME/go/bin"
  mock_shell zsh "$HOME/.local/bin:$HOME/go/bin"

  out=$(run_guard inspector "$HOME/go/bin/inspector" 2>"$TMP/err")
  err=$(cat "$TMP/err")
  moved_to=$(quarantine_copy ".local/bin/inspector")

  assert_contains "guard still returns 0" "$out" "guard-rc=0"
  assert_contains "prints where the copy came from" "$out" "$HOME/.local/bin/inspector ->"
  assert_contains "prints where it went" "$out" "$moved_to"
  assert_absent "stale copy is gone from ~/.local/bin" "$HOME/.local/bin/inspector"
  assert_file "stale copy is recoverable from quarantine" "$moved_to"
  assert_eq "quarantined copy is the stale one, byte for byte" "stale" "$(sh "$moved_to")"
  assert_contains "re-probes and confirms both shells" "$out" "in: bash zsh."
  assert_eq "no warning once the shadow is gone" "" "$err"
  teardown
}

test_copy_outside_home_is_warned_about_not_moved() {
  setup
  make_tool "$HOME/go/bin/inspector" managed
  make_tool "$OUTSIDE/inspector" outside
  # The outside copy wins, and nothing here is allowed to touch it.
  mock_shell bash "$OUTSIDE:$HOME/go/bin"
  mock_shell zsh "$OUTSIDE:$HOME/go/bin"

  out=$(run_guard inspector "$HOME/go/bin/inspector" 2>"$TMP/err")
  err=$(cat "$TMP/err")

  assert_contains "guard still returns 0" "$out" "guard-rc=0"
  assert_contains "warns about the outside copy on stderr" "$err" \
    "another inspector is installed outside your home directory, at $OUTSIDE/inspector"
  assert_contains "says it was left alone" "$err" "left alone"
  assert_contains "warns that it still wins" "$err" "still runs $OUTSIDE/inspector for inspector"
  assert_file "outside copy was not moved" "$OUTSIDE/inspector"
  assert_absent "nothing was quarantined" "$HOME/.cache/dotfiles-shadowed"
  assert_not_contains "no shell is reported as healthy" "$out" "in: "
  teardown
}

test_symlink_to_the_managed_copy_is_not_a_shadow() {
  setup
  make_tool "$HOME/go/bin/inspector" managed
  mkdir -p "$HOME/.local/bin"
  ln -s "$HOME/go/bin/inspector" "$HOME/.local/bin/inspector"
  mock_shell bash "$HOME/.local/bin:$HOME/go/bin"
  mock_shell zsh "$HOME/.local/bin:$HOME/go/bin"

  out=$(run_guard inspector "$HOME/go/bin/inspector" 2>"$TMP/err")
  err=$(cat "$TMP/err")

  assert_contains "both shells pass through the symlink" "$out" "in: bash zsh."
  assert_eq "deliberate symlink draws no warning" "" "$err"
  assert_file "symlink left in place" "$HOME/.local/bin/inspector"
  assert_absent "nothing was quarantined" "$HOME/.cache/dotfiles-shadowed"
  teardown
}

test_copy_resolving_into_the_nix_store_is_never_moved() {
  setup
  make_tool "$HOME/go/bin/inspector" managed
  # A stand-in for ~/.nix-profile/bin/inspector: a link under $HOME whose
  # target is in the store. Moving it would corrupt a profile, and the next
  # switch would put it back anyway. The store lives in the scratch
  # directory here (MBG_STORE_PREFIX) so the rule can be proved without a
  # real /nix to point at.
  export MBG_STORE_PREFIX="$TMP/nix/store"
  make_tool "$MBG_STORE_PREFIX/fake-inspector/bin/inspector" from-the-store
  mkdir -p "$HOME/.local/bin"
  ln -s "$MBG_STORE_PREFIX/fake-inspector/bin/inspector" "$HOME/.local/bin/inspector"
  mock_shell bash "$HOME/go/bin"
  mock_shell zsh "$HOME/go/bin"

  out=$(run_guard inspector "$HOME/go/bin/inspector" 2>"$TMP/err")
  err=$(cat "$TMP/err")

  assert_contains "guard still returns 0" "$out" "guard-rc=0"
  assert_contains "warns it resolves into the store" "$err" \
    "resolves into the Nix store ($MBG_STORE_PREFIX/fake-inspector/bin/inspector)"
  assert_eq "the link is still there" "$MBG_STORE_PREFIX/fake-inspector/bin/inspector" \
    "$(readlink "$HOME/.local/bin/inspector")"
  assert_absent "nothing was quarantined" "$HOME/.cache/dotfiles-shadowed"
  unset MBG_STORE_PREFIX
  teardown
}

test_nothing_is_moved_when_the_managed_copy_is_missing() {
  setup
  # No ~/go/bin/inspector at all - today's install did not happen. The
  # stale copy may be the only inspector on the machine, so it stays.
  make_tool "$HOME/.local/bin/inspector" stale
  mock_both_shells_managed_first

  out=$(run_guard inspector "$HOME/go/bin/inspector" 2>"$TMP/err")
  err=$(cat "$TMP/err")

  assert_contains "guard still returns 0" "$out" "guard-rc=0"
  assert_contains "says the managed copy is not installed" "$err" \
    "$HOME/go/bin/inspector is not installed"
  assert_contains "says nothing was touched" "$err" "no other copy of inspector was touched"
  assert_file "the only copy there is survives" "$HOME/.local/bin/inspector"
  assert_absent "nothing was quarantined" "$HOME/.cache/dotfiles-shadowed"
  teardown
}

test_shell_that_finds_nothing_is_warned_about() {
  setup
  make_tool "$HOME/go/bin/inspector" managed
  # zsh has the managed directory on PATH; bash does not - the exact state
  # a shell switch would otherwise hide.
  mock_shell bash "$HOME/.local/bin"
  mock_shell zsh "$HOME/go/bin"

  out=$(run_guard inspector "$HOME/go/bin/inspector" 2>"$TMP/err")
  err=$(cat "$TMP/err")

  assert_contains "guard still returns 0" "$out" "guard-rc=0"
  assert_contains "warns that bash finds nothing" "$err" \
    "a fresh bash login shell finds no inspector at all"
  assert_contains "names the directory that is missing from its PATH" "$err" \
    "$HOME/go/bin/inspector is not on its login PATH"
  assert_contains "still reports zsh as healthy" "$out" "in: zsh."
  assert_not_contains "does not report bash as healthy" "$out" "bash zsh"
  teardown
}

test_alias_in_front_of_the_managed_copy_is_warned_about() {
  setup
  make_tool "$HOME/go/bin/inspector" managed
  mock_both_shells_managed_first
  mock_shell_override zsh "inspector: aliased to inspector --slow"

  out=$(run_guard inspector "$HOME/go/bin/inspector" 2>"$TMP/err")
  err=$(cat "$TMP/err")

  assert_contains "guard still returns 0" "$out" "guard-rc=0"
  assert_contains "warns the answer is not a path" "$err" "not to a path"
  assert_contains "names the alias it saw" "$err" "aliased to inspector --slow"
  assert_contains "bash is still reported as healthy" "$out" "in: bash."
  teardown
}

test_missing_shell_is_reported_and_the_other_still_checked() {
  setup
  make_tool "$HOME/go/bin/inspector" managed
  mock_both_shells_managed_first
  rm -f "$MOCK_DIR/zsh"

  out=$(run_guard inspector "$HOME/go/bin/inspector" 2>"$TMP/err")
  err=$(cat "$TMP/err")

  assert_contains "guard still returns 0" "$out" "guard-rc=0"
  assert_contains "says zsh could not be checked" "$err" "no zsh on PATH"
  assert_contains "bash was still checked" "$out" "in: bash."
  teardown
}

test_two_shadowing_copies_are_both_quarantined_without_colliding() {
  setup
  make_tool "$HOME/.npm-global/bin/fabrica" managed
  make_tool "$HOME/.local/bin/fabrica" stale-local
  make_tool "$HOME/bin/fabrica" stale-bin
  mock_shell bash "$HOME/.local/bin:$HOME/bin:$HOME/.npm-global/bin"
  mock_shell zsh "$HOME/.local/bin:$HOME/bin:$HOME/.npm-global/bin"

  out=$(run_guard fabrica "$HOME/.npm-global/bin/fabrica" 2>"$TMP/err")
  err=$(cat "$TMP/err")

  assert_absent "~/.local/bin copy moved" "$HOME/.local/bin/fabrica"
  assert_absent "~/bin copy moved" "$HOME/bin/fabrica"
  assert_eq "first copy kept its own identity" "stale-local" \
    "$(sh "$(quarantine_copy ".local/bin/fabrica")")"
  assert_eq "second copy kept its own identity" "stale-bin" \
    "$(sh "$(quarantine_copy "bin/fabrica")")"
  assert_contains "both shells confirmed afterwards" "$out" "in: bash zsh."
  assert_eq "no leftover warnings" "" "$err"
  teardown
}

test_unmovable_shadow_warns_and_still_returns_zero() {
  setup
  make_tool "$HOME/go/bin/inspector" managed
  make_tool "$HOME/.local/bin/inspector" stale
  mock_both_shells_managed_first
  # A plain file where the quarantine directory has to go: every mkdir
  # under it fails, so the move cannot happen.
  printf 'in the way\n' >"$HOME/.cache"

  out=$(run_guard inspector "$HOME/go/bin/inspector" 2>"$TMP/err")
  err=$(cat "$TMP/err")

  assert_contains "guard still returns 0" "$out" "guard-rc=0"
  assert_contains "warns it could not be moved" "$err" "could not be moved to"
  assert_contains "says what to do instead" "$err" "move or delete it by hand"
  assert_file "the shadow is still there, not half-moved" "$HOME/.local/bin/inspector"
  teardown
}

test_non_plain_tool_name_is_refused() {
  setup
  make_tool "$HOME/go/bin/inspector" managed
  mock_both_shells_managed_first

  out=$(run_guard 'inspector; rm -rf $HOME' "$HOME/go/bin/inspector" 2>"$TMP/err")
  err=$(cat "$TMP/err")

  assert_contains "guard still returns 0" "$out" "guard-rc=0"
  assert_contains "refuses the name" "$err" "is not a plain tool name"
  assert_file "scratch HOME untouched" "$HOME/go/bin/inspector"
  teardown
}

# A `git` that cannot reach the network, for the two end-to-end tests: it
# sends both sync scripts down their earliest give-up path, which is the
# one that used to skip every later step.
mock_offline_git() {
  cat >"$MOCK_DIR/git" <<'MOCK'
#!/bin/sh
echo "fatal: unable to access remote: Could not resolve host" >&2
exit 128
MOCK
  chmod +x "$MOCK_DIR/git"
}

test_inspector_sync_guards_even_when_it_installs_nothing() {
  setup
  make_tool "$HOME/go/bin/inspector" managed
  make_tool "$HOME/.local/bin/inspector" stale
  mock_both_shells_managed_first
  mock_offline_git

  rc=0
  out=$("$REAL_BASH" "$SCRIPT_DIR/inspector-sync.sh" "$HOME/go/bin" "$GUARD" 2>"$TMP/err") || rc=$?
  err=$(cat "$TMP/err")

  assert_eq "inspector-sync still exits 0" "0" "$rc"
  assert_contains "it did give up on the install" "$err" "could not read main"
  assert_contains "but the guard still ran" "$out" \
    "moved another copy of inspector out of the way"
  assert_absent "the shadow is gone" "$HOME/.local/bin/inspector"
  assert_file "quarantined copy is recoverable" "$(quarantine_copy ".local/bin/inspector")"
  teardown
}

test_fabrica_sync_guards_even_when_it_installs_nothing() {
  setup
  make_tool "$HOME/.npm-global/bin/fabrica" managed
  make_tool "$HOME/.local/bin/fabrica" stale
  mock_both_shells_managed_first
  mock_offline_git

  rc=0
  out=$("$REAL_BASH" "$SCRIPT_DIR/fabrica-sync.sh" "$HOME/.npm-global" "$GUARD" 2>"$TMP/err") || rc=$?
  err=$(cat "$TMP/err")

  assert_eq "fabrica-sync still exits 0" "0" "$rc"
  assert_contains "it did give up on the install" "$err" "could not read master"
  assert_contains "but the guard still ran" "$out" \
    "moved another copy of fabrica out of the way"
  assert_absent "the shadow is gone" "$HOME/.local/bin/fabrica"
  assert_file "quarantined copy is recoverable" "$(quarantine_copy ".local/bin/fabrica")"
  teardown
}

test_managed_copy_winning_is_left_alone
test_shadowing_copy_under_home_is_quarantined
test_copy_outside_home_is_warned_about_not_moved
test_symlink_to_the_managed_copy_is_not_a_shadow
test_copy_resolving_into_the_nix_store_is_never_moved
test_nothing_is_moved_when_the_managed_copy_is_missing
test_shell_that_finds_nothing_is_warned_about
test_alias_in_front_of_the_managed_copy_is_warned_about
test_missing_shell_is_reported_and_the_other_still_checked
test_two_shadowing_copies_are_both_quarantined_without_colliding
test_unmovable_shadow_warns_and_still_returns_zero
test_non_plain_tool_name_is_refused
test_inspector_sync_guards_even_when_it_installs_nothing
test_fabrica_sync_guards_even_when_it_installs_nothing

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
