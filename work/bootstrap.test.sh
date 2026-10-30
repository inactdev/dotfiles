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
#
# npm/go are mocked for the same reason: install_fabrica and
# install_inspector would otherwise reach the real registry, the real Go
# module proxy, and two private GitHub repositories. git is mocked too,
# but only for `clone` - see mock_git below, which is what keeps
# install_fabrica's clone off the network while leaving the real git for
# the identity assertions.
mock_bin() {
  dir=$1
  cat >"$dir/brew" <<'MOCK'
#!/bin/sh
echo "brew $*" >>"$FIXTURES/brew.log"
exit 0
MOCK
  # npm: logs every invocation. `pack --pack-destination <dir>` leaves one
  # tarball there, which is what install_fabrica then globs for and
  # installs, so the whole clone -> pack -> install chain is exercised
  # without npm ever running. $FIXTURES/npm_fail makes every call fail.
  cat >"$dir/npm" <<'MOCK'
#!/bin/sh
echo "npm $*" >>"$FIXTURES/npm.log"
if [ -f "$FIXTURES/npm_fail" ]; then
  exit 1
fi
if [ "$1" = pack ]; then
  dest=.
  while [ $# -gt 0 ]; do
    if [ "$1" = --pack-destination ]; then
      dest=$2
    fi
    shift
  done
  mkdir -p "$dest"
  : >"$dest/fabrica-0.0.0.tgz"
fi
exit 0
MOCK
  # go: logs every invocation, and `install` drops a stub binary in
  # whatever GOBIN the caller set, so the test can assert the binary lands
  # where work/zshrc already looks. $FIXTURES/go_fail makes it fail.
  cat >"$dir/go" <<'MOCK'
#!/bin/sh
echo "go $*" >>"$FIXTURES/go.log"
echo "GOBIN=${GOBIN:-} GOPRIVATE=${GOPRIVATE:-} CGO_ENABLED=${CGO_ENABLED:-} GIT_TERMINAL_PROMPT=${GIT_TERMINAL_PROMPT:-}" >>"$FIXTURES/go.env.log"
if [ -f "$FIXTURES/go_fail" ]; then
  exit 1
fi
if [ "$1" = install ] && [ -n "${GOBIN:-}" ]; then
  mkdir -p "$GOBIN"
  : >"$GOBIN/inspector"
  chmod +x "$GOBIN/inspector"
fi
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
  chmod +x "$dir/brew" "$dir/defaults" "$dir/killall" "$dir/gh" "$dir/npm" "$dir/go"
}

# git, intercepted for `clone` only. install_fabrica clones a private
# repository, which a test must never actually attempt - so a `clone`
# anywhere in the argument list is logged and faked (the destination, the
# last argument, is created with a minimal package.json so the pack step
# downstream has something to stand in). Every other git invocation is
# handed to the real binary, which this suite needs for its git-identity
# assertions against a scratch $HOME. $FIXTURES/git_clone_fail makes the
# clone fail the way an unauthenticated machine's would.
mock_git() {
  dir=$1
  cat >"$dir/git" <<'MOCK'
#!/bin/sh
for arg in "$@"; do
  if [ "$arg" = clone ]; then
    echo "git $*" >>"$FIXTURES/git.log"
    if [ -f "$FIXTURES/git_clone_fail" ]; then
      exit 1
    fi
    dest=
    for a in "$@"; do
      dest=$a
    done
    mkdir -p "$dest"
    printf '{"name":"fabrica","version":"0.0.0"}\n' >"$dest/package.json"
    exit 0
  fi
done
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$dir/git"
}

setup() {
  TMP=$(mktemp -d)
  MOCK_DIR="$TMP/bin"
  FIXTURES="$TMP/fixtures"
  HOME="$TMP/home"
  mkdir -p "$MOCK_DIR" "$FIXTURES" "$HOME" "$TMP/tmp"
  mock_bin "$MOCK_DIR"
  : >"$FIXTURES/brew.log"
  : >"$FIXTURES/defaults.log"
  : >"$FIXTURES/gh.log"
  : >"$FIXTURES/npm.log"
  : >"$FIXTURES/go.log"
  : >"$FIXTURES/go.env.log"
  : >"$FIXTURES/git.log"
  # jq/ln/mkdir/mv/read etc. come from the real system - none of them are
  # the thing under test and none touch anything outside $HOME. git is the
  # one exception: the real binary is still what runs for everything but
  # `clone` (see mock_git), reached through $REAL_GIT.
  JQ_BIN=$(command -v jq)
  REAL_GIT=$(command -v git)
  ln -s "$JQ_BIN" "$MOCK_DIR/jq"
  mock_git "$MOCK_DIR"
}

teardown() {
  rm -rf "$TMP"
}

run_bootstrap() {
  # Hermetic PATH: no real brew/defaults/gh reachable, so a bug can never
  # install real packages or touch real macOS defaults from a test run.
  # stdin is /dev/null so `[ -t 0 ]` is false and identity prompts never
  # block the suite.
  # TMPDIR under $TMP too: install_fabrica makes its clone/tarball
  # directory there, so a leak is visible to the leftover assertion below
  # and is cleaned up with the rest of the scratch dir either way.
  HOME="$HOME" FIXTURES="$FIXTURES" REAL_GIT="$REAL_GIT" TMPDIR="$TMP/tmp" \
    PATH="$MOCK_DIR:/usr/bin:/bin" "$SCRIPT" "$REPO_DIR" </dev/null
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
  assert_eq "herdr config symlinked" "$REPO_DIR/home/.config/herdr" "$(readlink "$HOME/.config/herdr")"
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
  if out=$(run_bootstrap 2>&1); then code=0; else code=$?; fi
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
  if run_bootstrap >"$TMP/out2.log" 2>&1; then code=0; else code=$?; fi
  assert_eq "second run exits 0" "0" "$code"
  assert_eq "zshrc still points at the same place, no re-backup" "$first_target" "$(readlink "$HOME/.zshrc")"
  assert_eq "no backup file created on re-run (target was already our symlink)" "0" "$(find "$HOME" -name '*.pre-dotfiles-backup' | wc -l | tr -d ' ')"
  teardown
}

test_fabrica_installed_via_clone_then_pack() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_contains "fabrica cloned shallowly from its own repo, on master" \
    "$(cat "$FIXTURES/git.log")" \
    "clone --quiet --depth 1 --branch master https://github.com/inactdev/fabrica.git"
  assert_contains "npm pack run with an explicit pack destination" \
    "$(cat "$FIXTURES/npm.log")" "pack --pack-destination"
  assert_contains "the packed tarball is what gets installed globally, under ~/.local" \
    "$(cat "$FIXTURES/npm.log")" "install -g --prefix $HOME/.local"
  assert_contains "and it is a .tgz, not a git spec" \
    "$(cat "$FIXTURES/npm.log")" "fabrica-0.0.0.tgz"
  teardown
}

# The two shorter forms Fabrica's README explicitly rules out. Both
# "work" in the sense of exiting 0, which is exactly why this is asserted
# rather than left to a human to notice: the symptom of either is
# `fabrica doctor` refusing to start work later.
test_fabrica_never_installed_from_a_git_spec() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  log=$(cat "$FIXTURES/npm.log")
  case "$log" in
    *"github:"*)
      fail_count=$((fail_count + 1))
      echo "FAIL - npm was handed a github: spec; must install the packed tarball instead"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - npm is never handed a github: spec"
      ;;
  esac
  teardown
}

test_inspector_installed_with_go_install_latest() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_contains "inspector installed with the documented go install command" \
    "$(cat "$FIXTURES/go.log")" \
    "install github.com/inactdev/inspector/cmd/inspector@latest"
  assert_contains "GOBIN pins the binary to the directory work/zshrc puts on PATH" \
    "$(cat "$FIXTURES/go.env.log")" "GOBIN=$HOME/.local/bin"
  assert_contains "the fetch stays off the public proxy/checksum DB for this owner" \
    "$(cat "$FIXTURES/go.env.log")" "GOPRIVATE=github.com/inactdev/*"
  assert_contains "cgo off, so no C toolchain is needed on a locked-down Mac" \
    "$(cat "$FIXTURES/go.env.log")" "CGO_ENABLED=0"
  assert_contains "git can never stop on a credential prompt" \
    "$(cat "$FIXTURES/go.env.log")" "GIT_TERMINAL_PROMPT=0"
  if [ -x "$HOME/.local/bin/inspector" ]; then
    pass_count=$((pass_count + 1)); echo "ok - inspector binary lands in ~/.local/bin"
  else
    fail_count=$((fail_count + 1)); echo "FAIL - inspector binary lands in ~/.local/bin"
  fi
  teardown
}

test_fabrica_clone_failure_warns_and_continues() {
  setup
  : >"$FIXTURES/git_clone_fail"
  if out=$(run_bootstrap 2>&1); then code=0; else code=$?; fi
  assert_eq "bootstrap still exits 0 when the private clone is refused" "0" "$code"
  assert_contains "says the clone failed" "$out" "could not clone master"
  assert_contains "points at gh auth login" "$out" "gh auth login"
  assert_contains "summary flags Fabrica as pending" "$out" "Fabrica: not installed"
  assert_contains "the rest of the bootstrap still ran" "$out" "applying macOS defaults"
  # Nothing was packed or installed, and the scratch clone directory is gone.
  assert_eq "npm never ran after a failed clone" "" "$(cat "$FIXTURES/npm.log")"
  assert_eq "no clone/tarball directory left behind" "0" \
    "$(find "$TMP/tmp" -maxdepth 1 -name 'fabrica-install.*' | wc -l | tr -d ' ')"
  teardown
}

test_fabrica_npm_failure_warns_and_continues() {
  setup
  : >"$FIXTURES/npm_fail"
  if out=$(run_bootstrap 2>&1); then code=0; else code=$?; fi
  assert_eq "bootstrap still exits 0 when npm fails" "0" "$code"
  assert_contains "says npm pack failed" "$out" "npm pack of the clone failed"
  assert_contains "summary flags Fabrica as pending" "$out" "Fabrica: not installed"
  assert_eq "no clone/tarball directory left behind" "0" \
    "$(find "$TMP/tmp" -maxdepth 1 -name 'fabrica-install.*' | wc -l | tr -d ' ')"
  teardown
}

test_inspector_failure_warns_and_continues() {
  setup
  : >"$FIXTURES/go_fail"
  if out=$(run_bootstrap 2>&1); then code=0; else code=$?; fi
  assert_eq "bootstrap still exits 0 when go install fails" "0" "$code"
  assert_contains "says the go install failed" "$out" "go install github.com/inactdev/inspector/cmd/inspector@latest failed"
  assert_contains "summary flags Inspector as pending" "$out" "Inspector: not installed"
  assert_contains "the rest of the bootstrap still ran" "$out" "applying macOS defaults"
  teardown
}

test_fabrica_and_inspector_leave_no_temp_files_on_success() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_eq "no clone/tarball directory survives a successful install" "0" \
    "$(find "$TMP/tmp" -maxdepth 1 -name 'fabrica-install.*' | wc -l | tr -d ' ')"
  # Not "Everything applied cleanly" - with no TTY and no gh login this
  # run always has git identity and gh pending. What matters here is that
  # neither tool is among them.
  out=$(cat "$TMP/out.log")
  case "$out" in
    *"Fabrica: not installed"* | *"Inspector: not installed"*)
      fail_count=$((fail_count + 1))
      echo "FAIL - a successful install must not be flagged pending"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - neither tool is flagged pending after a successful install"
      ;;
  esac
  teardown
}

# node and go are what install_fabrica and install_inspector run; the
# Brewfile is the only thing that puts them on a work Mac.
test_brewfile_provides_node_and_go() {
  setup
  assert_contains "Brewfile installs node" "$(cat "$REPO_DIR/work/Brewfile")" 'brew "node"'
  assert_contains "Brewfile installs go" "$(cat "$REPO_DIR/work/Brewfile")" 'brew "go"'
  teardown
}

test_no_username_hardcoded_in_source() {
  # Static check, not a run_bootstrap scenario: the *code* must never
  # hard-code the personal username, independent of where this particular
  # clone happens to live on disk (which will legitimately contain
  # whatever the cloning user's home directory is).
  #
  # GitHub owner references are carved out, and only those: Fabrica and
  # Inspector live at github.com/inactdev/{fabrica,inspector}, which is
  # the repositories' own identity and cannot be parameterized away the
  # way a home directory can. The carve-out is deliberately narrow - it
  # matches the owner only where it directly follows a github.com host or
  # a `github:` spec prefix - so a bare `inactdev` used as a username or
  # a home-directory component anywhere in this code still fails the test.
  hits=$(mktemp)
  if grep -RIn --exclude='*.test.sh' -e '/Users/inactdev' -e 'inactdev' \
    "$SCRIPT_DIR" "$REPO_DIR/run.sh" 2>/dev/null |
    grep -v -e 'github\.com[:/]inactdev/' -e 'github:inactdev/' >"$hits"; then
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
test_brewfile_provides_node_and_go
test_fabrica_installed_via_clone_then_pack
test_fabrica_never_installed_from_a_git_spec
test_inspector_installed_with_go_install_latest
test_fabrica_clone_failure_warns_and_continues
test_fabrica_npm_failure_warns_and_continues
test_inspector_failure_warns_and_continues
test_fabrica_and_inspector_leave_no_temp_files_on_success
test_idempotent_rerun

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
