#!/usr/bin/env bash
# Test suite for work/codespace-bootstrap.sh (the codespace-work no-nix
# path). Runs the real script against mocked apt-get/dpkg/sudo/curl/npm on
# a hermetic PATH and a scratch HOME, so it never touches real apt
# packages, a real download, or this machine's real ~/.zshrc / ~/.claude /
# ~/AGENTS.md - safe to run any time, by anyone, with no side effects
# outside a temp dir. This does NOT exercise a real package install on a
# real Codespaces machine - see install.container-test.sh for the real
# end-to-end container run (also the only place that proves Nix itself is
# never installed on this path).
#
# Usage: bash work/codespace-bootstrap.test.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
SCRIPT="$SCRIPT_DIR/codespace-bootstrap.sh"

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
      printf 'FAIL - %s\n  must not contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack"
      ;;
    *)
      pass_count=$((pass_count + 1))
      printf 'ok - %s\n' "$desc"
      ;;
  esac
}

# --- mocks ------------------------------------------------------------------
# apt-get: logs every call, and for `install -y PKG...` drops a no-op stub
# binary into $MOCK_DIR (on PATH) for packages this script expects to find
# on PATH afterward, plus a dpkg marker so mocked `dpkg -s` reports it
# installed - close enough to the real post-install state for this
# script's own command -v / dpkg -s gates to branch correctly, without an
# actual network install.
mock_bin() {
  local dir="$1"
  cat >"$dir/apt-get" <<'MOCK'
#!/bin/sh
echo "apt-get $*" >>"$FIXTURES/apt.log"
if [ "$1 $2" = "update -y" ]; then
  exit 0
fi
if [ "$1" = "install" ]; then
  shift 2 # drop "install -y"
  for pkg in "$@"; do
    case "$pkg" in
      --no-install-recommends) continue ;;
    esac
    mkdir -p "$FIXTURES/dpkg-installed"
    : >"$FIXTURES/dpkg-installed/$pkg"
    case "$pkg" in
      git) bin=git ;;
      jq) bin=jq ;;
      ripgrep) bin=rg ;;
      fd-find) bin=fdfind ;;
      direnv) bin=direnv ;;
      rbenv) bin=rbenv ;;
      zsh) bin=zsh ;;
      gh) bin=gh ;;
      unzip) bin=unzip ;;
      nodejs) bin=node ;;
      golang-go) bin=go ;;
      python3) bin=python3 ;;
      *) bin="" ;;
    esac
    if [ "$bin" = "gh" ]; then
      # `gh auth status` must report "not logged in" - see
      # test_unauthenticated_gh_is_reported_pending - so this can't be
      # the same unconditional no-op stub every other tool gets.
      printf '#!/bin/sh\nif [ "$1 $2" = "auth status" ]; then exit 1; fi\nexit 0\n' >"$MOCK_DIR/gh"
      chmod +x "$MOCK_DIR/gh"
    elif [ -n "$bin" ]; then
      printf '#!/bin/sh\nexit 0\n' >"$MOCK_DIR/$bin"
      chmod +x "$MOCK_DIR/$bin"
    fi
  done
fi
exit 0
MOCK
  cat >"$dir/dpkg" <<'MOCK'
#!/bin/sh
if [ "$1" = "--print-architecture" ]; then
  echo "amd64"
  exit 0
fi
if [ "$1" = "-s" ]; then
  [ -f "$FIXTURES/dpkg-installed/$2" ] && exit 0 || exit 1
fi
exit 0
MOCK
  cat >"$dir/sudo" <<'MOCK'
#!/bin/sh
echo "sudo $*" >>"$FIXTURES/sudo.log"
if [ "$1" = "chsh" ]; then
  exit 0
fi
if [ "$1" = "dd" ] || [ "$1" = "tee" ]; then
  cat >/dev/null
  exit 0
fi
exec "$@"
MOCK
  # No network in this hermetic run: every direct-binary/npm installer
  # (neovim, stylua, ruff, starship, claude-code, prettierd) must fail
  # gracefully and land in the PENDING summary, not abort the script -
  # see test_network_dependent_installs_are_pending_not_fatal.
  cat >"$dir/curl" <<'MOCK'
#!/bin/sh
echo "curl $*" >>"$FIXTURES/curl.log"
exit 1
MOCK
  cat >"$dir/npm" <<'MOCK'
#!/bin/sh
echo "npm $*" >>"$FIXTURES/npm.log"
exit 1
MOCK
  # No standalone gh mock here on purpose: gh must start out genuinely
  # missing so test_apt_tools_installed_when_missing can prove
  # install_gh actually runs - the apt-get mock above creates a working
  # (auth-status-aware) gh stub once "installed", same as a real machine.
  chmod +x "$dir/apt-get" "$dir/dpkg" "$dir/sudo" "$dir/curl" "$dir/npm"
}

setup() {
  TMP=$(mktemp -d)
  MOCK_DIR="$TMP/bin"
  FIXTURES="$TMP/fixtures"
  HOME="$TMP/home"
  mkdir -p "$MOCK_DIR" "$FIXTURES" "$HOME"
  mock_bin "$MOCK_DIR"
  : >"$FIXTURES/apt.log"
  : >"$FIXTURES/sudo.log"
  : >"$FIXTURES/curl.log"
  : >"$FIXTURES/npm.log"
  # Real coreutils this script relies on that aren't the thing under
  # test: git/jq (once "installed", also used for the git-config
  # assertions below) come from the real system via symlink, same
  # pattern as work/bootstrap.test.sh.
  ln -s "$(command -v git)" "$MOCK_DIR/git"
  ln -s "$(command -v jq)" "$MOCK_DIR/jq"
  ln -s "$(command -v tar)" "$MOCK_DIR/tar"
  ln -s "$(command -v whoami)" "$MOCK_DIR/whoami"
}

teardown() {
  rm -rf "$TMP"
}

run_bootstrap() {
  # Hermetic PATH: only the mocks plus core coreutils, so a bug can never
  # apt-install a real package, hit the real network, or touch this
  # machine's real dotfiles. MOCK_DIR here isn't for codespace-bootstrap.sh
  # itself (it never reads that var) - it's for the mocked apt-get *it*
  # spawns, which needs $MOCK_DIR in ITS environment to know where to drop
  # each package's stub binary. The PATH="$MOCK_DIR:..." expansion below
  # reads the enclosing shell's $MOCK_DIR (already set by setup()), not
  # this line's own prefix assignment - shellcheck (SC2097/SC2098) can't
  # tell those two uses apart, hence the disable.
  # shellcheck disable=SC2097,SC2098
  HOME="$HOME" FIXTURES="$FIXTURES" MOCK_DIR="$MOCK_DIR" \
    PATH="$MOCK_DIR:/usr/bin:/bin" "$SCRIPT" "$REPO_DIR" </dev/null
}

# --- tests --------------------------------------------------------------

test_apt_tools_installed_when_missing() {
  setup
  # git/jq are deliberately pre-present (see setup's real symlinks) since
  # this script always needs a working git for its own git-config calls -
  # exactly matching reality, where Codespaces always has git already
  # (GitHub itself used it to clone the repo). Everything else here has
  # no such bootstrapping dependency and is genuinely missing.
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  for pkg in ripgrep fd-find direnv rbenv gh zsh zsh-autosuggestions zsh-syntax-highlighting; do
    assert_contains "apt installs $pkg" "$(cat "$FIXTURES/apt.log")" "install -y --no-install-recommends $pkg"
  done
  assert_eq "fd symlinked from fdfind" "$MOCK_DIR/fdfind" "$(readlink "$HOME/.local/bin/fd")"
  teardown
}

test_already_present_tools_are_not_reinstalled() {
  setup
  # Deliberately excludes git/jq: setup() already symlinks the real
  # binaries there, and overwriting a symlink target with `>` follows the
  # link - pointing that at a real system git/jq would clobber it. Every
  # other tool here is a fresh mock file, never a symlink, so this is safe.
  for tool in rg fd direnv rbenv gh zsh node go python3; do
    printf '#!/bin/sh\nexit 0\n' >"$MOCK_DIR/$tool"
    chmod +x "$MOCK_DIR/$tool"
  done
  mkdir -p "$FIXTURES/dpkg-installed"
  : >"$FIXTURES/dpkg-installed/zsh-autosuggestions"
  : >"$FIXTURES/dpkg-installed/zsh-syntax-highlighting"
  out=$(run_bootstrap 2>&1) || true
  assert_eq "apt-get install never called for already-present tools" "" "$(cat "$FIXTURES/apt.log")"
  assert_contains "summary lists git as already present" "$out" "Already present, skipped:"
  teardown
}

test_network_dependent_installs_are_pending_not_fatal() {
  setup
  out=$(run_bootstrap 2>&1)
  code=$?
  assert_eq "script still exits 0 when downloads fail" "0" "$code"
  assert_contains "neovim reported pending" "$out" "could not install: neovim"
  assert_contains "summary flags still-needs-attention" "$out" "Still needs attention:"
  teardown
}

test_no_git_clone_in_source() {
  setup
  # Excludes comment-only lines (this file's own comments explain the
  # no-clone constraint using the words "git clone") - looking for a real
  # invocation, not prose.
  if grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -n 'git[[:space:]]\+clone' >"$TMP/hits"; then
    fail_count=$((fail_count + 1))
    echo "FAIL - codespace-bootstrap.sh must never clone a repository:"
    cat "$TMP/hits"
  else
    pass_count=$((pass_count + 1))
    echo "ok - no git clone in codespace-bootstrap.sh"
  fi
  teardown
}

test_symlinks_point_into_repo_no_ghostty() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_eq "nvim config symlinked" "$REPO_DIR/home/.config/nvim" "$(readlink "$HOME/.config/nvim")"
  assert_eq "starship config symlinked" "$REPO_DIR/home/.config/starship.toml" "$(readlink "$HOME/.config/starship.toml")"
  assert_eq "AGENTS.md symlinked" "$REPO_DIR/home/AGENTS.md" "$(readlink "$HOME/AGENTS.md")"
  assert_eq "CLAUDE.md symlinked to AGENTS.md" "$REPO_DIR/home/AGENTS.md" "$(readlink "$HOME/.claude/CLAUDE.md")"
  if [ ! -e "$HOME/.config/ghostty" ]; then
    pass_count=$((pass_count + 1))
    echo "ok - no ghostty symlink (no GUI terminal in a container)"
  else
    fail_count=$((fail_count + 1))
    echo "FAIL - no ghostty symlink"
  fi
  teardown
}

test_zshrc_and_claude_settings_linked() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_eq "zshrc symlinked to the shared work/zshrc (also used by the Mac work host)" \
    "$REPO_DIR/work/zshrc" "$(readlink "$HOME/.zshrc")"
  assert_eq "claude settings symlinked to the shared work variant" \
    "$REPO_DIR/work/claude-settings.json" "$(readlink "$HOME/.claude/settings.json")"
  teardown
}

test_git_config_set() {
  setup
  run_bootstrap >"$TMP/out.log" 2>&1 || true
  assert_eq "push.autoSetupRemote set" "true" "$(HOME="$HOME" git config --global push.autoSetupRemote)"
  assert_eq "core.editor set" "nvim" "$(HOME="$HOME" git config --global core.editor)"
  teardown
}

test_missing_git_identity_is_reported_pending_not_prompted() {
  setup
  out=$(run_bootstrap 2>&1) || true
  assert_eq "no git user.name set" "" "$(HOME="$HOME" git config --global user.name 2>/dev/null || true)"
  assert_contains "summary flags git identity as pending" "$out" "git identity"
  teardown
}

test_existing_git_identity_is_preserved_and_not_pending() {
  setup
  HOME="$HOME" git config --global user.name "Someone Else"
  HOME="$HOME" git config --global user.email "someone@work.example"
  out=$(run_bootstrap 2>&1) || true
  assert_eq "existing identity preserved" "Someone Else" "$(HOME="$HOME" git config --global user.name)"
  assert_not_contains "already-configured identity not flagged pending" "$out" "git identity: run git config"
  teardown
}

test_unauthenticated_gh_is_reported_pending() {
  setup
  out=$(run_bootstrap 2>&1) || true
  assert_contains "summary flags GitHub login as pending" "$out" "GitHub login"
  teardown
}

test_summary_states_macos_only_tools_skipped() {
  setup
  out=$(run_bootstrap 2>&1) || true
  assert_contains "summary names ghostty as deliberately skipped" "$out" "ghostty"
  assert_contains "summary names docker-desktop as deliberately skipped" "$out" "docker-desktop"
  teardown
}

test_summary_states_neovim_plugins_not_synced() {
  setup
  out=$(run_bootstrap 2>&1) || true
  assert_contains "summary states plugins are not pre-synced" "$out" "not synced: neovim plugins"
  teardown
}

# --- shared with work/bootstrap.sh, not duplicated ---------------------------
# The whole point of sourcing work/bootstrap.sh instead of copying it:
# these must be the exact same function objects, so a future edit to
# either script's copy is impossible - there's only one copy. A test that
# only checked *behavior* (e.g. "nvim gets symlinked") would still pass
# against a second hand-copied implementation that quietly drifted from
# the first, so this compares `declare -f` source text directly instead.

test_shared_functions_are_the_same_function_not_a_copy() {
  setup
  local mac_defs codespace_defs fn
  for fn in link_with_backup install_symlinks install_zshrc \
    install_claude_settings configure_git_identity configure_git \
    print_git_gh_pending; do
    mac_defs=$(
      # shellcheck disable=SC1091
      source "$REPO_DIR/work/bootstrap.sh"
      declare -f "$fn"
    )
    codespace_defs=$(
      # shellcheck disable=SC1090,SC1091
      source "$SCRIPT" 2>/dev/null
      declare -f "$fn"
    )
    assert_eq "$fn: codespace-bootstrap.sh's copy is byte-identical to work/bootstrap.sh's (via source, not a hand copy)" \
      "$mac_defs" "$codespace_defs"
  done
  teardown
}

test_codespace_bootstrap_sources_work_bootstrap() {
  setup
  # shellcheck disable=SC2016 # deliberately unexpanded - checking that
  # this literal text appears in the script, not evaluating it.
  assert_contains "codespace-bootstrap.sh sources work/bootstrap.sh" \
    "$(cat "$SCRIPT")" 'source "$CODESPACE_BOOTSTRAP_DIR/bootstrap.sh"'
  teardown
}

test_codespace_bootstrap_does_not_redefine_shared_functions() {
  setup
  local fn hits
  hits=""
  for fn in link_with_backup install_symlinks install_zshrc \
    install_claude_settings configure_git_identity configure_git \
    print_git_gh_pending; do
    if grep -qE "^${fn}\(\)" "$SCRIPT"; then
      hits="$hits $fn"
    fi
  done
  assert_eq "no shared function is redefined locally in codespace-bootstrap.sh" "" "$hits"
  teardown
}

test_apt_tools_installed_when_missing
test_already_present_tools_are_not_reinstalled
test_network_dependent_installs_are_pending_not_fatal
test_no_git_clone_in_source
test_symlinks_point_into_repo_no_ghostty
test_zshrc_and_claude_settings_linked
test_git_config_set
test_missing_git_identity_is_reported_pending_not_prompted
test_existing_git_identity_is_preserved_and_not_pending
test_unauthenticated_gh_is_reported_pending
test_summary_states_macos_only_tools_skipped
test_summary_states_neovim_plugins_not_synced
test_shared_functions_are_the_same_function_not_a_copy
test_codespace_bootstrap_sources_work_bootstrap
test_codespace_bootstrap_does_not_redefine_shared_functions

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
