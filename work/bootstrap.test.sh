#!/bin/sh
# Test suite for work/bootstrap.sh (the --no-nix path). Runs the real
# script against mocked brew/defaults/killall/gh/fnm/node commands on a
# hermetic PATH and a scratch HOME, so it never touches real Homebrew
# packages, real macOS defaults, a real fnm's Node downloads, or the real
# ~/.zshrc / ~/.claude / ~/AGENTS.md / ~/.fabrica - safe to run any time,
# by anyone, with no side effects outside a temp dir. This does NOT
# exercise real package installation or a real corporate Mac - see
# README.md for what still needs the real machine.
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
  #
  # `install -g --prefix <p>` reproduces the two things about real npm the
  # launcher logic depends on: it lays the package down at
  # <p>/lib/node_modules/fabrica and links <p>/bin/fabrica to it with a
  # *relative* target (which is what resolve_link has to cope with), and it
  # refuses with EEXIST when something that isn't its own link is already
  # sitting at that bin path. That refusal is npm's real behaviour -
  # bin-links' check-bin.js fails a global, top-level install unless the
  # existing target resolves into the package being installed - and it is
  # exactly why work/bootstrap.sh clears the path first. A mock that
  # silently overwrote would hide the bug that guard prevents.
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
if [ "$1" = install ]; then
  # Fails the install step only, leaving `pack` to succeed - the one way to
  # reach the "a machine that already had fabrica must keep it" path.
  if [ -f "$FIXTURES/npm_install_fail" ]; then
    echo "npm error install of the tarball failed" >&2
    exit 1
  fi
  prefix=
  while [ $# -gt 0 ]; do
    if [ "$1" = --prefix ]; then
      prefix=$2
    fi
    shift
  done
  if [ -n "$prefix" ]; then
    if [ -e "$prefix/bin/fabrica" ] && [ ! -L "$prefix/bin/fabrica" ]; then
      echo "npm error code EEXIST" >&2
      echo "npm error EEXIST: file already exists" >&2
      exit 1
    fi
    mkdir -p "$prefix/lib/node_modules/fabrica/dist" "$prefix/bin"
    printf '#!/usr/bin/env node\n' >"$prefix/lib/node_modules/fabrica/dist/cli.js"
    chmod +x "$prefix/lib/node_modules/fabrica/dist/cli.js"
    ln -sfn ../lib/node_modules/fabrica/dist/cli.js "$prefix/bin/fabrica"
  fi
fi
exit 0
MOCK
  # fnm: faithful enough to make the pinning logic provable, and nothing
  # more. $FIXTURES/fnm_installed is the list of "downloaded" versions.
  #   - `install <v>` adds one, and FAILS when it is already there, which
  #     is what the real fnm does ("version already installed") and the
  #     reason work/bootstrap.sh probes before installing.
  #   - `exec --using=<v> <cmd...>` fails when <v> isn't in that list and
  #     otherwise runs <cmd...>, so the generated launcher can be executed
  #     for real in a test and asserted on.
  # $FIXTURES/fnm_install_fail makes the download fail.
  cat >"$dir/fnm" <<'MOCK'
#!/bin/sh
echo "fnm $*" >>"$FIXTURES/fnm.log"
if [ "$1" = install ]; then
  if grep -qx "$2" "$FIXTURES/fnm_installed" 2>/dev/null; then
    echo "error: Version already installed" >&2
    exit 1
  fi
  if [ -f "$FIXTURES/fnm_install_fail" ]; then
    echo "error: Can't download the requested binary" >&2
    exit 1
  fi
  echo "$2" >>"$FIXTURES/fnm_installed"
  exit 0
fi
if [ "$1" = exec ]; then
  shift
  version=
  while [ $# -gt 0 ]; do
    case "$1" in
      --using=*) version=${1#--using=}; shift ;;
      --) shift; break ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  if ! grep -qx "$version" "$FIXTURES/fnm_installed" 2>/dev/null; then
    echo "error: Can't find requested version: $version" >&2
    exit 1
  fi
  [ $# -eq 0 ] && exit 0
  exec "$@"
fi
exit 0
MOCK
  # node: only ever reached through the fnm mock's exec - by the pinned
  # version probe and by the generated launcher. Logs its argv so the
  # launcher can be shown to hand the right script and the right arguments
  # on, and never runs any real JavaScript.
  cat >"$dir/node" <<'MOCK'
#!/bin/sh
echo "node $*" >>"$FIXTURES/node.log"
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
  chmod +x "$dir/brew" "$dir/defaults" "$dir/killall" "$dir/gh" "$dir/npm" \
    "$dir/go" "$dir/fnm" "$dir/node"
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
  # Stands in for /Applications/Docker.app, which this suite must never
  # read (it would report whatever the machine running the tests happens
  # to have) and could not create anyway. Deliberately NOT created here:
  # "Docker Desktop is missing" is the default state, and the tests that
  # want it present mkdir it themselves.
  DOCKER_APP="$TMP/Applications/Docker.app"
  mkdir -p "$MOCK_DIR" "$FIXTURES" "$HOME" "$TMP/tmp"
  mock_bin "$MOCK_DIR"
  : >"$FIXTURES/brew.log"
  : >"$FIXTURES/defaults.log"
  : >"$FIXTURES/gh.log"
  : >"$FIXTURES/npm.log"
  : >"$FIXTURES/go.log"
  : >"$FIXTURES/go.env.log"
  : >"$FIXTURES/git.log"
  : >"$FIXTURES/fnm.log"
  : >"$FIXTURES/node.log"
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
    DOCKER_APP="$DOCKER_APP" \
    PATH="$MOCK_DIR:/usr/bin:/bin" "$SCRIPT" "$REPO_DIR" </dev/null
}

# A `docker` that does nothing but exist, so check_docker's `command -v`
# half is satisfied without a real Docker anywhere near this run.
mock_docker_cli() {
  cat >"$MOCK_DIR/docker" <<'MOCK'
#!/bin/sh
exit 0
MOCK
  chmod +x "$MOCK_DIR/docker"
}

# Runs the generated ~/.local/bin/fabrica launcher the way a shell would,
# on the same hermetic PATH the bootstrap had - so the fnm it finds is the
# mock, and the "node" it ends up running is the logging stub.
run_fabrica_launcher() {
  FIXTURES="$FIXTURES" PATH="$MOCK_DIR:/usr/bin:/bin" \
    "$HOME/.local/bin/fabrica" "$@" </dev/null
}

# Octal mode of $1. `stat` is the one assertion helper here that has to
# branch on the OS: the suite runs on macOS in CI (BSD stat) and on Linux
# for anyone checking it locally (GNU stat), and the two spell this
# differently with no common flag.
file_mode() {
  if [ "$(uname -s)" = "Darwin" ]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
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

# node and go are what install_fabrica and install_inspector run, and fnm
# is what pins the Node version `fabrica` itself runs on; the Brewfile is
# the only thing that puts any of them on a work Mac.
test_brewfile_provides_node_and_go() {
  setup
  assert_contains "Brewfile installs node" "$(cat "$REPO_DIR/work/Brewfile")" 'brew "node"'
  assert_contains "Brewfile installs go" "$(cat "$REPO_DIR/work/Brewfile")" 'brew "go"'
  assert_contains "Brewfile installs fnm" "$(cat "$REPO_DIR/work/Brewfile")" 'brew "fnm"'
  teardown
}

# work/zshrc is shared verbatim with the codespace-work posture, which has
# no fnm at all - so the eval has to be guarded, exactly like rbenv's.
test_zshrc_loads_fnm_guarded() {
  setup
  zshrc=$(cat "$REPO_DIR/work/zshrc")
  assert_contains "zshrc evaluates fnm env" "$zshrc" 'eval "$(fnm env --use-on-cd --shell zsh)"'
  assert_contains "zshrc guards the fnm eval on fnm being installed" "$zshrc" \
    'if command -v fnm >/dev/null 2>&1; then'
  teardown
}

# --- the pinned Node version -------------------------------------------

test_node_version_installed_through_fnm() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_contains "the pinned Node version is installed with fnm" \
    "$(cat "$FIXTURES/fnm.log")" "fnm install 24.18.0"
  teardown
}

# The whole point of the launcher: `fabrica` names its Node version itself,
# so no .node-version in whatever directory it is run from can change it.
test_fabrica_launcher_pins_the_node_version() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  launcher="$HOME/.local/bin/fabrica"
  if [ -f "$launcher" ] && [ ! -L "$launcher" ] && [ -x "$launcher" ]; then
    pass_count=$((pass_count + 1)); echo "ok - fabrica is an executable launcher, not npm's shim"
  else
    fail_count=$((fail_count + 1)); echo "FAIL - fabrica is an executable launcher, not npm's shim"
  fi
  body=$(cat "$launcher")
  assert_contains "launcher runs the pinned version through fnm exec" "$body" \
    "exec --using=24.18.0 node"
  # An absolute path, not npm's relative '../lib/...' link target: the
  # launcher is run from arbitrary working directories, so a relative entry
  # point would resolve differently every time. Asserted as "node \"/" plus
  # the tail of the path rather than against "$HOME/..." because the script
  # resolves it with `pwd -P`, and on macOS the scratch HOME under
  # /tmp or /var/folders resolves through a symlink to /private/....
  assert_contains "launcher execs an absolute path" "$body" 'node "/'
  assert_contains "launcher execs the CLI npm installed" "$body" \
    "/.local/lib/node_modules/fabrica/dist/cli.js"
  case "$body" in
    *"../lib/node_modules"*)
      fail_count=$((fail_count + 1))
      echo "FAIL - launcher must not carry npm's relative link target"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - launcher carries no relative path"
      ;;
  esac
  teardown
}

# Executed for real (against the mocked fnm and a logging `node` stub), so
# this covers the launcher's actual command line and not just its text:
# right version, right script, and every argument passed through untouched.
test_fabrica_launcher_runs_and_forwards_arguments() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  : >"$FIXTURES/fnm.log"
  : >"$FIXTURES/node.log"
  if run_fabrica_launcher doctor --json >"$TMP/launcher.log" 2>&1; then code=0; else code=$?; fi
  assert_eq "launcher exits 0" "0" "$code"
  assert_contains "launcher asks fnm for the pinned version" \
    "$(cat "$FIXTURES/fnm.log")" "fnm exec --using=24.18.0 node"
  assert_contains "launcher runs the installed CLI with the arguments it was given" \
    "$(cat "$FIXTURES/node.log")" "/.local/lib/node_modules/fabrica/dist/cli.js doctor --json"
  teardown
}

# Re-running must not try to download a version that is already there
# (real fnm exits non-zero for that, which is why the script probes first),
# and the launcher must survive npm's second install - npm refuses to link
# its shim over a file it doesn't own, so the install clears the path first.
test_second_run_reuses_the_installed_node_and_relinks_cleanly() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  if out=$(run_bootstrap 2>&1); then code=0; else code=$?; fi
  assert_eq "second run exits 0" "0" "$code"
  assert_eq "the pinned version is downloaded exactly once" "1" \
    "$(grep -c 'fnm install 24.18.0' "$FIXTURES/fnm.log" | tr -d ' ')"
  assert_contains "the second run says it is already installed" "$out" \
    "Node 24.18.0 already installed"
  assert_contains "and re-pins the launcher" "$out" "fabrica pinned to Node 24.18.0"
  assert_eq "the moved-aside previous launcher is cleaned up" "0" \
    "$(find "$HOME/.local/bin" -name 'fabrica.pre-bootstrap.*' | wc -l | tr -d ' ')"
  case "$out" in
    *"EEXIST"* | *"Fabrica: not installed"* | *"not pinned"*)
      fail_count=$((fail_count + 1))
      echo "FAIL - the second npm install must not trip over the launcher:"
      echo "$out"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - the second npm install replaces the launcher cleanly"
      ;;
  esac
  teardown
}

# The install has to clear the launcher's path before npm runs (npm won't
# link over a file it doesn't own), which must not cost a working machine
# the fabrica it already had when that install then fails.
test_failed_reinstall_restores_the_previous_launcher() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  before=$(cat "$HOME/.local/bin/fabrica")
  : >"$FIXTURES/npm_install_fail"
  if out=$(run_bootstrap 2>&1); then code=0; else code=$?; fi
  assert_eq "bootstrap still exits 0" "0" "$code"
  assert_contains "summary flags Fabrica as pending" "$out" "Fabrica: not installed"
  assert_eq "the launcher that was working is still there, unchanged" "$before" \
    "$(cat "$HOME/.local/bin/fabrica")"
  assert_eq "and nothing was left moved aside" "0" \
    "$(find "$HOME/.local/bin" -name 'fabrica.pre-bootstrap.*' | wc -l | tr -d ' ')"
  teardown
}

# No fnm, no pin - but Fabrica itself is still installed and still runnable
# (on whatever node the shell has), and the summary says what is missing.
test_missing_fnm_warns_and_leaves_npms_own_shim() {
  setup
  rm -f "$MOCK_DIR/fnm"
  if out=$(run_bootstrap 2>&1); then code=0; else code=$?; fi
  assert_eq "bootstrap still exits 0 without fnm" "0" "$code"
  assert_contains "says fnm is missing" "$out" "fnm is not on PATH"
  assert_contains "summary flags the Node pin as pending" "$out" "Node 24.18.0"
  assert_contains "the rest of the bootstrap still ran" "$out" "applying macOS defaults"
  if [ -L "$HOME/.local/bin/fabrica" ]; then
    pass_count=$((pass_count + 1)); echo "ok - npm's own fabrica shim is left in place"
  else
    fail_count=$((fail_count + 1)); echo "FAIL - npm's own fabrica shim is left in place"
  fi
  teardown
}

test_fnm_install_failure_warns_and_continues() {
  setup
  : >"$FIXTURES/fnm_install_fail"
  if out=$(run_bootstrap 2>&1); then code=0; else code=$?; fi
  assert_eq "bootstrap still exits 0 when the Node download fails" "0" "$code"
  assert_contains "says the fnm install failed" "$out" "fnm install 24.18.0 failed"
  assert_contains "summary flags the Node pin as pending" "$out" "Node 24.18.0"
  assert_contains "the rest of the bootstrap still ran" "$out" "applying macOS defaults"
  teardown
}

# --- ~/.fabrica ---------------------------------------------------------

test_fabrica_home_is_created_with_tight_modes_and_config() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_eq "~/.fabrica is private to the user" "700" "$(file_mode "$HOME/.fabrica")"
  assert_eq "brain.env is created" "" "$(cat "$HOME/.fabrica/brain.env")"
  assert_eq "brain.env is readable only by the user" "600" \
    "$(file_mode "$HOME/.fabrica/brain.env")"
  toml=$(cat "$HOME/.fabrica/projects.toml")
  assert_contains "projects.toml declares the caps block" "$toml" "[caps]"
  assert_contains "per-task cap" "$toml" "perTaskUsd = 20"
  assert_contains "per-day cap" "$toml" "perDayUsd = 200"
  assert_contains "projects.toml declares the reader block" "$toml" "[reader]"
  assert_contains "reader vendor" "$toml" 'vendor = "claude-code"'
  assert_contains "reader model" "$toml" 'model = "sonnet"'
  teardown
}

# The invariant that matters most here: this is a bootstrap someone re-runs
# on a machine that is already working, and brain.env holds the one thing
# on it that a human had to go and get by hand.
test_fabrica_home_never_overwrites_existing_content() {
  setup
  mkdir -p "$HOME/.fabrica"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=already-here\n' >"$HOME/.fabrica/brain.env"
  printf '[caps]\nperTaskUsd = 3\nperDayUsd = 7\n' >"$HOME/.fabrica/projects.toml"
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_eq "brain.env is left exactly as it was" "CLAUDE_CODE_OAUTH_TOKEN=already-here" \
    "$(cat "$HOME/.fabrica/brain.env")"
  # Content is never touched; the mode is, every run - a credential file
  # left world-readable is the kind of thing nobody notices until it counts.
  assert_eq "an existing brain.env's mode is tightened anyway" "600" \
    "$(file_mode "$HOME/.fabrica/brain.env")"
  toml=$(cat "$HOME/.fabrica/projects.toml")
  assert_contains "hand-tuned caps are untouched" "$toml" "perTaskUsd = 3"
  case "$toml" in
    *"perTaskUsd = 20"*)
      fail_count=$((fail_count + 1))
      echo "FAIL - an existing [caps] block must not be re-written with our defaults"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - an existing [caps] block is left alone"
      ;;
  esac
  assert_eq "only one [caps] block" "1" "$(grep -c '^\[caps\]' "$HOME/.fabrica/projects.toml" | tr -d ' ')"
  assert_contains "the missing [reader] block is appended" "$toml" "[reader]"
  assert_contains "with its values" "$toml" 'vendor = "claude-code"'
  teardown
}

# A projects.toml someone edited by hand may well not end in a newline;
# appending to it must not glue [reader] onto that last line.
test_fabrica_home_append_survives_a_missing_trailing_newline() {
  setup
  mkdir -p "$HOME/.fabrica"
  printf '[caps]\nperTaskUsd = 3' >"$HOME/.fabrica/projects.toml"
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_eq "the appended block starts on a line of its own" "1" \
    "$(grep -c '^\[reader\]' "$HOME/.fabrica/projects.toml" | tr -d ' ')"
  assert_eq "and the last hand-written line is intact" "1" \
    "$(grep -c '^perTaskUsd = 3$' "$HOME/.fabrica/projects.toml" | tr -d ' ')"
  teardown
}

# --- the two steps only a human can take --------------------------------

test_claude_token_is_reported_as_pending_when_absent() {
  setup
  if out=$(run_bootstrap 2>&1); then code=0; else code=$?; fi
  assert_eq "a missing token is pending, not a failure" "0" "$code"
  assert_contains "summary names the command to run" "$out" "claude setup-token"
  assert_contains "and the variable to set" "$out" "CLAUDE_CODE_OAUTH_TOKEN="
  assert_contains "and the file to put it in" "$out" "/.fabrica/brain.env"
  teardown
}

test_claude_token_already_set_is_not_pending_and_never_printed() {
  setup
  mkdir -p "$HOME/.fabrica"
  printf 'export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-not-a-real-token\n' >"$HOME/.fabrica/brain.env"
  out=$(run_bootstrap 2>&1) || true
  case "$out" in
    *"claude setup-token"*)
      fail_count=$((fail_count + 1))
      echo "FAIL - an already-set token must not be flagged pending"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - an already-set token is not flagged pending"
      ;;
  esac
  # The check reads brain.env; it must never echo what it finds there.
  case "$out" in
    *"sk-ant-not-a-real-token"*)
      fail_count=$((fail_count + 1))
      echo "FAIL - the token value must never appear in bootstrap output"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - the token value never appears in output"
      ;;
  esac
  teardown
}

# Docker Desktop comes from the company's Self-Service app on this host,
# so `brew bundle` must never try to install or upgrade a cask for it -
# the managed copy is the only copy. The check is on the cask line rather
# than the word "docker" so the explanatory comment in the Brewfile is
# free to say why.
test_brewfile_does_not_install_docker_desktop() {
  setup
  brewfile=$(grep -v '^[[:space:]]*#' "$REPO_DIR/work/Brewfile" || true)
  case "$brewfile" in
    *docker*)
      fail_count=$((fail_count + 1))
      echo "FAIL - work/Brewfile must not install Docker; it comes from Self-Service"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - work/Brewfile installs no Docker cask"
      ;;
  esac
  teardown
}

test_docker_present_is_not_flagged_pending() {
  setup
  mock_docker_cli
  mkdir -p "$DOCKER_APP"
  if out=$(run_bootstrap 2>&1); then code=0; else code=$?; fi
  assert_eq "bootstrap exits 0 with Docker installed" "0" "$code"
  assert_contains "says Docker Desktop is already installed" "$out" "Docker Desktop already installed"
  case "$out" in
    *"Docker Desktop: install it"*)
      fail_count=$((fail_count + 1))
      echo "FAIL - an installed Docker Desktop must not be flagged pending"
      ;;
    *)
      pass_count=$((pass_count + 1))
      echo "ok - an installed Docker Desktop is not flagged pending"
      ;;
  esac
  teardown
}

# Missing Docker is a pending item, never a failure: nothing else in the
# bootstrap needs Docker, and installing it is a human step in a GUI app
# that no script here can drive.
test_docker_missing_is_pending_not_a_failure() {
  setup
  if out=$(run_bootstrap 2>&1); then code=0; else code=$?; fi
  assert_eq "bootstrap still exits 0 with Docker missing" "0" "$code"
  assert_contains "summary points at Self-Service" "$out" "Docker Desktop: install it from Self-Service"
  assert_contains "it is listed as pending, not as an error" "$out" "Still needs attention:"
  assert_contains "the rest of the bootstrap still ran" "$out" "applying macOS defaults"
  teardown
}

# The half-installed state check_docker exists to catch: a leftover
# `docker` CLI (a former install, or a colima/podman shim) with no
# Docker.app behind it. Asserted from this direction rather than the
# other because it holds whatever the machine running the suite has on
# its own PATH - the hermetic PATH still ends in /usr/bin:/bin, so a
# system `docker` there would otherwise decide the result. The reverse
# case (app present, CLI absent) is the same `&&`, read the other way.
test_docker_cli_without_the_app_is_still_pending() {
  setup
  mock_docker_cli
  if out=$(run_bootstrap 2>&1); then code=0; else code=$?; fi
  assert_eq "bootstrap still exits 0" "0" "$code"
  assert_contains "a stray docker CLI alone does not count as installed" \
    "$out" "Docker Desktop: install it from Self-Service"
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
test_zshrc_loads_fnm_guarded
test_brewfile_does_not_install_docker_desktop
test_docker_present_is_not_flagged_pending
test_docker_missing_is_pending_not_a_failure
test_docker_cli_without_the_app_is_still_pending
test_fabrica_installed_via_clone_then_pack
test_fabrica_never_installed_from_a_git_spec
test_inspector_installed_with_go_install_latest
test_fabrica_clone_failure_warns_and_continues
test_fabrica_npm_failure_warns_and_continues
test_inspector_failure_warns_and_continues
test_fabrica_and_inspector_leave_no_temp_files_on_success
test_node_version_installed_through_fnm
test_fabrica_launcher_pins_the_node_version
test_fabrica_launcher_runs_and_forwards_arguments
test_second_run_reuses_the_installed_node_and_relinks_cleanly
test_failed_reinstall_restores_the_previous_launcher
test_missing_fnm_warns_and_leaves_npms_own_shim
test_fnm_install_failure_warns_and_continues
test_fabrica_home_is_created_with_tight_modes_and_config
test_fabrica_home_never_overwrites_existing_content
test_fabrica_home_append_survives_a_missing_trailing_newline
test_claude_token_is_reported_as_pending_when_absent
test_claude_token_already_set_is_not_pending_and_never_printed
test_idempotent_rerun

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
