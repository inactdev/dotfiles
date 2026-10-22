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
# One section at the tail is not about install.sh at all: it reuses the
# same container (and the Nix the personal-posture install put in it) to
# run a real `home-manager switch` of flake.nix's
# homeConfigurations."ci-linux", as a separate throwaway user with a
# scratch HOME. That is the only check anywhere in this repo that actually
# executes the activation steps in modules/fabrica.nix,
# modules/inspector.nix and modules/linux.nix (the two sync steps, and the
# one that enables linger for the user whose timer applies the dotfiles) -
# see the comment block above it for why nothing cheaper can.
#
# Requires Docker. Usage: bash install.container-test.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
IMAGE="ubuntu:24.04"
CONTAINER="dotfiles-install-rehearsal-$$"
BUNDLE_DIR="$(mktemp -d)"
BUNDLE="$BUNDLE_DIR/dotfiles.bundle"
# The container user the ci-linux activation at the tail of this script
# runs as. This string MUST equal flake.nix's `ciUser`: home-manager
# refuses to activate when $HOME is not the home.homeDirectory its
# configuration was evaluated with, and that option is derived from the
# username in modules/core.nix.
CI_USER="ci-activation"
CI_HOME="/home/$CI_USER"

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

# gcc is for the $CI_USER section at the tail of this script, not for
# either posture, and it is now insurance rather than a requirement:
# modules/inspector-sync.sh sets CGO_ENABLED=0, so its `go install` asks
# for no C compiler - and an apt-installed one would be invisible to it
# anyway, since that activation step runs on a PATH of store packages
# only. It stays because a bare ubuntu:24.04 is the only host in this
# picture with no compiler at all (macOS has clang from the Xcode command
# line tools, the home Ubuntu box has gcc from apt), so any dependency
# that falls back to building a native addon would fail here for a reason
# no real machine has, which is noise rather than a finding.
docker exec "$CONTAINER" bash -c '
  set -e
  apt-get update -y >/tmp/apt.log 2>&1
  apt-get install -y --no-install-recommends sudo curl git ca-certificates xz-utils gcc >>/tmp/apt.log 2>&1
  for u in codespace-personal codespace-work; do
    useradd -m -s /bin/bash "$u"
    echo "$u ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$u"
  done
'

# $CI_USER is created separately from the two posture users and used only
# at the tail of this script. Deliberately no sudoers entry: the ci-linux
# activation is a plain user-level home-manager switch against the
# nix-daemon the personal-posture install already started, and withholding
# root is one more way this section cannot disturb anything the posture
# assertions above depend on.
docker exec "$CONTAINER" useradd -m -s /bin/bash "$CI_USER"

# git bundle, not a plain COPY/cp: this repo is normally checked out as a
# linked worktree whose .git is a pointer file to an absolute host path
# that does not exist inside the container. It bundles HEAD, not the
# working tree, so a local run only exercises committed changes.
echo "==> bundling repo into the container"
git -C "$SCRIPT_DIR" bundle create "$BUNDLE" HEAD >/dev/null
ORIGIN_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "https://github.com/inactdev/dotfiles.git")"
docker cp "$BUNDLE" "$CONTAINER:/tmp/dotfiles.bundle" >/dev/null

for user in codespace-personal codespace-work "$CI_USER"; do
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
COMMON_TOOLS="nvim rg fd jq starship stylua prettierd ruff direnv gh zsh git node go python3 claude"

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
assert "codespace-personal: herdr absent (codespaces never import modules/mac.nix)" \
  tool_absent codespace-personal herdr
assert "codespace-work: herdr on PATH" tool_on_path codespace-work herdr

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

# --- real activation of the Fabrica/Inspector steps (ci-linux host) ---------
# Everything above this line is about install.sh. This section is about
# something install.sh never touches: the two activation steps in
# modules/fabrica.nix and modules/inspector.nix, which no codespace host
# composes (see those files) and which therefore had no CI coverage of any
# kind beyond `nix eval`.
#
# They needed it. Both began with `$DRY_RUN_CMD PATH=...:$PATH bash ...`,
# and a shell only treats `PATH=...` as an assignment when it is the first
# word at parse time - so on every real switch, where $DRY_RUN_CMD expands
# to nothing, `PATH=/nix/store/...` became the command name and the step
# died before reaching the sync script. Neither script had ever run on a
# real machine, and every hermetic test in this repo passed throughout. An
# activation step's command line is only interpreted by a shell at
# activation time, so the only check that can see this is a real
# `home-manager switch` - which is what happens below, against
# flake.nix's homeConfigurations."ci-linux".
#
# Three things about where this sits:
#
#   - last, because it needs the Nix that the personal-posture install
#     above put in this container (and the nix-daemon that install.sh
#     started), and because it must not perturb any assertion before it.
#   - as its own container user with its own scratch HOME, because a
#     second home-manager generation over codespace-personal's HOME would
#     replace the profile every personal-posture assertion above is about.
#   - with no stubbing of either install. Both repositories are public, the
#     container has network, and pointing the steps at fixtures would
#     recreate the exact failure mode this section exists to end: a test
#     that passes while the real thing does not run.
CI_HOST_LOG="$BUNDLE_DIR/ci-linux-activation.log"
echo "==> activating homeConfigurations.ci-linux for real (scratch HOME, throwaway container user)"
# ~/.dotfiles is what modules/core.nix's out-of-store symlinks resolve
# through, set up here the same way install.sh does it for a codespace.
# Sourcing nix-daemon.sh rather than calling the store path directly: it is
# also what sets NIX_SSL_CERT_FILE, which the flake fetch needs.
#
# --impure is not something this host needs - unlike the two codespace
# outputs, nothing in ci-linux reads the environment, which is exactly why
# flake.nix gives it a hardcoded `ciUser`. It is passed because flake.nix's
# `codespaceUser` throws under pure evaluation, so any future
# home-manager/Nix version that forces more of the outputs attrset than the
# one path asked for would fail here for an unrelated host's reason. The
# flag costs nothing and removes that coupling.
#
# USER is named explicitly because this exec does not set it and
# home-manager's own command reads it under `set -u`: with USER unset the
# switch aborts with `USER: unbound variable` before a single activation
# step runs, so every assertion below fails for a reason that has nothing
# to do with what they are checking. install.sh passes USER to its own
# home-manager invocation for the codespace switch as well. HOME is named
# next to it to pin what the rest of this section is relative to - it must
# stay $CI_USER's real home directory, because home-manager refuses to
# activate against any home directory other than the one its configuration
# was evaluated with.
docker exec -u "$CI_USER" -e USER="$CI_USER" -e HOME="$CI_HOME" "$CONTAINER" bash -c '
  set -euo pipefail
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  ln -sfn "$HOME/dotfiles-src" "$HOME/.dotfiles"
  nix run github:nix-community/home-manager/release-26.05#home-manager -- \
    -b hm-backup switch --flake "$HOME/.dotfiles#ci-linux" --impure
' >"$CI_HOST_LOG" 2>&1
CI_HOST_STATUS=$?
cat "$CI_HOST_LOG"

assert "ci-linux: home-manager switch exits 0" [ "$CI_HOST_STATUS" -eq 0 ]

# A zero exit is necessary and nowhere near sufficient. Both steps end in
# `|| echo "<tool>-sync exited non-zero; continuing activation."` entirely
# on purpose - keeping either tool current is never worth losing the rest
# of an activation over - so the broken version of these steps exited 0
# too, every time, having done nothing. That backstop firing is the
# step-level failure signal.
neither_sync_step_hit_its_backstop() {
  ! grep -qE -- '-sync exited non-zero; continuing activation' "$CI_HOST_LOG"
}
assert "ci-linux: neither sync step hit its non-zero backstop" \
  neither_sync_step_hit_its_backstop

# The regression by its own signature, generalized one notch: a shell
# reporting a `VAR=value` word as a command it cannot find. Deliberately
# not a bare search for "No such file or directory", which git, go, npm or
# any other tool a step legitimately runs is entitled to print about
# something of its own; requiring the assignment-shaped word on the same
# line is what makes this specific to the bug and not to the phrase.
no_assignment_was_run_as_a_command() {
  ! grep -qE -- '[A-Za-z_][A-Za-z0-9_]*=[^ ]*: No such file or directory' "$CI_HOST_LOG"
}
assert "ci-linux: no VAR=value word was executed as a command name" \
  no_assignment_was_run_as_a_command

# Proof the scripts ran at all. Every line either sync script prints is
# prefixed with its own name, so a log with no such prefix means the step
# never got as far as the interpreter - the precise symptom of the bug
# above, and the one thing no amount of exit-status checking reveals.
assert "ci-linux: fabrica-sync reported for itself during activation" \
  grep -q "fabrica-sync:" "$CI_HOST_LOG"
assert "ci-linux: inspector-sync reported for itself during activation" \
  grep -q "inspector-sync:" "$CI_HOST_LOG"

# Proof they did real work rather than finding themselves already current:
# this HOME is brand new, so "installing" is the only correct thing either
# step can say on it.
assert "ci-linux: fabrica-sync installed rather than skipping (fresh HOME)" \
  grep -q "fabrica-sync: installing" "$CI_HOST_LOG"
assert "ci-linux: inspector-sync installed rather than skipping (fresh HOME)" \
  grep -q "inspector-sync: installing" "$CI_HOST_LOG"

# And the check that matters most: the tools are actually there afterwards,
# at the two paths modules/managed-paths.nix names and modules/core.nix
# puts on PATH ahead of ~/.local/bin.
managed_tool_installed() {
  local relative_path="$1"
  docker exec -u "$CI_USER" "$CONTAINER" bash -c "[ -x \"\$HOME/$relative_path\" ]"
}
assert "ci-linux: the Inspector step installed an executable ~/go/bin/inspector" \
  managed_tool_installed go/bin/inspector
assert "ci-linux: the Fabrica step installed an executable ~/.npm-global/bin/fabrica" \
  managed_tool_installed .npm-global/bin/fabrica

# Right path, right binary. `go version -m` reads the module path out of
# the binary's own build info - the same source modules/inspector-sync.sh
# compares against origin/main - so this distinguishes the Inspector the
# step installed from anything that merely has the right filename.
inspector_binary_is_upstream_inspector() {
  # go comes from the home-manager profile this activation just built
  # (modules/core.nix installs it), so the profile's bin directory goes on
  # PATH first; sourcing hm-session-vars.sh as well covers a Nix that puts
  # the profile somewhere other than ~/.nix-profile.
  docker exec -u "$CI_USER" "$CONTAINER" bash -c '
    . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" 2>/dev/null
    PATH="$HOME/.nix-profile/bin:$PATH"
    go version -m "$HOME/go/bin/inspector"
  ' 2>/dev/null | grep -q "github.com/inactdev/inspector"
}
assert "ci-linux: ~/go/bin/inspector carries github.com/inactdev/inspector build info" \
  inspector_binary_is_upstream_inspector

# The npm equivalent: the bin entry has to resolve into the package npm
# installed under the managed prefix, which is what proves the global
# install landed there rather than the name happening to exist.
fabrica_bin_resolves_into_the_managed_prefix() {
  local resolved
  resolved="$(docker exec -u "$CI_USER" "$CONTAINER" bash -c \
    'readlink -f "$HOME/.npm-global/bin/fabrica"' 2>/dev/null)"
  case "$resolved" in
    "$CI_HOME/.npm-global/lib/node_modules/fabrica/"*) return 0 ;;
    *)
      echo "  fabrica resolved to: ${resolved:-<not found>}" >&2
      return 1
      ;;
  esac
}
assert "ci-linux: ~/.npm-global/bin/fabrica resolves into the managed npm prefix" \
  fabrica_bin_resolves_into_the_managed_prefix

# Finally, the guarantee the two steps exist to provide, taken from the
# steps' own output: modules/managed-bin-guard.sh asks a fresh login shell
# what it resolves each tool to, and names the shells that answer with the
# managed copy. A fresh *bash* login shell is expected not to - only zsh
# gets the PATH line in modules/core.nix - so this matches the success
# line, not the absence of warnings.
login_shell_runs_managed() {
  grep -q "a fresh login shell runs the managed $1" "$CI_HOST_LOG"
}
assert "ci-linux: a fresh login shell resolves inspector to the managed copy" \
  login_shell_runs_managed inspector
assert "ci-linux: a fresh login shell resolves fabrica to the managed copy" \
  login_shell_runs_managed fabrica

# --- the linger step (modules/linux.nix) ------------------------------------
# The other thing only a real activation can check: modules/linux.nix now
# enables linger for the configured user, because the systemd *user* timer
# it declares only runs while that user's systemd instance is up - without
# linger, a headless box stops applying its dotfiles the moment the last
# session ends, silently.
#
# What this asserts depends on the container, by design, and the condition
# is the module's own definition of "logind cannot exist here" (no
# loginctl, or systemd is not the init system) so the two cannot disagree:
#
#   - no logind (today's ubuntu:24.04 container, where PID 1 is `sleep`):
#     the step must say out loud that it skipped, naming the command and
#     the user. A silent skip is the failure this whole section exists to
#     catch - the switch exiting 0 proves nothing on its own, exactly as
#     with the two sync steps above.
#   - logind present (a container that ever gains systemd, or this file
#     reused against a real box): the step must have actually enabled it,
#     and logind itself - not the log - is what gets asked.
container_has_logind() {
  docker exec "$CONTAINER" bash -c '[ -d /run/systemd/system ] && command -v loginctl >/dev/null 2>&1'
}

linger_step_warned_it_skipped() {
  grep -q "skipped 'loginctl enable-linger $CI_USER'" "$CI_HOST_LOG"
}

# Either wording is a pass: a fresh user is enabled, and a re-run of the
# switch finds it already on. Both are the step reporting linger is on.
linger_step_reported_linger_on() {
  grep -qE "(enabled linger for|linger already enabled for) $CI_USER" "$CI_HOST_LOG"
}

logind_reports_linger_enabled() {
  local linger
  linger="$(docker exec "$CONTAINER" \
    loginctl show-user "$CI_USER" --property=Linger --value 2>/dev/null)"
  if [ "$linger" = "yes" ]; then
    return 0
  fi
  echo "  logind reports Linger=${linger:-<no answer>} for $CI_USER" >&2
  return 1
}

if container_has_logind; then
  assert "ci-linux: the linger step reported linger on for $CI_USER" \
    linger_step_reported_linger_on
  assert "ci-linux: logind reports Linger=yes for $CI_USER after the switch" \
    logind_reports_linger_enabled
else
  assert "ci-linux: the linger step warned it skipped, naming the command and the user" \
    linger_step_warned_it_skipped
fi

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
