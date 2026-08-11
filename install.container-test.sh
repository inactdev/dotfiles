#!/usr/bin/env bash
# Layer 1 container rehearsal for install.sh's real Codespaces path: runs
# the actual install - Nix + home-manager for codespace-personal, plain
# apt/npm/direct-binary for codespace-work (work/codespace-bootstrap.sh) -
# inside a fresh, disposable ubuntu:24.04 container standing in for a
# Codespaces machine - amd64, matching both real Codespaces machines and
# the GitHub Actions runners this is wired to run on (see
# .github/workflows/install-container-test.yml).
#
# Complements install.test.sh, which only covers the pure bash decision
# logic (detect_posture, require_codespaces, main's posture dispatch)
# without ever touching Nix, apt, or a real download - the posture ->
# package-set/settings-file/alias wiring now lives in modules/codespace.nix
# (personal) and work/codespace-bootstrap.sh (work), so this is the only
# place that actually exercises either end to end.
#
# Requires Docker. Usage: bash install.container-test.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
IMAGE="ubuntu:24.04"
CONTAINER="dotfiles-install-rehearsal-$$"
BUNDLE_DIR="$(mktemp -d)"
BUNDLE="$BUNDLE_DIR/dotfiles.bundle"

pass_count=0
fail_count=0

assert() {
  local desc="$1"
  shift
  if "$@"; then
    pass_count=$((pass_count + 1))
    printf 'ok - %s\n' "$desc"
  else
    fail_count=$((fail_count + 1))
    printf 'FAIL - %s\n' "$desc"
  fi
}

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$BUNDLE_DIR"
}
trap cleanup EXIT

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for install.container-test.sh - see AGENTS.md" >&2
  exit 1
fi

origin_owner() {
  printf '%s\n' "$1" |
    sed -E 's#^(git@github\.com:|https://github\.com/|ssh://git@github\.com/)##; s#\.git$##' |
    cut -d/ -f1
}

echo "==> starting rehearsal container ($IMAGE, linux/amd64)"
# seccomp=unconfined: Nix's own build sandbox needs to create nested
# user+mount namespaces, which Docker's default seccomp profile blocks -
# this is a throwaway rehearsal container, not a security boundary we rely
# on, so relaxing it here is fine.
docker run -d --platform linux/amd64 --security-opt seccomp=unconfined --name "$CONTAINER" "$IMAGE" sleep infinity >/dev/null

docker exec "$CONTAINER" bash -c '
  set -e
  apt-get update -y >/tmp/apt.log 2>&1
  apt-get install -y --no-install-recommends sudo curl git ca-certificates xz-utils >>/tmp/apt.log 2>&1
  for u in codespace-personal codespace-work; do
    useradd -m -s /bin/bash "$u"
    echo "$u ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$u"
  done
'

# git bundle, not a plain COPY/cp: this repo is normally checked out as a
# linked worktree whose .git is a pointer file to an absolute host path
# that does not exist inside the container. It bundles HEAD, not the
# working tree, so a local run only exercises committed changes.
echo "==> bundling repo into the container"
git -C "$SCRIPT_DIR" bundle create "$BUNDLE" HEAD >/dev/null
ORIGIN_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "https://github.com/inactdev/dotfiles.git")"
docker cp "$BUNDLE" "$CONTAINER:/tmp/dotfiles.bundle" >/dev/null

for user in codespace-personal codespace-work; do
  docker exec -u "$user" "$CONTAINER" bash -c "
    set -e
    git clone -q /tmp/dotfiles.bundle ~/dotfiles-src
    cd ~/dotfiles-src
    git remote remove origin
    git remote add origin '$ORIGIN_URL'
  "
done

# Seed conflicts a real codespace can have before install.sh runs: GitHub's
# own default-branch auto-dotfiles-install step can leave ~/.config/nvim
# behind as a symlink-to-directory, and a base image can ship a ~/.zshrc -
# both paths this profile manages, so install.sh must back them up instead
# of aborting the whole activation. The two seeds cover the two distinct
# mechanisms: the regular-file ~/.zshrc is home-manager's own `-b hm-backup`
# (which MUST precede `switch` - placed after it it's silently dropped),
# while the ~/.config/nvim *symlink* is backup_legacy_dotfile_symlinks in
# install.sh - home-manager's collision check refuses to back up symlinks
# at all (every backup branch in its check-link-targets.sh requires
# `! -L`), so install.sh has to move those aside itself before the switch.
# codespace-work only - work/codespace-bootstrap.sh's own link_with_backup
# (shared with the Mac path) handles a pre-existing symlink by just
# re-pointing it, no equivalent seed needed there.
docker exec -u codespace-personal "$CONTAINER" bash -c '
  set -e
  mkdir -p ~/.config ~/leftover-nvim
  echo "-- leftover" > ~/leftover-nvim/init.lua
  ln -s "$HOME/leftover-nvim" ~/.config/nvim
  echo "# leftover zshrc" > ~/.zshrc
'

PERSONAL_REPO="$(origin_owner "$ORIGIN_URL")/some-personal-project"
WORK_REPO="acme-corp/widgets" # deliberately a different owner - see detect_posture in install.sh

# --- work posture runs FIRST, before Nix has ever touched this container ----
# This ordering is what makes the "work posture never installs Nix" proof
# below actually mean something: the Nix installer's multi-user mode
# writes system-wide profile snippets (e.g. /etc/profile.d/nix.sh) that
# every user in the container would pick up, personal-posture user
# included - so if codespace-personal's Nix install ran first, a
# regression that made the work path start installing Nix could still
# pass a "codespace-work has no nix on PATH" check by accident, since
# /nix would already exist container-wide either way. Checking
# immediately after work's own install, before personal's install has
# had any chance to run, removes that confound entirely.
WORK_INSTALL_LOG="$BUNDLE_DIR/work-install.log"
echo "==> running install.sh (work posture) - before Nix touches this container at all"
docker exec -u codespace-work -e CODESPACES=true -e GITHUB_REPOSITORY="$WORK_REPO" "$CONTAINER" \
  bash -c 'cd ~/dotfiles-src && bash install.sh' >"$WORK_INSTALL_LOG" 2>&1
WORK_INSTALL_STATUS=$?
cat "$WORK_INSTALL_LOG"
assert "install.sh exits 0 (work posture)" [ "$WORK_INSTALL_STATUS" -eq 0 ]

# --- no-Nix / no-clone proof -------------------------------------------------

nix_directory_absent() {
  ! docker exec "$CONTAINER" bash -c '[ -e /nix ]'
}

nix_binary_absent() {
  local user="$1"
  ! docker exec -u "$user" "$CONTAINER" bash -c 'command -v nix' >/dev/null 2>&1
}

# The only .git directory allowed to exist anywhere under the work user's
# HOME is the one the test harness itself created above (git clone of the
# bundle into ~/dotfiles-src, before install.sh ever ran) - anything else
# would mean something install.sh reached (directly, or transitively via
# a tool it invoked) cloned a repository, the one hard requirement this
# whole change exists to satisfy.
no_repo_was_cloned() {
  local user="$1"
  local expected="/home/$user/dotfiles-src/.git" hits
  hits="$(docker exec -u "$user" "$CONTAINER" bash -c \
    'find "$HOME" -maxdepth 6 -name .git 2>/dev/null')"
  if [ "$hits" = "$expected" ]; then
    return 0
  fi
  echo "  unexpected .git directories:" >&2
  echo "$hits" >&2
  return 1
}

assert "no /nix directory exists anywhere in the container yet" nix_directory_absent
assert "codespace-work: nix is not on PATH" nix_binary_absent codespace-work
assert "codespace-work: nothing under HOME was git-cloned besides the test harness's own dotfiles-src checkout" \
  no_repo_was_cloned codespace-work

echo "==> running install.sh (personal posture)"
assert "install.sh exits 0 (personal posture)" \
  docker exec -u codespace-personal -e CODESPACES=true -e GITHUB_REPOSITORY="$PERSONAL_REPO" "$CONTAINER" \
  bash -c 'cd ~/dotfiles-src && bash install.sh'

# --- shared tool-presence assertions -----------------------------------------

# Adds ~/.local/bin (codespace-work's own downloaded binaries - nvim,
# stylua, ruff, starship - and its fd symlink) ahead of a best-effort Nix
# profile source (codespace-personal only; both `.` calls no-op silently
# for the other posture, since neither path exists there). One prefix for
# both postures rather than two, since every check below runs against
# both users anyway.
# shellcheck disable=SC2016 # deliberately unexpanded - a template string
# expanded by the *remote* shell each `docker exec` runs.
env_prefix='export PATH="$HOME/.local/bin:$PATH"; . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null; . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" 2>/dev/null;'

tool_on_path() {
  local user="$1" tool="$2"
  docker exec -u "$user" "$CONTAINER" bash -c "$env_prefix command -v $tool" >/dev/null 2>&1
}

tool_absent() {
  ! tool_on_path "$1" "$2"
}

# On-PATH alone is not evidence for the personal posture: work posture ran
# first in this same container and its apt installs are system-wide, so
# rg/jq/direnv/gh/zsh/git/node/go/python3 (and starship, in /usr/local/bin)
# would resolve for codespace-personal whether or not the home-manager
# profile provided anything. Resolving into /nix/store is what actually
# proves the profile did.
tool_resolves_into_nix_store() {
  local user="$1" tool="$2" resolved
  resolved="$(docker exec -u "$user" "$CONTAINER" bash -c \
    "$env_prefix readlink -f \"\$(command -v $tool)\"" 2>/dev/null)"
  case "$resolved" in
    /nix/store/*) return 0 ;;
    *)
      echo "  $tool resolved to: ${resolved:-<not found>}" >&2
      return 1
      ;;
  esac
}

ghostty_absent() {
  local user="$1"
  ! docker exec -u "$user" "$CONTAINER" bash -c "$env_prefix command -v ghostty" >/dev/null 2>&1
}

claude_settings_target_matches() {
  local user="$1" expected_suffix="$2" actual
  actual="$(docker exec -u "$user" "$CONTAINER" bash -c 'readlink -f "$HOME/.claude/settings.json"' 2>/dev/null)"
  case "$actual" in
    *"$expected_suffix") return 0 ;;
    *)
      echo "  got: $actual" >&2
      return 1
      ;;
  esac
}

cc_alias_is() {
  local user="$1" expected="$2" actual
  # bash -c wrapping matters here, not just quoting style: zsh itself
  # isn't on docker exec's default PATH for either posture (there's no
  # apt zsh on it until $env_prefix's PATH/profile setup runs, or the
  # Nix one for personal) - $env_prefix has to run in a shell FIRST to
  # put zsh on PATH before it can be resolved as the exec target at all.
  #
  # $aliases[cc], not the `alias` builtin: zsh's builtin quotes values
  # that contain spaces (cc='claude --dangerously-skip-permissions'),
  # which only the personal-posture alias does - the raw array avoids
  # that asymmetry.
  actual="$(docker exec -u "$user" "$CONTAINER" bash -c "$env_prefix zsh -ic 'echo -n \"\$aliases[cc]\"'" 2>/dev/null)"
  [ "$actual" = "$expected" ]
}

default_shell_is_zsh() {
  local user="$1"
  docker exec "$CONTAINER" bash -c "getent passwd '$user' | cut -d: -f7" | grep -q '/zsh$'
}

seeded_nvim_backed_up() {
  docker exec -u codespace-personal "$CONTAINER" bash -c \
    '[ "$(readlink "$HOME/.config/nvim.hm-backup")" = "$HOME/leftover-nvim" ]'
}

seeded_zshrc_backed_up() {
  docker exec -u codespace-personal "$CONTAINER" bash -c \
    'grep -q "leftover zshrc" "$HOME/.zshrc.hm-backup"'
}

nvim_config_is_managed() {
  local user="$1"
  docker exec -u "$user" "$CONTAINER" bash -c \
    "[ \"\$(readlink -f \"\$HOME/.config/nvim\")\" = \"\$HOME/dotfiles-src/home/.config/nvim\" ]"
}

# Present on both postures - see work/Brewfile (work) and modules/core.nix
# (personal, via flake.nix's homeConfigurations.codespace-personal); the
# two package lists were built to match on purpose.
COMMON_TOOLS="nvim rg fd jq starship herdr stylua prettierd ruff direnv gh zsh git node go python3 claude"

for user in codespace-personal codespace-work; do
  for tool in $COMMON_TOOLS; do
    assert "$user: $tool on PATH" tool_on_path "$user" "$tool"
  done
  assert "$user: ghostty absent" ghostty_absent "$user"
  assert "$user: default shell is zsh" default_shell_is_zsh "$user"
  assert "$user: nvim config resolves to the repo's home/.config/nvim" nvim_config_is_managed "$user"
done

# fzf is the one tool intentionally NOT shared - see README.md's
# "Deliberately excluded from the work host" list, which this codespace
# path also honors (work/Brewfile never listed it either).
assert "codespace-personal: fzf on PATH" tool_on_path codespace-personal fzf
assert "codespace-work: fzf absent (excluded, matching the Mac work host)" tool_absent codespace-work fzf

for tool in $COMMON_TOOLS fzf; do
  assert "codespace-personal: $tool comes from the home-manager profile, not work's apt installs" \
    tool_resolves_into_nix_store codespace-personal "$tool"
done

assert "codespace-personal: ~/.claude/settings.json links codespaces/claude-settings.json" \
  claude_settings_target_matches codespace-personal "codespaces/claude-settings.json"
assert "codespace-work: ~/.claude/settings.json links work/claude-settings.json" \
  claude_settings_target_matches codespace-work "work/claude-settings.json"

assert "codespace-personal: cc alias is --dangerously-skip-permissions" \
  cc_alias_is codespace-personal "claude --dangerously-skip-permissions"
assert "codespace-work: cc alias is plain claude" \
  cc_alias_is codespace-work "claude"

assert "codespace-personal: seeded ~/.config/nvim symlink backed up as .hm-backup" \
  seeded_nvim_backed_up
assert "codespace-personal: seeded ~/.zshrc backed up as .hm-backup" \
  seeded_zshrc_backed_up

# --- work posture: output says what happened, and a re-run is safe ----------

assert "work install output names the posture and confirms no Nix/clone" \
  grep -q "installing via apt/npm/direct-binary (work posture) - no Nix, no cloned repositories" "$WORK_INSTALL_LOG"
assert "work install output lists deliberately-skipped macOS-only tools" \
  grep -q "Deliberately not installed (macOS-only, no codespace equivalent):" "$WORK_INSTALL_LOG"
assert "work install output states neovim plugins are not pre-synced" \
  grep -q "Deliberately not synced: neovim plugins" "$WORK_INSTALL_LOG"

# Captured *before* the second run rather than asserted empty: what
# idempotency means here is that the second run adds no new backups on
# top of whatever the first legitimately made, not that zero exist. This
# user account starts with no ~/.zshrc at all (useradd -m/skel ships
# .bashrc/.profile/.bash_logout, not .zshrc), so the expected count today
# is zero - but a base image that does ship one would produce exactly one
# backup here, and that would still be correct.
backup_files() {
  docker exec -u codespace-work "$CONTAINER" bash -c \
    'find "$HOME" -maxdepth 3 -name "*.pre-dotfiles-backup" 2>/dev/null | sort'
}
BACKUP_FILES_BEFORE_SECOND_RUN="$(backup_files)"

echo "==> re-running install.sh (work posture) to check idempotency"
SECOND_RUN_LOG="$BUNDLE_DIR/work-install-second-run.log"
docker exec -u codespace-work -e CODESPACES=true -e GITHUB_REPOSITORY="$WORK_REPO" "$CONTAINER" \
  bash -c 'cd ~/dotfiles-src && bash install.sh' >"$SECOND_RUN_LOG" 2>&1
SECOND_RUN_STATUS=$?
cat "$SECOND_RUN_LOG"
assert "install.sh exits 0 on a second work-posture run" [ "$SECOND_RUN_STATUS" -eq 0 ]

second_run_creates_no_new_backups() {
  [ "$(backup_files)" = "$BACKUP_FILES_BEFORE_SECOND_RUN" ]
}
assert "second run creates no new .pre-dotfiles-backup files beyond the first run's" \
  second_run_creates_no_new_backups

# Container-wide /nix presence isn't a meaningful check at this point in
# the suite (personal posture has already run by now and may have left
# /nix behind win or lose; see AGENTS.md for the Apple Silicon/QEMU case
# where it loses) - what
# a second work-posture run must prove instead is that ITS OWN code path
# still never attempts a Nix install, independent of what else already
# exists in the container.
second_run_never_mentions_installing_nix() {
  ! grep -q "installing Nix" "$SECOND_RUN_LOG"
}
assert "second work-posture run's own output never mentions installing Nix" \
  second_run_never_mentions_installing_nix

# The checkout is the source of every symlink this posture installs, so
# nothing the install runs - including third-party installers it pipes to
# sh - may write back through one of those symlinks into it. ~/.zshrc ->
# work/zshrc is the live case: an rc-file-appending installer dirties the
# user's own dotfiles clone, and only shows up from the second run on,
# once the symlink exists.
work_checkout_is_clean() {
  local dirty
  dirty="$(docker exec -u codespace-work "$CONTAINER" bash -c \
    'cd ~/dotfiles-src && git status --porcelain')"
  if [ -z "$dirty" ]; then
    return 0
  fi
  echo "  install.sh wrote back into the checkout:" >&2
  echo "$dirty" >&2
  return 1
}
assert "work posture never writes back into its own checkout (e.g. through the ~/.zshrc symlink)" \
  work_checkout_is_clean

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
