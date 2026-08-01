#!/bin/sh
# Test suite for work/bootstrap.sh (the --no-nix path). Runs the real
# script against mocked brew/defaults/killall/gh commands on a hermetic
# PATH and a scratch HOME, so it never touches real Homebrew packages,
# real macOS defaults, or the real ~/.zshrc / ~/.claude / ~/AGENTS.md -
# safe to run any time, by anyone, with no side effects outside a temp
# dir. This does NOT exercise real package installation or a real
# corporate Mac - see README.md for what still needs the real machine.
#
# Usage: sh work/bootstrap.test.sh
set -eu

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck disable=SC1007
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
SCRIPT="$SCRIPT_DIR/bootstrap.sh"

pass_count=0
fail_count=0

# --- mocks --------------------------------------------------------------
# brew: "bundle" logs to $FIXTURES/brew.log and succeeds; anything else
# also logs and succeeds. Real package installation never runs.
mock_bin() {
  dir=$1
  cat >"$dir/brew" <<'MOCK'
#!/bin/sh
echo "brew $*" >>"$FIXTURES/brew.log"
exit 0
MOCK
  cat >"$dir/defaults" <<'MOCK'
#!/bin/sh
echo "defaults $*" >>"$FIXTURES/defaults.log"
if [ -f "$FIXTURES/defaults_fail" ]; then
  exit 1
fi
exit 0
MOCK
  cat >"$dir/killall" <<'MOCK'
#!/bin/sh
exit 0
MOCK
  cat >"$dir/gh" <<'MOCK'
#!/bin/sh
if [ "$1 $2" = "auth status" ]; then
  [ -f "$FIXTURES/gh_authenticated" ] && exit 0 || exit 1
fi
if [ "$1 $2" = "auth setup-git" ]; then
  echo "gh auth setup-git" >>"$FIXTURES/gh.log"
  exit 0
fi
exit 0
MOCK
  chmod +x "$dir/brew" "$dir/defaults" "$dir/killall" "$dir/gh"
}

setup() {
  TMP=$(mktemp -d)
  MOCK_DIR="$TMP/bin"
  FIXTURES="$TMP/fixtures"
  HOME="$TMP/home"
  mkdir -p "$MOCK_DIR" "$FIXTURES" "$HOME"
  mock_bin "$MOCK_DIR"
  : >"$FIXTURES/brew.log"
  : >"$FIXTURES/defaults.log"
  : >"$FIXTURES/gh.log"
  # git/jq/ln/mkdir/mv/read etc. come from the real system - none of them
  # are the thing under test and none touch anything outside $HOME.
  JQ_BIN=$(command -v jq)
  GIT_BIN=$(command -v git)
  ln -s "$JQ_BIN" "$MOCK_DIR/jq"
  ln -s "$GIT_BIN" "$MOCK_DIR/git"
}

teardown() {
  rm -rf "$TMP"
}

run_bootstrap() {
  # Hermetic PATH: no real brew/defaults/gh reachable, so a bug can never
  # install real packages or touch real macOS defaults from a test run.
  # stdin is /dev/null so `[ -t 0 ]` is false and identity prompts never
  # block the suite.
  HOME="$HOME" FIXTURES="$FIXTURES" PATH="$MOCK_DIR:/usr/bin:/bin" "$SCRIPT" "$REPO_DIR" </dev/null
}

assert_eq() {
  desc=$1
  expected=$2
  actual=$3
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
    printf 'ok - %s\n' "$desc"
  else
    fail_count=$((fail_count + 1))
    printf 'FAIL - %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
  fi
}

assert_contains() {
  desc=$1
  haystack=$2
  needle=$3
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

# --- tests ----------------------------------------------------------------

test_symlinks_point_into_repo() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_eq "nvim config symlinked" "$REPO_DIR/home/.config/nvim" "$(readlink "$HOME/.config/nvim")"
  assert_eq "starship config symlinked" "$REPO_DIR/home/.config/starship.toml" "$(readlink "$HOME/.config/starship.toml")"
  assert_eq "ghostty config symlinked" "$REPO_DIR/home/.config/ghostty" "$(readlink "$HOME/.config/ghostty")"
  assert_eq "AGENTS.md symlinked" "$REPO_DIR/home/AGENTS.md" "$(readlink "$HOME/AGENTS.md")"
  assert_eq "CLAUDE.md symlinked to AGENTS.md" "$REPO_DIR/home/AGENTS.md" "$(readlink "$HOME/.claude/CLAUDE.md")"
  if [ ! -e "$HOME/.tmux.conf" ]; then
    pass_count=$((pass_count + 1)); echo "ok - no tmux symlink"
  else
    fail_count=$((fail_count + 1)); echo "FAIL - no tmux symlink"
  fi
  if [ ! -e "$HOME/.config/wezterm" ]; then
    pass_count=$((pass_count + 1)); echo "ok - no wezterm symlink"
  else
    fail_count=$((fail_count + 1)); echo "FAIL - no wezterm symlink"
  fi
  if [ ! -e "$HOME/.config/herdr" ]; then
    pass_count=$((pass_count + 1)); echo "ok - no herdr symlink"
  else
    fail_count=$((fail_count + 1)); echo "FAIL - no herdr symlink"
  fi
  teardown
}

test_zshrc_and_claude_settings_linked() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_eq "zshrc symlinked to work/zshrc" "$REPO_DIR/work/zshrc" "$(readlink "$HOME/.zshrc")"
  assert_eq "claude settings symlinked to work variant" "$REPO_DIR/work/claude-settings.json" "$(readlink "$HOME/.claude/settings.json")"
  teardown
}

test_zshrc_backs_up_preexisting_real_file() {
  setup
  echo "some real user zshrc" >"$HOME/.zshrc"
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_eq "pre-existing real .zshrc backed up" "some real user zshrc" "$(cat "$HOME/.zshrc.pre-dotfiles-backup")"
  assert_eq "new .zshrc is our symlink" "$REPO_DIR/work/zshrc" "$(readlink "$HOME/.zshrc")"
  teardown
}

test_claude_settings_variant_is_valid_json_without_hooks() {
  setup
  jq empty "$REPO_DIR/work/claude-settings.json"
  assert_eq "no hooks key" "" "$(jq -r 'if has("hooks") then "present" else "" end' "$REPO_DIR/work/claude-settings.json")"
  assert_eq "no skipDangerousModePermissionPrompt key" "" "$(jq -r 'if has("skipDangerousModePermissionPrompt") then "present" else "" end' "$REPO_DIR/work/claude-settings.json")"
  assert_eq "statusLine survives" "command" "$(jq -r '.statusLine.type' "$REPO_DIR/work/claude-settings.json")"
  teardown
}

test_git_config_set() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_eq "push.autoSetupRemote set" "true" "$(HOME="$HOME" git config --global push.autoSetupRemote)"
  assert_eq "core.editor set" "nvim" "$(HOME="$HOME" git config --global core.editor)"
  teardown
}

test_no_tty_no_identity_never_falls_back_to_personal_email() {
  setup
  out=$(run_bootstrap 2>&1) || true
  assert_eq "no git user.name set" "" "$(HOME="$HOME" git config --global user.name 2>/dev/null || true)"
  assert_eq "no git user.email set" "" "$(HOME="$HOME" git config --global user.email 2>/dev/null || true)"
  case "$out" in
    *"aris.a.perez"*)
      fail_count=$((fail_count + 1))
      echo "FAIL - personal email must never appear in bootstrap output"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - personal email never appears"
      ;;
  esac
  assert_contains "summary flags git identity as pending" "$out" "git identity"
  teardown
}

test_existing_git_identity_is_preserved_and_not_pending() {
  setup
  HOME="$HOME" git config --global user.name "Someone Else"
  HOME="$HOME" git config --global user.email "someone@work.example"
  out=$(run_bootstrap 2>&1) || true
  assert_eq "existing identity preserved" "Someone Else" "$(HOME="$HOME" git config --global user.name)"
  case "$out" in
    *"git identity: run git config"*)
      fail_count=$((fail_count + 1))
      echo "FAIL - already-configured identity should not be flagged pending"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - already-configured identity not flagged pending"
      ;;
  esac
  teardown
}

test_macos_defaults_failure_warns_and_continues() {
  setup
  : >"$FIXTURES/defaults_fail"
  out=$(run_bootstrap 2>&1)
  code=$?
  assert_eq "bootstrap still exits 0 despite MDM-locked defaults" "0" "$code"
  assert_contains "warns about a rejected default" "$out" "WARN: could not set"
  assert_contains "summary flags macOS defaults as pending" "$out" "macOS defaults"
  teardown
}

test_brew_bundle_invoked_with_work_brewfile() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_contains "brew bundle called with work/Brewfile" "$(cat "$FIXTURES/brew.log")" "bundle --file=$REPO_DIR/work/Brewfile"
  teardown
}

test_idempotent_rerun() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  first_target=$(readlink "$HOME/.zshrc")
  run_bootstrap >"$TMP/out2.log" 2>&1
  code=$?
  assert_eq "second run exits 0" "0" "$code"
  assert_eq "zshrc still points at the same place, no re-backup" "$first_target" "$(readlink "$HOME/.zshrc")"
  assert_eq "no backup file created on re-run (target was already our symlink)" "0" "$(find "$HOME" -name '*.pre-dotfiles-backup' | wc -l | tr -d ' ')"
  teardown
}

test_no_username_hardcoded_in_source() {
  # Static check, not a run_bootstrap scenario: the *code* must never
  # hard-code the personal username, independent of where this particular
  # clone happens to live on disk (which will legitimately contain
  # whatever the cloning user's home directory is).
  hits=$(mktemp)
  if grep -RIn --exclude='*.test.sh' -e '/Users/inactdev' -e 'inactdev' \
    "$SCRIPT_DIR" "$REPO_DIR/run.sh" >"$hits" 2>/dev/null; then
    fail_count=$((fail_count + 1))
    echo "FAIL - work-host code hard-codes the personal username:"
    cat "$hits"
  else
    pass_count=$((pass_count + 1))
    echo "ok - no hard-coded personal username in work-host code"
  fi
  rm -f "$hits"
}

test_no_username_hardcoded_in_source
test_symlinks_point_into_repo
test_zshrc_and_claude_settings_linked
test_zshrc_backs_up_preexisting_real_file
test_claude_settings_variant_is_valid_json_without_hooks
test_git_config_set
test_no_tty_no_identity_never_falls_back_to_personal_email
test_existing_git_identity_is_preserved_and_not_pending
test_macos_defaults_failure_warns_and_continues
test_brew_bundle_invoked_with_work_brewfile
test_idempotent_rerun

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
