#!/usr/bin/env bash
# Test suite for install.sh's pure decision logic: personal-vs-work posture
# detection, and the require_codespaces guard. Sources the real install.sh
# (see the BASH_SOURCE guard at its tail) and calls its functions directly
# against a scratch fake-dotfiles git repo, so it never touches Nix, sudo,
# or any real download. This does NOT exercise the real install (installing
# Nix, starting nix-daemon, applying the codespace-personal/codespace-work
# home-manager profile, chsh, nvim plugin sync) - see
# install.container-test.sh for the real end-to-end container run that
# covers that path, for both postures.
#
# Usage: bash install.test.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPT="$SCRIPT_DIR/install.sh"

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
  TMP=$(mktemp -d)
  FAKE_DOTFILES="$TMP/fake-dotfiles"
  HOME="$TMP/home"
  mkdir -p "$FAKE_DOTFILES" "$HOME"
}

teardown() {
  rm -rf "$TMP"
}

set_fake_origin() {
  git -C "$FAKE_DOTFILES" init -q
  git -C "$FAKE_DOTFILES" remote add origin "$1"
}

# --- detect_posture ---------------------------------------------------------

test_same_owner_is_personal() {
  setup
  set_fake_origin "https://github.com/inactdev/dotfiles.git"
  out=$(
    # shellcheck disable=SC1090
    source "$SCRIPT"
    GITHUB_REPOSITORY="inactdev/some-personal-project" detect_posture "$FAKE_DOTFILES"
  )
  assert_eq "same owner (https origin) -> personal" "personal" "$out"
  teardown
}

test_same_owner_ssh_origin_is_personal() {
  setup
  set_fake_origin "git@github.com:inactdev/dotfiles.git"
  out=$(
    # shellcheck disable=SC1090
    source "$SCRIPT"
    GITHUB_REPOSITORY="inactdev/some-personal-project" detect_posture "$FAKE_DOTFILES"
  )
  assert_eq "same owner (ssh origin) -> personal" "personal" "$out"
  teardown
}

test_owner_comparison_is_case_insensitive() {
  setup
  set_fake_origin "https://github.com/InactDev/dotfiles.git"
  out=$(
    # shellcheck disable=SC1090
    source "$SCRIPT"
    GITHUB_REPOSITORY="inactdev/some-personal-project" detect_posture "$FAKE_DOTFILES"
  )
  assert_eq "case-insensitive owner match -> personal" "personal" "$out"
  teardown
}

test_different_owner_is_work() {
  setup
  set_fake_origin "https://github.com/inactdev/dotfiles.git"
  out=$(
    # shellcheck disable=SC1090
    source "$SCRIPT"
    GITHUB_REPOSITORY="acme-corp/widgets" detect_posture "$FAKE_DOTFILES"
  )
  assert_eq "different owner -> work" "work" "$out"
  teardown
}

test_missing_github_repository_defaults_to_work() {
  setup
  set_fake_origin "https://github.com/inactdev/dotfiles.git"
  out=$(
    # shellcheck disable=SC1090
    source "$SCRIPT"
    unset GITHUB_REPOSITORY
    detect_posture "$FAKE_DOTFILES"
  )
  assert_eq "undeterminable workspace owner -> work (locked-down default)" "work" "$out"
  teardown
}

test_no_origin_remote_defaults_to_work() {
  setup
  git -C "$FAKE_DOTFILES" init -q
  out=$(
    # shellcheck disable=SC1090
    source "$SCRIPT"
    GITHUB_REPOSITORY="inactdev/some-personal-project" detect_posture "$FAKE_DOTFILES"
  )
  assert_eq "undeterminable dotfiles owner -> work (locked-down default)" "work" "$out"
  teardown
}

# --- require_codespaces -------------------------------------------------------

test_require_codespaces_fails_outside_a_codespace() {
  setup
  if out=$(
    exec 2>&1
    # shellcheck disable=SC1090
    source "$SCRIPT"
    unset CODESPACES
    require_codespaces
    echo "should not reach here"
  ); then
    code=0
  else
    code=$?
  fi
  assert_eq "require_codespaces exits non-zero without CODESPACES=true" "1" "$code"
  assert_contains "explains this is the Codespaces entry point" "$out" "CODESPACES=true"
  teardown
}

# --- settings-file content ----------------------------------------------------
# The posture -> settings-file wiring itself now lives in
# modules/codespace.nix (see flake.nix's homeConfigurations."codespace-
# personal"/"codespace-work"), not install.sh, so it's exercised by
# install.container-test.sh instead of a bash unit test here. What's left
# to check at this level is just the static file content each posture links.

test_codespaces_claude_settings_no_hooks_keeps_skip_permissions() {
  jq empty "$SCRIPT_DIR/codespaces/claude-settings.json"
  assert_eq "no hooks key" "" \
    "$(jq -r 'if has("hooks") then "present" else "" end' "$SCRIPT_DIR/codespaces/claude-settings.json")"
  assert_eq "skipDangerousModePermissionPrompt kept" "true" \
    "$(jq -r '.skipDangerousModePermissionPrompt' "$SCRIPT_DIR/codespaces/claude-settings.json")"
}

test_work_claude_settings_no_hooks_no_skip_permissions() {
  jq empty "$SCRIPT_DIR/work/claude-settings.json"
  assert_eq "no hooks key" "" \
    "$(jq -r 'if has("hooks") then "present" else "" end' "$SCRIPT_DIR/work/claude-settings.json")"
  assert_eq "no skipDangerousModePermissionPrompt key" "" \
    "$(jq -r 'if has("skipDangerousModePermissionPrompt") then "present" else "" end' "$SCRIPT_DIR/work/claude-settings.json")"
}

test_no_username_hardcoded_in_source() {
  hits=$(mktemp)
  if grep -RIn --exclude='*.test.sh' -e '/Users/inactdev' -e 'inactdev' \
    "$SCRIPT" "$SCRIPT_DIR/codespaces" "$SCRIPT_DIR/modules/codespace.nix" >"$hits" 2>/dev/null; then
    fail_count=$((fail_count + 1))
    echo "FAIL - codespaces-host code hard-codes the personal username:"
    cat "$hits"
  else
    pass_count=$((pass_count + 1))
    echo "ok - no hard-coded personal username in codespaces-host code"
  fi
  rm -f "$hits"
}

test_no_username_hardcoded_in_source
test_same_owner_is_personal
test_same_owner_ssh_origin_is_personal
test_owner_comparison_is_case_insensitive
test_different_owner_is_work
test_missing_github_repository_defaults_to_work
test_no_origin_remote_defaults_to_work
test_require_codespaces_fails_outside_a_codespace
test_codespaces_claude_settings_no_hooks_keeps_skip_permissions
test_work_claude_settings_no_hooks_no_skip_permissions

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
