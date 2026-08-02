#!/usr/bin/env bash
# Layer 1 container rehearsal for install.sh's real Codespaces path: runs
# the actual install (Nix, then home-manager switch for both
# codespace-personal and codespace-work) inside a fresh, disposable
# ubuntu:24.04 container standing in for a Codespaces machine - amd64,
# matching both real Codespaces machines and the GitHub Actions runners
# this is wired to run on (see .github/workflows/install-container-test.yml).
#
# Complements install.test.sh, which only covers the pure bash decision
# logic (detect_posture, require_codespaces) without ever touching Nix or a
# real download - the posture -> package-set/settings-file/alias wiring now
# lives in modules/codespace.nix (see flake.nix), so this is the only place
# that actually exercises it end to end, for both postures.
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
# that does not exist inside the container - see AGENTS.md.
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

PERSONAL_REPO="$(origin_owner "$ORIGIN_URL")/some-personal-project"
WORK_REPO="acme-corp/widgets" # deliberately a different owner - see detect_posture in install.sh

echo "==> running install.sh (personal posture)"
docker exec -u codespace-personal -e CODESPACES=true -e GITHUB_REPOSITORY="$PERSONAL_REPO" "$CONTAINER" \
  bash -c 'cd ~/dotfiles-src && bash install.sh'

echo "==> running install.sh (work posture)"
docker exec -u codespace-work -e CODESPACES=true -e GITHUB_REPOSITORY="$WORK_REPO" "$CONTAINER" \
  bash -c 'cd ~/dotfiles-src && bash install.sh'

# --- assertions --------------------------------------------------------------

# shellcheck disable=SC2016 # deliberately unexpanded here - this is a
# template string, expanded by the *remote* shell each `docker exec` runs.
nix_env_prefix='. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null; . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" 2>/dev/null;'

tool_on_path() {
  local user="$1" tool="$2"
  docker exec -u "$user" "$CONTAINER" bash -c "$nix_env_prefix command -v $tool" >/dev/null 2>&1
}

ghostty_absent() {
  local user="$1"
  ! docker exec -u "$user" "$CONTAINER" bash -c "$nix_env_prefix command -v ghostty" >/dev/null 2>&1
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
  actual="$(docker exec -u "$user" "$CONTAINER" bash -c "$nix_env_prefix zsh -ic 'alias cc'" 2>/dev/null)"
  [ "$actual" = "cc=$expected" ]
}

default_shell_is_zsh() {
  local user="$1"
  docker exec "$CONTAINER" bash -c "getent passwd '$user' | cut -d: -f7" | grep -q '/zsh$'
}

for user in codespace-personal codespace-work; do
  for tool in nvim rg fd fzf jq; do
    assert "$user: $tool on PATH" tool_on_path "$user" "$tool"
  done
  assert "$user: ghostty absent" ghostty_absent "$user"
  assert "$user: default shell is the Nix zsh" default_shell_is_zsh "$user"
done

assert "codespace-personal: ~/.claude/settings.json links codespaces/claude-settings.json" \
  claude_settings_target_matches codespace-personal "codespaces/claude-settings.json"
assert "codespace-work: ~/.claude/settings.json links work/claude-settings.json" \
  claude_settings_target_matches codespace-work "work/claude-settings.json"

assert "codespace-personal: cc alias is --dangerously-skip-permissions" \
  cc_alias_is codespace-personal "claude --dangerously-skip-permissions"
assert "codespace-work: cc alias is plain claude" \
  cc_alias_is codespace-work "claude"

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
