#!/usr/bin/env bash
# Test suite for run.sh's host-resolution logic (the home/work menu, the
# uname-based mac-vs-linux auto-detect, the work-has-no-linux-host guards,
# and what gets written to the remembered-host marker - including from an
# explicitly named host, which is remembered exactly like a menu answer),
# its switcher command lines (which host branches to home-manager vs.
# darwin-rebuild, and that the home-linux branch carries `-b hm-backup`
# ahead of `switch`), and its two ~/.dotfiles symlink guards: validate_dir
# (near the top of run.sh, aborts on an unresolvable/non-repo DIR) and
# link_dotfiles (refuses to silently repoint an existing ~/.dotfiles - see
# issue #9). Sources the real run.sh (see the BASH_SOURCE guard at its
# tail) and calls its functions directly against a mocked `uname` on a
# hermetic PATH and a scratch marker file/HOME - never touches real Nix,
# Homebrew, this machine's actual ~/.dotfiles, or the remembered host of
# the checkout it is run from (see run_script_sandboxed). Does NOT exercise
# a real bootstrap; see work/bootstrap.test.sh for that path's coverage.
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
#
# $2, when given, mocks `uname -s`: resolve_host consults it to decide
# whether the host it just resolved is one worth remembering (work exists on
# Darwin only), so a test about the marker must not depend on which kind of
# machine the suite happens to run on.
run_resolve_host() {
  local requested=$1 platform=${2:-}
  if [ -n "$platform" ]; then mock_uname "$MOCK_DIR" "$platform"; fi
  (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by resolve_host, sourced dynamically above
    MARKER="$TMP/.dotfiles-host"
    # shellcheck disable=SC2030,SC2031
    PATH="$MOCK_DIR:$PATH"
    rc=0
    resolve_host "$requested" "0" "0" || rc=$?
    echo "HOST=$HOST RESOLVED_NO_NIX=$RESOLVED_NO_NIX rc=$rc"
  )
}

# Same, for the bare `--no-nix` form (no host named at all), which resolves
# to work and must be remembered the same way.
run_resolve_host_no_nix() {
  local platform=$1
  mock_uname "$MOCK_DIR" "$platform"
  (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by resolve_host, sourced dynamically above
    MARKER="$TMP/.dotfiles-host"
    # shellcheck disable=SC2030,SC2031
    PATH="$MOCK_DIR:$PATH"
    rc=0
    resolve_host "" "1" "0" || rc=$?
    echo "HOST=$HOST RESOLVED_NO_NIX=$RESOLVED_NO_NIX rc=$rc"
  )
}

marker_contents() {
  cat "$TMP/.dotfiles-host" 2>/dev/null || true
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

# A host named on the command line is a statement about the machine, same as
# a menu answer - so `./run.sh bootstrap work` once must be enough, and every
# later flagless ./run.sh must resolve to work on its own.
test_explicit_work_host_is_remembered() {
  setup
  out=$(run_resolve_host "work" "Darwin" 2>&1) || true
  assert_contains "explicit work says it remembered the choice" "$out" "remembered 'work'"
  assert_eq "marker remembers work/no-nix" "work
no-nix" "$(marker_contents)"
  teardown
}

test_explicit_nix_host_is_remembered() {
  setup
  out=$(run_resolve_host "personal-mac" "Darwin" 2>&1) || true
  assert_contains "explicit personal-mac says it remembered the choice" "$out" \
    "remembered 'personal-mac'"
  assert_eq "marker remembers personal-mac/nix" "personal-mac
nix" "$(marker_contents)"
  teardown
}

test_bare_no_nix_flag_is_remembered_as_work() {
  setup
  out=$(run_resolve_host_no_nix "Darwin" 2>&1) || true
  assert_contains "--no-nix alone resolves to work" "$out" "HOST=work RESOLVED_NO_NIX=1"
  assert_eq "marker remembers work/no-nix" "work
no-nix" "$(marker_contents)"
  teardown
}

# The one combination that must never be recorded: cmd_bootstrap_no_nix
# rejects work on Linux moments later, so remembering it would leave every
# later flagless ./run.sh resolving to a host that can only fail. choose_host
# already refuses to write the marker for the same answer from the menu
# (test_work_menu_answer_fails_clearly_on_linux).
test_explicit_work_host_on_linux_is_not_remembered() {
  setup
  run_resolve_host "work" "Linux" >/dev/null 2>&1 || true
  if [ -e "$TMP/.dotfiles-host" ]; then
    fail_count=$((fail_count + 1))
    echo "FAIL - work on Linux must not be remembered (there is no work-linux host)"
  else
    pass_count=$((pass_count + 1))
    echo "ok - work on Linux is not remembered"
  fi
  teardown
}

# Re-running with the same explicit host must stay quiet: ./run.sh rebuild
# work would otherwise print "remembered 'work'" on every single run.
test_remembering_the_same_host_again_is_silent() {
  setup
  run_resolve_host "work" "Darwin" >/dev/null 2>&1 || true
  out=$(run_resolve_host "work" "Darwin" 2>&1) || true
  case "$out" in
    *remembered*)
      fail_count=$((fail_count + 1))
      echo "FAIL - an unchanged remembered host must not be re-announced: $out"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - an unchanged remembered host is not re-announced"
      ;;
  esac
  assert_eq "and the marker still says work/no-nix" "work
no-nix" "$(marker_contents)"
  teardown
}

# Remembering is a convenience, never a reason to fail a command the user
# asked for: a checkout whose marker can't be written must still bootstrap.
test_unwritable_marker_warns_but_resolves() {
  setup
  mkdir -p "$TMP/readonly"
  mock_uname "$MOCK_DIR" "Darwin"
  out=$( (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by resolve_host, sourced dynamically above
    MARKER="$TMP/readonly/nonexistent-dir/.dotfiles-host"
    # shellcheck disable=SC2030,SC2031
    PATH="$MOCK_DIR:$PATH"
    rc=0
    resolve_host "work" "0" "0" || rc=$?
    echo "HOST=$HOST rc=$rc"
  ) 2>&1 )
  assert_contains "an unwritable marker still resolves the host" "$out" "HOST=work rc=0"
  assert_contains "and says it couldn't remember it" "$out" "isn't remembered"
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
  mock_whoami "$dir"
  : >"$TMP/invoked.log"
}

# cmd_bootstrap_nix's step 3/4 greps flake.nix for `user = "$(whoami)"` and
# exits 1 on a mismatch, so any test that runs a bootstrap past step 2/4
# would otherwise only pass on the repo owner's own account and fail on CI,
# in a codespace, or for a second contributor - for reasons unrelated to the
# symlink guards under test. Reads the expected name out of flake.nix rather
# than hardcoding it, so this mock can't drift from the file it must match
# (and so no personal username is duplicated into the test suite).
mock_whoami() {
  local dir=$1
  local flake_user
  flake_user=$(sed -n 's/^[[:space:]]*user = "\([^"]*\)".*/\1/p' "$SCRIPT_DIR/flake.nix" | head -1)
  cat >"$dir/whoami" <<MOCK
#!/bin/sh
echo "$flake_user"
MOCK
  chmod +x "$dir/whoami"
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
    # Whatever run.sh records about this machine (record_applied_commit
    # writes the commit the self-apply job reads) must land under the
    # scratch HOME - an XDG_STATE_HOME inherited from the person running
    # the suite would put it in their real state directory instead.
    # shellcheck disable=SC2034 # read by record_applied_commit, sourced dynamically above
    XDG_STATE_HOME=""
    # shellcheck disable=SC2030,SC2031 # PATH is deliberately remocked per subshell
    PATH="$MOCK_DIR:$PATH"
    "$fn" "$host" >/dev/null 2>&1
  ) || true
  cat "$TMP/invoked.log"
}

test_rebuild_home_linux_uses_home_manager_not_darwin_rebuild() {
  setup
  out=$(run_cmd_sandboxed cmd_rebuild "home-linux")
  # Deliberately not the whole argv: the flags between `--` and `switch`
  # are what test_rebuild_home_linux_passes_backup_extension_before_switch
  # is for, so adding one there must not break this test's own subject.
  assert_contains "rebuild home-linux runs the home-manager flake app" "$out" "#home-manager -- "
  assert_contains "rebuild home-linux switches against a flake" "$out" "switch --flake"
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

# Asserts the *position* of -b hm-backup, not merely its presence. It is a
# top-level home-manager option rather than one `switch` accepts, and a
# `switch --flake ... -b hm-backup` is silently dropped instead of
# rejected - so a presence-only check would pass while the switch kept
# aborting on the first unmanaged file in the way. Reads the recorded argv
# of whichever command invoked the home-manager flake app.
assert_backup_flag_precedes_switch() {
  local desc=$1 log=$2 line
  line=$(printf '%s\n' "$log" | grep -- '#home-manager' | head -1)
  case "$line" in
    *"-b hm-backup switch "*)
      pass_count=$((pass_count + 1))
      printf 'ok - %s\n' "$desc"
      ;;
    *)
      fail_count=$((fail_count + 1))
      printf 'FAIL - %s\n  home-manager was invoked as: %s\n' "$desc" "$line"
      ;;
  esac
}

# home-linux is a standalone homeConfigurations output, where
# home-manager.backupFileExtension (what personal-mac gets declaratively in
# flake.nix) does not exist - the CLI flag is the only equivalent. Without
# it, one unmanaged regular file where a managed one goes aborts the entire
# activation, and on a stock Ubuntu box that is the default state:
# /etc/skel seeds ~/.bashrc and ~/.profile, both of which
# modules/core.nix's programs.bash.enable makes home-manager own.
test_rebuild_home_linux_passes_backup_extension_before_switch() {
  setup
  out=$(run_cmd_sandboxed cmd_rebuild "home-linux")
  assert_backup_flag_precedes_switch \
    "rebuild home-linux passes -b hm-backup ahead of switch" "$out"
  teardown
}

# The bootstrap branch runs its own copy of the command, and is the one
# that meets those untouched skel files first.
test_bootstrap_home_linux_passes_backup_extension_before_switch() {
  setup
  out=$(run_cmd_sandboxed cmd_bootstrap_nix "home-linux")
  assert_backup_flag_precedes_switch \
    "bootstrap home-linux passes -b hm-backup ahead of switch" "$out"
  assert_contains "bootstrap home-linux targets the home-linux flake attr" "$out" \
    ".dotfiles#home-linux"
  teardown
}

# The Mac branch must NOT grow the flag by sympathy: darwin-rebuild has no
# -b, and personal-mac already gets the behaviour from flake.nix's
# home-manager.backupFileExtension.
test_rebuild_personal_mac_passes_no_backup_flag() {
  setup
  out=$(run_cmd_sandboxed cmd_rebuild "personal-mac")
  case "$out" in
    *"-b hm-backup"*)
      fail_count=$((fail_count + 1))
      printf 'FAIL - darwin-rebuild takes no -b; personal-mac uses flake.nix instead:\n%s\n' "$out"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - rebuild personal-mac passes no -b (backupFileExtension covers it)"
      ;;
  esac
  teardown
}

# home/.local/bin/dotfiles-auto-apply reads this file to know which commit
# the machine is level with. On personal-mac that job never switches
# anything itself (no terminal for sudo to prompt at, so it notifies that
# an update is ready instead), which makes a hand-run rebuild the only
# thing that can tell it the update has been applied - if this record were
# missing, its reminder would go on being logged forever after you applied
# the update.
applied_record() {
  cat "$TMP/home/.local/state/dotfiles-auto/last-applied" 2>/dev/null || true
}

test_rebuild_records_the_commit_for_the_self_apply_job() {
  setup
  local expected
  expected=$(git -C "$SCRIPT_DIR" rev-parse HEAD)
  run_cmd_sandboxed cmd_rebuild "personal-mac" >/dev/null
  assert_eq "rebuild personal-mac records the applied commit" "$expected" "$(applied_record)"
  teardown

  setup
  run_cmd_sandboxed cmd_rebuild "home-linux" >/dev/null
  assert_eq "rebuild home-linux records the applied commit too" "$expected" "$(applied_record)"
  teardown
}

test_plan_records_nothing() {
  setup
  run_cmd_sandboxed cmd_plan "personal-mac" >/dev/null
  assert_eq "plan changes nothing, so it records nothing" "" "$(applied_record)"
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

# --- validate_dir (run.sh's DIR computation) -------------------------------
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
    # shellcheck disable=SC2329,SC2317 # shadows the cd builtin for run.sh's DIR computation, sourced below (SC2317 is shellcheck <0.10's code for the same report)
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
    # shellcheck disable=SC2329,SC2317 # shadows the dirname command for run.sh's DIR computation, sourced below (SC2317 is shellcheck <0.10's code for the same report)
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

# --- link_dotfiles (called by cmd_bootstrap_nix and cmd_rebuild) -----------

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
  # Reproduces the corrupted state from issue #9: a dangling ~/.dotfiles
  # symlink. The literal empty-target form (`ln -sfn "" ~/.dotfiles`) only
  # exists on macOS - Linux rejects empty symlink targets outright - but
  # both hit the same resolved="" refusal path in link_dotfiles, so a
  # nonexistent target keeps the test cross-platform.
  ln -sfn "$TMP/deleted-checkout" "$TMP/home/.dotfiles"
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

# A symlink that resolves to $target but isn't spelled the way run.sh would
# have written it (relative, hand-restored, trailing slash) is already
# correct. Comparing raw `readlink` text would refuse it and, under set -e,
# kill every ./run.sh rebuild until --relink was passed.
test_link_dotfiles_noop_when_relative_symlink_resolves_to_target() {
  setup
  mkdir -p "$TMP/home" "$TMP/checkout"
  target=$(cd -- "$TMP/checkout" && pwd -P)
  ln -sfn "../checkout" "$TMP/home/.dotfiles"
  out=$(run_link_dotfiles "$target" "0" "$TMP/home" 2>&1)
  assert_eq "relative symlink resolving to target is a silent no-op" "rc=0" "$out"
  assert_eq "relative symlink left exactly as spelled on disk" "../checkout" \
    "$(readlink "$TMP/home/.dotfiles")"
  teardown
}

test_link_dotfiles_noop_when_symlink_has_trailing_slash() {
  setup
  mkdir -p "$TMP/home" "$TMP/checkout"
  target=$(cd -- "$TMP/checkout" && pwd -P)
  ln -sfn "$target/" "$TMP/home/.dotfiles"
  out=$(run_link_dotfiles "$target" "0" "$TMP/home" 2>&1)
  assert_eq "trailing-slash symlink is a silent no-op" "rc=0" "$out"
  teardown
}

# `ln -sfn TARGET DIR` against an existing real directory nests a stray
# symlink inside it and exits 0, leaving the switcher to run against the
# wrong tree - so a non-symlink ~/.dotfiles is refused even with --relink.
test_link_dotfiles_refuses_real_directory_even_with_relink() {
  setup
  mkdir -p "$TMP/home/.dotfiles"
  out=$(run_link_dotfiles "$SCRIPT_DIR" "1" "$TMP/home" 2>&1)
  assert_contains "real directory + --relink: refused" "$out" "rc=1"
  assert_contains "real directory: explains it isn't a symlink" "$out" "is not a symlink"
  if [ -L "$TMP/home/.dotfiles" ] || [ ! -d "$TMP/home/.dotfiles" ]; then
    fail_count=$((fail_count + 1))
    echo "FAIL - a real ~/.dotfiles directory must be left as a directory"
  elif [ -n "$(ls -A "$TMP/home/.dotfiles")" ]; then
    fail_count=$((fail_count + 1))
    echo "FAIL - nothing may be written inside a real ~/.dotfiles directory:"
    ls -la "$TMP/home/.dotfiles"
  else
    pass_count=$((pass_count + 1))
    echo "ok - real ~/.dotfiles directory left untouched and empty"
  fi
  teardown
}

# README prescribes no clone location and every message here names
# ~/.dotfiles, so cloning the repo straight to ~/.dotfiles is a natural
# reading. On that machine DIR == $HOME/.dotfiles is a real directory that
# already resolves to $target - the checkout is already where it belongs, so
# this must be a no-op rather than a refusal whose only advice ("move or
# remove it by hand") would delete the clone.
test_link_dotfiles_noop_when_checkout_itself_is_dotfiles() {
  setup
  mkdir -p "$TMP/home/.dotfiles"
  target=$(cd -- "$TMP/home/.dotfiles" && pwd -P)
  out=$(run_link_dotfiles "$target" "0" "$TMP/home" 2>&1)
  assert_eq "checkout cloned straight to ~/.dotfiles is a silent no-op" "rc=0" "$out"
  if [ -L "$TMP/home/.dotfiles" ] || [ ! -d "$TMP/home/.dotfiles" ] \
    || [ -n "$(ls -A "$TMP/home/.dotfiles")" ]; then
    fail_count=$((fail_count + 1))
    echo "FAIL - a checkout that IS ~/.dotfiles must be left exactly as it was"
    ls -la "$TMP/home"
  else
    pass_count=$((pass_count + 1))
    echo "ok - a checkout that IS ~/.dotfiles left exactly as it was"
  fi
  teardown
}

test_link_dotfiles_refuses_real_file_even_with_relink() {
  setup
  mkdir -p "$TMP/home"
  echo "hand-written notes" >"$TMP/home/.dotfiles"
  out=$(run_link_dotfiles "$SCRIPT_DIR" "1" "$TMP/home" 2>&1)
  assert_contains "real file + --relink: refused" "$out" "rc=1"
  assert_eq "real file: contents left untouched" "hand-written notes" \
    "$(cat "$TMP/home/.dotfiles")"
  teardown
}

# The invariant that actually protects the machine: link_dotfiles returning
# non-zero must abort the whole command via set -e BEFORE any switcher runs.
# Testing link_dotfiles in isolation can't see a regression where the call is
# wrapped in an `if`/`|| true` - run.sh would then refuse to relink and still
# switch against a foreign checkout, which is worse than the original bug.
#
# This has to exec the real script as a subprocess rather than reuse
# run_cmd_sandboxed: that helper's `( ... ) || true` puts the whole subshell
# in a tested context, which bash propagates inward and which disables the
# very `set -e` these tests exist to prove. A fresh `bash run.sh` gets its own
# clean set -e state, so this is also the only assertion here that exercises
# run.sh exactly as a user invokes it, argv parsing included.
# DOTFILES_HOST_MARKER points the remembered-host marker at scratch. It has
# to be set here and nowhere else: this helper runs the real script, which
# computes MARKER from its own directory, so without the override every one
# of these tests would rewrite the remembered host of the checkout the suite
# is being run from - which on the owner's own machine is the live
# ~/.dotfiles.
run_script_sandboxed() {
  mock_switchers "$MOCK_DIR"
  # shellcheck disable=SC2031 # this shell's PATH is untouched; the mock is scoped to the child
  HOME="$TMP/home" PATH="$MOCK_DIR:$PATH" DOTFILES_HOST_MARKER="$TMP/.dotfiles-host" \
    bash "$SCRIPT" "$@" >/dev/null 2>&1
  echo "rc=$?"
  cat "$TMP/invoked.log"
}

test_rebuild_refusal_aborts_before_any_switcher_runs() {
  setup
  mkdir -p "$TMP/home" "$TMP/other-target"
  ln -sfn "$TMP/other-target" "$TMP/home/.dotfiles"
  out=$(run_script_sandboxed rebuild personal-mac)
  assert_eq "refused rebuild exits non-zero and runs no switcher at all" "rc=1" "$out"
  assert_eq "refused rebuild leaves ~/.dotfiles on its original target" \
    "$TMP/other-target" "$(readlink "$TMP/home/.dotfiles")"
  teardown
}

test_bootstrap_refusal_aborts_before_any_switcher_runs() {
  setup
  mkdir -p "$TMP/home" "$TMP/other-target"
  ln -sfn "$TMP/other-target" "$TMP/home/.dotfiles"
  out=$(run_script_sandboxed bootstrap personal-mac)
  assert_eq "refused bootstrap exits non-zero and runs no switcher at all" "rc=1" "$out"
  assert_eq "refused bootstrap leaves ~/.dotfiles on its original target" \
    "$TMP/other-target" "$(readlink "$TMP/home/.dotfiles")"
  teardown
}

# The counterpart: with nothing in the way, the same end-to-end invocation
# must still create the symlink and reach the switcher - the first-run
# bootstrap path that must not regress.
test_bootstrap_creates_symlink_and_reaches_switcher_when_absent() {
  setup
  mkdir -p "$TMP/home"
  out=$(run_script_sandboxed bootstrap personal-mac)
  assert_contains "clean bootstrap succeeds" "$out" "rc=0"
  assert_contains "clean bootstrap reaches the darwin switcher" "$out" \
    "darwin-rebuild -- switch --flake"
  assert_eq "clean bootstrap creates ~/.dotfiles pointing at this checkout" \
    "$SCRIPT_DIR" "$(readlink "$TMP/home/.dotfiles")"
  teardown
}

# The whole point of remembering, end to end through the real script: name
# the host once, then never again. Asserted on the argv the second,
# host-less invocation reaches, not merely on the marker's contents.
test_explicit_host_is_remembered_for_the_next_run_end_to_end() {
  setup
  mkdir -p "$TMP/home"
  run_script_sandboxed bootstrap personal-mac >/dev/null
  assert_eq "the explicit host was written to the marker" "personal-mac
nix" "$(marker_contents)"
  out=$(run_script_sandboxed rebuild)
  assert_contains "a later host-less rebuild succeeds" "$out" "rc=0"
  assert_contains "and targets the remembered host with no flag" "$out" \
    ".dotfiles#personal-mac"
  teardown
}

test_relink_flag_repoints_symlink_end_to_end() {
  setup
  mkdir -p "$TMP/home" "$TMP/other-target"
  ln -sfn "$TMP/other-target" "$TMP/home/.dotfiles"
  out=$(run_script_sandboxed rebuild personal-mac --relink)
  assert_contains "--relink lets rebuild proceed" "$out" "rc=0"
  assert_contains "--relink rebuild reaches the darwin switcher" "$out" \
    "sudo darwin-rebuild switch --flake"
  assert_eq "--relink repoints ~/.dotfiles at this checkout" \
    "$SCRIPT_DIR" "$(readlink "$TMP/home/.dotfiles")"
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
test_explicit_work_host_is_remembered
test_explicit_nix_host_is_remembered
test_bare_no_nix_flag_is_remembered_as_work
test_explicit_work_host_on_linux_is_not_remembered
test_remembering_the_same_host_again_is_silent
test_unwritable_marker_warns_but_resolves
test_rebuild_home_linux_uses_home_manager_not_darwin_rebuild
test_rebuild_personal_mac_still_uses_darwin_rebuild
test_rebuild_home_linux_passes_backup_extension_before_switch
test_bootstrap_home_linux_passes_backup_extension_before_switch
test_rebuild_personal_mac_passes_no_backup_flag
test_plan_home_linux_builds_the_home_manager_activation_package
test_plan_personal_mac_still_builds_the_darwin_system
test_rebuild_records_the_commit_for_the_self_apply_job
test_plan_records_nothing
test_unresolvable_dir_aborts_before_any_write
test_dir_resolving_outside_repo_aborts_before_any_write
test_link_dotfiles_creates_when_absent
test_link_dotfiles_noop_when_already_correct
test_link_dotfiles_refuses_when_pointing_elsewhere
test_link_dotfiles_refuses_on_dangling_empty_target_symlink
test_link_dotfiles_relink_moves_it
test_link_dotfiles_noop_when_relative_symlink_resolves_to_target
test_link_dotfiles_noop_when_symlink_has_trailing_slash
test_link_dotfiles_refuses_real_directory_even_with_relink
test_link_dotfiles_noop_when_checkout_itself_is_dotfiles
test_link_dotfiles_refuses_real_file_even_with_relink
test_rebuild_refusal_aborts_before_any_switcher_runs
test_bootstrap_refusal_aborts_before_any_switcher_runs
test_bootstrap_creates_symlink_and_reaches_switcher_when_absent
test_explicit_host_is_remembered_for_the_next_run_end_to_end
test_relink_flag_repoints_symlink_end_to_end

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
