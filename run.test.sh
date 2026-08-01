#!/usr/bin/env bash
# Test suite for run.sh's host-resolution logic: the home/work menu, the
# uname-based mac-vs-linux auto-detect, and the work-has-no-linux-host
# guards. Sources the real run.sh (see the BASH_SOURCE guard at its tail)
# and calls its functions directly against a mocked `uname` on a hermetic
# PATH and a scratch marker file - never touches real Nix, Homebrew, or
# this machine's actual host choice. Does NOT exercise a real bootstrap;
# see work/bootstrap.test.sh for that path's coverage.
#
# Usage: bash run.test.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPT="$SCRIPT_DIR/run.sh"

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

mock_uname() {
  local dir=$1 platform=$2
  cat >"$dir/uname" <<MOCK
#!/bin/sh
if [ "\$1" = "-s" ]; then echo "$platform"; else /usr/bin/uname "\$@"; fi
MOCK
  chmod +x "$dir/uname"
}

setup() {
  TMP=$(mktemp -d)
  MOCK_DIR="$TMP/bin"
  mkdir -p "$MOCK_DIR"
}

teardown() {
  rm -rf "$TMP"
}

# Runs choose_host in a subshell with a mocked uname and marker file, so
# each test gets a clean HOST/RESOLVED_NO_NIX/marker without cross-test
# leakage through run.sh's globals.
run_choose_host() {
  local platform=$1 answer=$2
  mock_uname "$MOCK_DIR" "$platform"
  (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    MARKER="$TMP/.dotfiles-host"
    # shellcheck disable=SC2030
    PATH="$MOCK_DIR:$PATH"
    choose_host <<<"$answer"
    echo "HOST=$HOST"
  )
}

test_home_menu_answer_picks_personal_mac_on_darwin() {
  setup
  out=$(run_choose_host "Darwin" "1" 2>&1) || true
  assert_contains "home + Darwin -> personal-mac" "$out" "HOST=personal-mac"
  assert_eq "marker remembers personal-mac/nix" "personal-mac
nix" "$(cat "$TMP/.dotfiles-host")"
  teardown
}

test_home_menu_answer_picks_home_linux_on_linux() {
  setup
  out=$(run_choose_host "Linux" "1" 2>&1) || true
  assert_contains "home + Linux -> home-linux" "$out" "HOST=home-linux"
  assert_eq "marker remembers home-linux/nix" "home-linux
nix" "$(cat "$TMP/.dotfiles-host")"
  teardown
}

test_work_menu_answer_picks_work_on_darwin() {
  setup
  out=$(run_choose_host "Darwin" "2" 2>&1) || true
  assert_contains "work + Darwin -> work" "$out" "HOST=work"
  teardown
}

test_work_menu_answer_fails_clearly_on_linux() {
  setup
  if out=$(run_choose_host "Linux" "2" 2>&1); then code=0; else code=$?; fi
  assert_eq "work + Linux exits non-zero" "1" "$code"
  assert_contains "explains no work-linux host" "$out" "No work-linux host is defined"
  assert_contains "points at Codespaces instead" "$out" "Codespaces"
  if [ -e "$TMP/.dotfiles-host" ]; then
    fail_count=$((fail_count + 1))
    echo "FAIL - marker must not be written on a rejected work+Linux choice"
  else
    pass_count=$((pass_count + 1))
    echo "ok - marker not written on rejected work+Linux choice"
  fi
  teardown
}

test_explicit_work_host_on_linux_is_rejected_by_bootstrap_no_nix() {
  setup
  mock_uname "$MOCK_DIR" "Linux"
  out=$(
    # shellcheck disable=SC1090
    source "$SCRIPT"
    # shellcheck disable=SC2030,SC2031
    PATH="$MOCK_DIR:$PATH"
    cmd_bootstrap_no_nix "work" 2>&1
  ) || code=$?
  assert_eq "explicit work + Linux exits non-zero" "1" "${code:-0}"
  assert_contains "explains no work-linux host (explicit path)" "$out" "No work-linux host is defined"
  teardown
}

test_explicit_home_linux_host_still_resolves_to_home_linux() {
  setup
  out=$(
    # shellcheck disable=SC1090
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by resolve_host, sourced dynamically above
    MARKER="$TMP/.dotfiles-host"
    resolve_host "home-linux" "0" "0"
    echo "HOST=$HOST RESOLVED_NO_NIX=$RESOLVED_NO_NIX"
  ) || true
  assert_contains "explicit home-linux resolves cleanly" "$out" "HOST=home-linux RESOLVED_NO_NIX=0"
  teardown
}

test_no_username_hardcoded_in_run_sh() {
  hits=$(mktemp)
  if grep -RIn -e '/Users/inactdev' -e 'inactdev' "$SCRIPT" >"$hits" 2>/dev/null; then
    fail_count=$((fail_count + 1))
    echo "FAIL - run.sh hard-codes the personal username:"
    cat "$hits"
  else
    pass_count=$((pass_count + 1))
    echo "ok - no hard-coded personal username in run.sh"
  fi
  rm -f "$hits"
}

test_no_username_hardcoded_in_run_sh
test_home_menu_answer_picks_personal_mac_on_darwin
test_home_menu_answer_picks_home_linux_on_linux
test_work_menu_answer_picks_work_on_darwin
test_work_menu_answer_fails_clearly_on_linux
test_explicit_work_host_on_linux_is_rejected_by_bootstrap_no_nix
test_explicit_home_linux_host_still_resolves_to_home_linux

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
