#!/usr/bin/env bash
# Test suite for run.sh's host-resolution logic (the home/work menu, the
# uname-based mac-vs-linux auto-detect, the work-has-no-linux-host guards)
# and its two ~/.dotfiles symlink guards: validate_dir (run.sh:4, aborts on
# an unresolvable/non-repo DIR) and link_dotfiles (run.sh:164/260, refuses
# to silently repoint an existing ~/.dotfiles - see issue #9). Sources the
# real run.sh (see the BASH_SOURCE guard at its tail) and calls its
# functions directly against a mocked `uname` on a hermetic PATH and a
# scratch marker file/HOME - never touches real Nix, Homebrew, or this
# machine's actual ~/.dotfiles. Does NOT exercise a real bootstrap; see
# work/bootstrap.test.sh for that path's coverage.
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
    # shellcheck disable=SC2153 # HOST is set by choose_host, sourced dynamically above
    echo "HOST=$HOST"
  )
}

# Runs resolve_host in a subshell against a scratch marker and reports both
# the resolved values and resolve_host's own exit status. The status matters
# on its own: run.sh is `set -e`, and cmd_bootstrap/plan/rebuild call
# resolve_host as a plain command, so a non-zero return there kills the whole
# CLI silently. Capturing it here (rather than letting the caller's `|| true`
# swallow it) is what makes that regression visible.
run_resolve_host() {
  local requested=$1
  (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by resolve_host, sourced dynamically above
    MARKER="$TMP/.dotfiles-host"
    rc=0
    resolve_host "$requested" "0" "0" || rc=$?
    echo "HOST=$HOST RESOLVED_NO_NIX=$RESOLVED_NO_NIX rc=$rc"
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
  if out=$(
    # shellcheck disable=SC1090
    source "$SCRIPT"
    # shellcheck disable=SC2030,SC2031
    PATH="$MOCK_DIR:$PATH"
    cmd_bootstrap_no_nix "work" 2>&1
  ); then code=0; else code=$?; fi
  assert_eq "explicit work + Linux exits non-zero" "1" "$code"
  assert_contains "explains no work-linux host (explicit path)" "$out" "No work-linux host is defined"
  teardown
}

test_explicit_home_linux_host_still_resolves_to_home_linux() {
  setup
  out=$(run_resolve_host "home-linux" 2>&1) || true
  assert_contains "explicit home-linux resolves cleanly" "$out" "HOST=home-linux RESOLVED_NO_NIX=0"
  assert_contains "explicit home-linux resolve_host succeeds" "$out" "rc=0"
  teardown
}

test_explicit_personal_mac_host_still_resolves_to_personal_mac() {
  setup
  out=$(run_resolve_host "personal-mac" 2>&1) || true
  assert_contains "explicit personal-mac resolves cleanly" "$out" "HOST=personal-mac RESOLVED_NO_NIX=0"
  assert_contains "explicit personal-mac resolve_host succeeds" "$out" "rc=0"
  teardown
}

test_explicit_work_host_implies_no_nix() {
  setup
  out=$(run_resolve_host "work" 2>&1) || true
  assert_contains "explicit work implies --no-nix" "$out" "HOST=work RESOLVED_NO_NIX=1"
  assert_contains "explicit work resolve_host succeeds" "$out" "rc=0"
  teardown
}

# Records the argv of every command run.sh shells out to, so the tests below
# can assert WHICH switcher a host branches to without running a real switch.
# `sudo` and `darwin-rebuild` are mocked too: on the home-linux path they must
# never be reached at all.
mock_switchers() {
  local dir=$1
  local name
  for name in nix sudo darwin-rebuild gh; do
    cat >"$dir/$name" <<MOCK
#!/bin/sh
echo "$name \$*" >>"$TMP/invoked.log"
exit 0
MOCK
    chmod +x "$dir/$name"
  done
  : >"$TMP/invoked.log"
}

# Runs one of run.sh's command functions with every switcher mocked and HOME
# pointed at scratch, so \`ln -sfn "\$DIR" ~/.dotfiles\` and any generation-link
# probe stay inside the sandbox and never touch the real machine.
run_cmd_sandboxed() {
  local fn=$1 host=$2
  mock_switchers "$MOCK_DIR"
  mkdir -p "$TMP/home"
  (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by resolve_host, sourced dynamically above
    MARKER="$TMP/.dotfiles-host"
    # shellcheck disable=SC2034 # read by resolve_host, sourced dynamically above
    no_nix=0
    # shellcheck disable=SC2034 # read by link_dotfiles, sourced dynamically above
    relink=0
    HOME="$TMP/home"
    # shellcheck disable=SC2031 # PATH is deliberately remocked per subshell
    PATH="$MOCK_DIR:$PATH"
    "$fn" "$host" >/dev/null 2>&1
  ) || true
  cat "$TMP/invoked.log"
}

test_rebuild_home_linux_uses_home_manager_not_darwin_rebuild() {
  setup
  out=$(run_cmd_sandboxed cmd_rebuild "home-linux")
  assert_contains "rebuild home-linux runs home-manager switch" "$out" "home-manager -- switch --flake"
  assert_contains "rebuild home-linux targets the home-linux flake attr" "$out" ".dotfiles#home-linux"
  case "$out" in
    *darwin-rebuild*)
      fail_count=$((fail_count + 1))
      echo "FAIL - rebuild home-linux must never invoke darwin-rebuild:"
      echo "$out"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - rebuild home-linux never invokes darwin-rebuild/sudo nix-darwin"
      ;;
  esac
  teardown
}

test_rebuild_personal_mac_still_uses_darwin_rebuild() {
  setup
  out=$(run_cmd_sandboxed cmd_rebuild "personal-mac")
  assert_contains "rebuild personal-mac still runs sudo darwin-rebuild" "$out" \
    "sudo darwin-rebuild switch --flake"
  assert_contains "rebuild personal-mac targets the personal-mac flake attr" "$out" \
    ".dotfiles#personal-mac"
  teardown
}

test_plan_home_linux_builds_the_home_manager_activation_package() {
  setup
  out=$(run_cmd_sandboxed cmd_plan "home-linux")
  assert_contains "plan home-linux builds homeConfigurations.<host>.activationPackage" "$out" \
    "homeConfigurations.home-linux.activationPackage"
  case "$out" in
    *darwinConfigurations*)
      fail_count=$((fail_count + 1))
      echo "FAIL - plan home-linux must not build a darwinConfigurations attr:"
      echo "$out"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - plan home-linux never builds a darwinConfigurations attr"
      ;;
  esac
  teardown
}

test_plan_personal_mac_still_builds_the_darwin_system() {
  setup
  out=$(run_cmd_sandboxed cmd_plan "personal-mac")
  assert_contains "plan personal-mac builds darwinConfigurations.<host>.system" "$out" \
    "darwinConfigurations.personal-mac.system"
  teardown
}

# --- validate_dir (run.sh:4) -----------------------------------------------
# DIR is computed at the top of run.sh, unconditionally, every time the file
# is sourced or run - so these tests can't just source-then-call like the
# functions above. Instead they override `cd`/`dirname` as shell functions
# *before* sourcing, forcing the same failure the issue reproduced (the
# script's own directory disappearing out from under it), and assert the
# whole invocation aborts before ~/.dotfiles is ever touched.

test_unresolvable_dir_aborts_before_any_write() {
  setup
  mkdir -p "$TMP/home"
  out=$(
    # shellcheck disable=SC2329 # shadows the cd builtin for run.sh's DIR computation, sourced below
    cd() { return 1; }
    HOME="$TMP/home"
    # shellcheck disable=SC1090
    source "$SCRIPT" 2>&1
  )
  code=$?
  assert_eq "unresolvable DIR aborts with exit 1" "1" "$code"
  assert_contains "explains DIR could not be verified" "$out" "can't verify its own directory"
  if [ -e "$TMP/home/.dotfiles" ] || [ -L "$TMP/home/.dotfiles" ]; then
    fail_count=$((fail_count + 1))
    echo "FAIL - ~/.dotfiles must not be written when DIR is unresolvable"
  else
    pass_count=$((pass_count + 1))
    echo "ok - ~/.dotfiles left untouched when DIR is unresolvable"
  fi
  teardown
}

test_dir_resolving_outside_repo_aborts_before_any_write() {
  setup
  mkdir -p "$TMP/home" "$TMP/not-the-repo"
  out=$(
    # shellcheck disable=SC2329 # shadows the dirname command for run.sh's DIR computation, sourced below
    dirname() { echo "$TMP/not-the-repo"; }
    HOME="$TMP/home"
    # shellcheck disable=SC1090
    source "$SCRIPT" 2>&1
  )
  code=$?
  assert_eq "DIR outside the repo aborts with exit 1" "1" "$code"
  assert_contains "explains DIR doesn't look like the repo" "$out" "can't verify its own directory"
  if [ -e "$TMP/home/.dotfiles" ] || [ -L "$TMP/home/.dotfiles" ]; then
    fail_count=$((fail_count + 1))
    echo "FAIL - ~/.dotfiles must not be written when DIR isn't this repo"
  else
    pass_count=$((pass_count + 1))
    echo "ok - ~/.dotfiles left untouched when DIR isn't this repo"
  fi
  teardown
}

# --- link_dotfiles (run.sh:164, run.sh:260) --------------------------------

run_link_dotfiles() {
  local target=$1 relink=$2 home=$3
  (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    HOME="$home"
    rc=0
    link_dotfiles "$target" "$relink" || rc=$?
    echo "rc=$rc"
  )
}

test_link_dotfiles_creates_when_absent() {
  setup
  mkdir -p "$TMP/home"
  out=$(run_link_dotfiles "$SCRIPT_DIR" "0" "$TMP/home" 2>&1)
  assert_contains "create: succeeds" "$out" "rc=0"
  assert_eq "create: symlink now points at target" "$SCRIPT_DIR" "$(readlink "$TMP/home/.dotfiles")"
  teardown
}

test_link_dotfiles_noop_when_already_correct() {
  setup
  mkdir -p "$TMP/home"
  ln -sfn "$SCRIPT_DIR" "$TMP/home/.dotfiles"
  out=$(run_link_dotfiles "$SCRIPT_DIR" "0" "$TMP/home" 2>&1)
  assert_eq "matching symlink is a silent no-op" "rc=0" "$out"
  teardown
}

test_link_dotfiles_refuses_when_pointing_elsewhere() {
  setup
  mkdir -p "$TMP/home" "$TMP/other-target"
  ln -sfn "$TMP/other-target" "$TMP/home/.dotfiles"
  out=$(run_link_dotfiles "$SCRIPT_DIR" "0" "$TMP/home" 2>&1)
  assert_contains "differing symlink: refused" "$out" "rc=1"
  assert_contains "differing symlink: shows current target" "$out" "current:  $TMP/other-target"
  assert_contains "differing symlink: shows proposed target" "$out" "proposed: $SCRIPT_DIR"
  assert_contains "differing symlink: points at --relink" "$out" "--relink"
  assert_eq "differing symlink: left untouched" "$TMP/other-target" "$(readlink "$TMP/home/.dotfiles")"
  teardown
}

test_link_dotfiles_refuses_on_dangling_empty_target_symlink() {
  setup
  mkdir -p "$TMP/home"
  # Reproduces the exact corrupted state from issue #9: `ln -sfn "" ~/.dotfiles`.
  ln -sfn "" "$TMP/home/.dotfiles"
  out=$(run_link_dotfiles "$SCRIPT_DIR" "0" "$TMP/home" 2>&1)
  assert_contains "dangling empty-target symlink: refused" "$out" "rc=1"
  teardown
}

test_link_dotfiles_relink_moves_it() {
  setup
  mkdir -p "$TMP/home" "$TMP/other-target"
  ln -sfn "$TMP/other-target" "$TMP/home/.dotfiles"
  out=$(run_link_dotfiles "$SCRIPT_DIR" "1" "$TMP/home" 2>&1)
  assert_contains "--relink: succeeds" "$out" "rc=0"
  assert_eq "--relink: symlink moved to target" "$SCRIPT_DIR" "$(readlink "$TMP/home/.dotfiles")"
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
test_explicit_personal_mac_host_still_resolves_to_personal_mac
test_explicit_work_host_implies_no_nix
test_rebuild_home_linux_uses_home_manager_not_darwin_rebuild
test_rebuild_personal_mac_still_uses_darwin_rebuild
test_plan_home_linux_builds_the_home_manager_activation_package
test_plan_personal_mac_still_builds_the_darwin_system
test_unresolvable_dir_aborts_before_any_write
test_dir_resolving_outside_repo_aborts_before_any_write
test_link_dotfiles_creates_when_absent
test_link_dotfiles_noop_when_already_correct
test_link_dotfiles_refuses_when_pointing_elsewhere
test_link_dotfiles_refuses_on_dangling_empty_target_symlink
test_link_dotfiles_relink_moves_it

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
