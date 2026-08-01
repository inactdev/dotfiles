#!/usr/bin/env bash
# Test suite for install.sh's pure decision logic: personal-vs-work posture
# detection and the settings-file choice that follows from it. Sources the
# real install.sh (see the BASH_SOURCE guard at its tail) and calls its
# functions directly against a scratch fake-dotfiles git repo, so it never
# touches apt, npm, or any real download. This does NOT exercise the real
# install (apt packages, neovim tarball, formatters, Claude Code CLI) - see
# README.md for the real `docker run ubuntu:24.04` end-to-end run that
# covers that path.
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

# --- install_claude_settings -------------------------------------------------

test_personal_posture_links_codespaces_settings() {
  setup
  (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    HOME="$HOME" install_claude_settings "personal"
  )
  assert_eq "personal posture links codespaces/claude-settings.json" \
    "$SCRIPT_DIR/codespaces/claude-settings.json" "$(readlink "$HOME/.claude/settings.json")"
  teardown
}

test_work_posture_links_work_settings() {
  setup
  (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    HOME="$HOME" install_claude_settings "work"
  )
  assert_eq "work posture links work/claude-settings.json" \
    "$SCRIPT_DIR/work/claude-settings.json" "$(readlink "$HOME/.claude/settings.json")"
  teardown
}

# --- configure_posture_shell -------------------------------------------------

test_personal_posture_adds_skip_permissions_alias() {
  setup
  (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    HOME="$HOME" configure_posture_shell "personal"
  )
  assert_contains "personal posture adds --dangerously-skip-permissions alias" \
    "$(cat "$HOME/.zshrc.local")" 'alias cc="claude --dangerously-skip-permissions"'
  teardown
}

test_personal_posture_alias_not_duplicated_on_rerun() {
  setup
  (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    HOME="$HOME" configure_posture_shell "personal"
    HOME="$HOME" configure_posture_shell "personal"
  )
  assert_eq "alias line appears exactly once after two runs" "1" \
    "$(grep -cF 'alias cc="claude --dangerously-skip-permissions"' "$HOME/.zshrc.local")"
  teardown
}

test_posture_flip_to_work_removes_skip_permissions_alias() {
  setup
  (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    HOME="$HOME" configure_posture_shell "personal"
    HOME="$HOME" configure_posture_shell "work"
  )
  if grep -qF 'alias cc="claude --dangerously-skip-permissions"' "$HOME/.zshrc.local" 2>/dev/null; then
    fail_count=$((fail_count + 1))
    echo "FAIL - alias must not survive a personal -> work posture flip"
  else
    pass_count=$((pass_count + 1))
    echo "ok - alias removed on personal -> work posture flip"
  fi
  teardown
}

test_posture_flip_to_work_preserves_other_zshrc_local_lines() {
  setup
  (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    HOME="$HOME" configure_posture_shell "personal"
    echo 'export SOME_OTHER_VAR=1' >>"$HOME/.zshrc.local"
    HOME="$HOME" configure_posture_shell "work"
  )
  assert_contains "unrelated .zshrc.local lines survive the flip" \
    "$(cat "$HOME/.zshrc.local")" 'export SOME_OTHER_VAR=1'
  teardown
}

test_work_posture_does_not_touch_zshrc_local() {
  setup
  (
    # shellcheck disable=SC1090
    source "$SCRIPT"
    HOME="$HOME" configure_posture_shell "work"
  )
  if [ -e "$HOME/.zshrc.local" ]; then
    fail_count=$((fail_count + 1))
    echo "FAIL - work posture must not create .zshrc.local"
  else
    pass_count=$((pass_count + 1))
    echo "ok - work posture leaves .zshrc.local untouched"
  fi
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

test_codespaces_claude_settings_no_hooks_keeps_skip_permissions() {
  jq empty "$SCRIPT_DIR/codespaces/claude-settings.json"
  assert_eq "no hooks key" "" \
    "$(jq -r 'if has("hooks") then "present" else "" end' "$SCRIPT_DIR/codespaces/claude-settings.json")"
  assert_eq "skipDangerousModePermissionPrompt kept" "true" \
    "$(jq -r '.skipDangerousModePermissionPrompt' "$SCRIPT_DIR/codespaces/claude-settings.json")"
}

test_no_username_hardcoded_in_source() {
  hits=$(mktemp)
  if grep -RIn --exclude='*.test.sh' -e '/Users/inactdev' -e 'inactdev' \
    "$SCRIPT" "$SCRIPT_DIR/codespaces" >"$hits" 2>/dev/null; then
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
test_personal_posture_links_codespaces_settings
test_work_posture_links_work_settings
test_personal_posture_adds_skip_permissions_alias
test_personal_posture_alias_not_duplicated_on_rerun
test_posture_flip_to_work_removes_skip_permissions_alias
test_posture_flip_to_work_preserves_other_zshrc_local_lines
test_work_posture_does_not_touch_zshrc_local
test_require_codespaces_fails_outside_a_codespace
test_codespaces_claude_settings_no_hooks_keeps_skip_permissions

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
