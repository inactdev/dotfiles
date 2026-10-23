#!/usr/bin/env bash
#
# managed-bin-guard - make sure the copy of a managed command-line tool
# that a fresh login shell finds is the managed one.
#
# Sourced (never run) by modules/inspector-sync.sh and
# modules/fabrica-sync.sh, which each end with
#
#   guard_managed_binary <tool-name> <managed-binary-path>
#
# on every path through them, including the ones that install nothing
# (already current, no network, a failed install): a shadowing copy is
# just as wrong on a machine that had nothing to install today, and that
# is exactly the machine nobody is watching. Putting the two managed bin
# directories ahead of ~/.local/bin on PATH (modules/core.nix) is the fix
# for the ordering; this is the check that the fix held, plus the cleanup
# for the copies that caused the problem in the first place - including
# the one that is not a binary, a leftover `npm link` symlink in the
# user-writable npm prefix (mbg_remove_stale_npm_link).
#
# Four rules it never breaks:
#
#   - it never fails its caller. Every path returns 0, so a shadowing copy
#     that cannot be moved, a shell that cannot be probed, or a stray
#     binary nothing here can reach costs a loud warning and nothing else.
#     The hard stop for "the wrong Inspector would win" is `fabrica
#     doctor`, which refuses to start work; losing the rest of an
#     activation over it would only make a machine less consistent.
#   - it moves aside, never deletes. A shadowing copy under $HOME goes to
#     $XDG_CACHE_HOME/dotfiles-shadowed/<timestamp>/<path relative to
#     $HOME>, and both paths are printed, so a copy moved by mistake is
#     one `mv` from being back. The single exception is a leftover
#     `npm link` symlink, which is removed rather than moved because it
#     holds no content at all - see mbg_remove_stale_npm_link, which also
#     says what it removed and never touches the checkout on the far end.
#   - it never moves anything that resolves into /nix/store. Such a copy
#     is declaratively installed (a nix profile's own bin directory lives
#     under $HOME), so moving it would corrupt a profile and the next
#     switch would put it straight back. It warns instead, naming the
#     path, because the fix belongs in whatever installs it.
#   - it never moves anything when the managed copy is not installed. On a
#     machine where today's install did not happen, the stale copy in
#     ~/.local/bin may be the only one there is, and moving it would leave
#     the machine with none at all.
#
# The scan is bounded by design - every directory on this process's PATH
# and on each probed login shell's PATH, plus the plausible per-user and
# Homebrew bin directories - and is never a recursive walk of $HOME, which
# would put minutes of I/O on the critical path of every switch to find
# something that can only shadow from a directory that is on PATH anyway.
#
# The caller supplies `say` and `warn` (both sync scripts define them with
# their own prefix, so an activation reads as one voice); bare fallbacks
# are defined below for sourcing this on its own, as the test suite does.

# declare -F, not `type`: `say` is a real command on macOS (text to
# speech), so `type say` succeeds on a Mac whether or not the function
# exists - and the fallback would then never be defined.
if ! declare -F say >/dev/null 2>&1; then
  say() { printf 'managed-bin-guard: %s\n' "$*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf 'managed-bin-guard: %s\n' "$*" >&2; }
fi

# The login shells to probe, in the order they are reported. Both, on both
# hosts, deliberately: the guarantee must not depend on which shell is in
# use, so a machine whose zsh resolves the managed copy and whose bash
# does not is a machine this has to talk about.
MBG_SHELLS=${MBG_SHELLS:-"bash zsh"}

# The PATH a probed login shell starts from, before its own startup files
# have their say. Deliberately minimal (and deliberately not this
# process's PATH, which during activation carries Nix store paths a login
# shell would never have): /etc/profile and, on macOS, /etc/zprofile's
# path_helper replace it outright, which is precisely the "fresh" part.
MBG_BASE_PATH=${MBG_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# Where the Nix store is. A copy that resolves below here is never moved
# (see the rules in the header); overridable only so the test suite can
# prove that rule against a scratch directory instead of needing a real
# store path to point at.
MBG_STORE_PREFIX=${MBG_STORE_PREFIX:-/nix/store}

# The npm prefix whose global package directory is checked for a leftover
# `npm link` (see mbg_remove_stale_npm_link). ~/.local because that is
# where such a leftover has actually been found, and because it is the
# user-writable prefix this project reaches for whenever npm's own default
# is not writable - `work/codespace-bootstrap.sh` installs its npm tools
# with `--prefix "$HOME/.local"` for exactly that reason, and an
# `npm link` or `npm install -g` aimed at that prefix puts its package
# entry under it. One path, not a list: it must stay a single word,
# because a home directory with a space in it is a path, not two. If
# another prefix ever needs covering, the function below takes the full
# path, so a second call is the whole change.
MBG_NPM_PREFIX=${MBG_NPM_PREFIX:-$HOME/.local}

# Resolve a path to its canonical one without realpath or `readlink -f`:
# neither is portable (`readlink -f` only reached BSD/macOS recently), and
# this has to behave identically on personal-mac and home-linux. Follows
# the final component's symlink chain by hand, then normalizes the
# directory part with `cd -P`, which resolves every symlinked parent.
# Prints the input unchanged when the directory does not exist, so a
# missing binary still compares as a path rather than as nothing.
mbg_resolve() {
  local path=$1 hops=0 target dir base
  while [ -L "$path" ] && [ "$hops" -lt 16 ]; do
    target=$(readlink "$path" 2>/dev/null) || break
    [ -n "$target" ] || break
    case $target in
      /*) path=$target ;;
      *) path=$(dirname "$path")/$target ;;
    esac
    hops=$((hops + 1))
  done
  dir=$(dirname "$path")
  base=$(basename "$path")
  if dir=$(cd -P "$dir" 2>/dev/null && pwd -P); then
    case $dir in
      /) printf '/%s\n' "$base" ;;
      *) printf '%s/%s\n' "$dir" "$base" ;;
    esac
  else
    printf '%s\n' "$path"
  fi
}

# Every directory worth looking in, one per line, deduplicated and
# existing. $1 is extra colon-separated PATH material to fold in (the
# probed login shells'), on top of the fixed list and this process's own
# PATH.
mbg_candidate_dirs() {
  local extra=${1:-}
  local all dir seen=''
  all="$HOME/.local/bin:$HOME/bin:$HOME/go/bin:$HOME/.npm-global/bin"
  all="$all:$HOME/.cargo/bin:$HOME/.linuxbrew/bin"
  all="$all:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin"
  if [ -n "${HOMEBREW_PREFIX:-}" ]; then
    all="$all:$HOMEBREW_PREFIX/bin"
  fi
  all="$all:${PATH:-}:$extra"

  while [ -n "$all" ]; do
    dir=${all%%:*}
    case $all in
      *:*) all=${all#*:} ;;
      *) all='' ;;
    esac
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    case $seen in
      *"|$dir|"*) continue ;;
    esac
    seen="$seen|$dir|"
    printf '%s\n' "$dir"
  done
}

# Ask one login shell what it resolves a tool to and what its PATH ended
# up as, printing "mbg-which=<answer>" and "mbg-path=<PATH>" lines.
#
# `-l -i`, not just `-l`: a non-interactive login zsh never reads .zshrc,
# which is where home-manager puts modules/core.nix's PATH line, so
# without -i this would answer a question nobody asked. `env -i` with
# nothing but HOME, TERM and a minimal PATH makes it a genuinely fresh
# login environment rather than a copy of the activation's own. Run from
# / so a startup file that reacts to the working directory (core.nix's fnm
# hook looks for a .node-version above it) has nothing to react to. stdin
# from /dev/null so nothing - compinit's insecure-directories question,
# most likely - can block a switch waiting for an answer, and stderr
# dropped because an interactive shell with no terminal is entitled to
# complain about exactly that.
#
# The leading newline matters: a startup file that writes to stdout
# without a trailing newline would otherwise glue its output onto the
# front of the first marker line and hide it.
mbg_probe() {
  local shell_bin=$1 tool=$2 script
  script="printf '\\nmbg-which=%s\\n' \"\$(command -v $tool 2>/dev/null || true)\";"
  script="$script printf 'mbg-path=%s\\n' \"\$PATH\""
  (
    cd / 2>/dev/null || true
    env -i \
      HOME="$HOME" \
      TERM=dumb \
      PATH="$MBG_BASE_PATH" \
      "$shell_bin" -l -i -c "$script" </dev/null 2>/dev/null
  ) || true
}

# One marker's value out of a probe's output ($1), by marker name ($2).
mbg_probe_field() {
  local line
  while IFS= read -r line; do
    case $line in
      "$2"=*) printf '%s\n' "${line#"$2"=}" ;;
    esac
  done <<<"$1"
}

# Move one shadowing copy into the timestamped quarantine directory,
# mirroring its path relative to $HOME so two copies of the same tool
# cannot collide and so what was moved is obvious from where it landed.
mbg_quarantine() {
  local tool=$1 managed=$2 candidate=$3 stamp=$4
  local dest dest_dir
  dest="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles-shadowed/$stamp/${candidate#"$HOME"/}"
  dest_dir=$(dirname "$dest")
  if ! (mkdir -p "$dest_dir" && mv "$candidate" "$dest"); then
    warn "another $tool at $candidate is shadowing the managed one at $managed,"
    warn "and it could not be moved to $dest - move or delete it by hand."
    return 1
  fi
  say "moved another copy of $tool out of the way: $candidate -> $dest"
  return 0
}

# A git checkout of the named npm package, as far as anything here is
# willing to claim: a directory with a repository in it (`.git` is a
# directory in a clone but a file in a worktree, hence -e rather than -d)
# whose package.json declares that name.
#
# Read with the shell's own pattern matching rather than with grep, jq or
# node, because the only commands this file may rely on are the ones its
# callers put on the activation PATH from the Nix store - and that is
# coreutils, which has no grep in it, plus a language runtime (node for
# Fabrica, go for Inspector) that is not the same one on both sides. The
# match needs `"name"` and the quoted name on one line, which holds for a
# formatted package.json and for a minified one alike.
mbg_is_checkout_of() {
  local dir=$1 name=$2
  local line
  [ -e "$dir/.git" ] || return 1
  [ -f "$dir/package.json" ] || return 1
  # `|| [ -n "$line" ]` so a final line with no newline is still read.
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      *'"name"'*'"'"$name"'"'*) return 0 ;;
    esac
  done <"$dir/package.json"
  return 1
}

# Remove the one leftover the scan above cannot see: the global package
# symlink `npm link` writes at <prefix>/lib/node_modules/<tool>.
#
# It needs removing even after the bin shim beside it has been
# quarantined. While a symlink stands where a package directory belongs,
# npm keeps reading that prefix as having the tool installed, an
# `npm install -g` into it fails with ENOTDIR, and `fabrica doctor` fails
# outright and prints `npm unlink -g fabrica` as the fix - on a machine
# whose managed install is perfectly fine, which is exactly the kind of
# wrong answer this file exists to end.
#
# Removed rather than moved aside - the one exception to the header's
# second rule - because there is nothing in it to lose: the link holds no
# content, one `npm link` puts it back, and the checkout it points at,
# where all the actual work lives, is never touched. The conditions are
# correspondingly strict, and anything that fails one of them is warned
# about and left exactly where it is:
#
#   - it must be a symlink. A real directory there is an install, not a
#     link, and removing an install is not this function's business.
#   - its target must still exist and must look like a git checkout of
#     this tool (mbg_is_checkout_of above). A link to anything else is not
#     something this can claim to recognise.
#   - it must be under $HOME, like everything else this file may touch.
#
# Called after the bin scan, deliberately: removing the package link first
# would turn a shim that resolves through it into a dangling symlink, and
# a dangling symlink fails the scan's own `[ -f ] && [ -x ]` test - so it
# would survive, unmoved and unrunnable, in front of the managed copy.
mbg_remove_stale_npm_link() {
  local tool=$1 link=$2
  local target

  [ -L "$link" ] || [ -e "$link" ] || return 0

  case $link in
    "$HOME"/*) ;;
    *)
      warn "a global package entry for $tool sits outside your home directory, at $link."
      warn "left alone - nothing here owns that path."
      return 0
      ;;
  esac

  if [ ! -L "$link" ]; then
    warn "$link is a real directory, not an \`npm link\` symlink, so it was left alone."
    warn "another install of $tool lives there; remove it by hand if it is not wanted."
    return 0
  fi

  target=$(mbg_resolve "$link")
  if ! mbg_is_checkout_of "$target" "$tool"; then
    warn "$link is an \`npm link\` symlink to $target, which is not a git checkout of $tool."
    warn "left alone - only a link to a checkout reads as a leftover here; remove it by hand if it is one."
    return 0
  fi

  if ! rm -f "$link"; then
    warn "a leftover \`npm link\` symlink at $link could not be removed - remove it by hand."
    return 0
  fi
  say "removed a leftover \`npm link\` symlink for $tool: $link -> $target"
  say "the checkout itself was left alone; \`npm link\` in it puts the link back if it was wanted."
  return 0
}

# Report what one login shell resolves the tool to. Prints the shell's
# name on stdout when it is the managed copy (the caller collects those
# into one line) and nothing but warnings otherwise.
mbg_report() {
  local tool=$1 managed_real=$2 shell=$3 found=$4
  local found_real

  if [ -z "$found" ]; then
    warn "a fresh $shell login shell finds no $tool at all: $managed_real is not on its login PATH."
    warn "whatever puts that directory on PATH for $shell is missing: modules/core.nix does it"
    warn "for zsh in its own PATH line, and for bash by enabling programs.bash, whose startup"
    warn "files are what source home-manager's hm-session-vars.sh."
    return 0
  fi

  case $found in
    /*) ;;
    *)
      warn "a fresh $shell login shell resolves $tool to \"$found\", not to a path -"
      warn "an alias or shell function is in front of the managed copy at $managed_real."
      return 0
      ;;
  esac

  found_real=$(mbg_resolve "$found")
  if [ "$found_real" = "$managed_real" ]; then
    printf '%s\n' "$shell"
    return 0
  fi

  warn "a fresh $shell login shell still runs $found for $tool, not the managed copy at $managed_real."
  warn "nothing here can move that copy, so remove it or take $(dirname "$found") off PATH ahead of $(dirname "$managed_real")."
  return 0
}

# The one entry point. $1 is the tool's command name, $2 the path of the
# managed copy of it.
guard_managed_binary() {
  local tool=${1:-} managed=${2:-}
  local managed_real stamp probes='' login_paths='' shell shell_bin probe
  local moved=0 ok_shells='' dir candidate candidate_real found verdict

  # The tool name is interpolated into the script the probed login shells
  # run, so it is checked rather than trusted - both callers pass a
  # literal, and anything else is a bug worth saying out loud.
  case $tool in
    '' | *[!A-Za-z0-9._-]*)
      warn "managed-bin-guard: \"$tool\" is not a plain tool name, so nothing was checked."
      return 0
      ;;
  esac
  if [ -z "$managed" ]; then
    warn "managed-bin-guard: no managed path for $tool, so nothing was checked."
    return 0
  fi

  managed_real=$(mbg_resolve "$managed")

  if [ ! -f "$managed_real" ] || [ ! -x "$managed_real" ]; then
    warn "$managed is not installed, so no other copy of $tool was touched."
    warn "whatever a login shell finds for $tool today is whatever was already there."
    return 0
  fi

  stamp=$(date -u +%Y%m%dT%H%M%SZ) || stamp=unknown

  # Probe first: each login shell's own PATH widens the scan below to the
  # directories that can actually shadow on this machine, including any a
  # ~/.zshrc.local added that nothing here would otherwise know about.
  # shellcheck disable=SC2086 # MBG_SHELLS is a deliberate word-split list
  for shell in $MBG_SHELLS; do
    shell_bin=$(command -v "$shell" 2>/dev/null) || shell_bin=
    if [ -z "$shell_bin" ]; then
      warn "no $shell on PATH, so the $tool a fresh $shell login shell finds was not checked."
      continue
    fi
    probe=$(mbg_probe "$shell_bin" "$tool")
    probes="$probes$shell"$'\t'"$shell_bin"$'\t'"$(mbg_probe_field "$probe" mbg-which)"$'\n'
    login_paths="$login_paths:$(mbg_probe_field "$probe" mbg-path)"
  done

  # Clean up: any other copy of the tool in a directory that could shadow.
  while IFS= read -r dir; do
    candidate=$dir/$tool
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    candidate_real=$(mbg_resolve "$candidate")
    [ "$candidate_real" != "$managed_real" ] || continue

    case $candidate_real in
      "$MBG_STORE_PREFIX"/*)
        warn "another $tool at $candidate resolves into the Nix store ($candidate_real)."
        warn "left alone - it is installed declaratively, so fix whatever installs it."
        continue
        ;;
    esac

    case $candidate in
      "$HOME"/*)
        if mbg_quarantine "$tool" "$managed" "$candidate" "$stamp"; then
          moved=$((moved + 1))
        fi
        ;;
      *)
        warn "another $tool is installed outside your home directory, at $candidate."
        warn "left alone - nothing here owns that path; remove it by hand if it wins."
        ;;
    esac
  done <<<"$(mbg_candidate_dirs "$login_paths")"

  # And the copy that is not a binary at all: a leftover `npm link` in the
  # user-writable npm prefix. After the scan above, never before it (see
  # the function's own comment for why the order is load-bearing).
  mbg_remove_stale_npm_link "$tool" "$MBG_NPM_PREFIX/lib/node_modules/$tool"

  # Verify. A probe from before the cleanup is stale the moment anything
  # moved, so the shells get asked again in that case - and only in that
  # case, since an interactive login shell is not free to start.
  while IFS=$'\t' read -r shell shell_bin found; do
    [ -n "$shell" ] || continue
    if [ "$moved" -gt 0 ]; then
      found=$(mbg_probe_field "$(mbg_probe "$shell_bin" "$tool")" mbg-which)
    fi
    verdict=$(mbg_report "$tool" "$managed_real" "$shell" "$found")
    if [ -n "$verdict" ]; then
      ok_shells="$ok_shells $verdict"
    fi
  done <<<"$probes"

  if [ -n "$ok_shells" ]; then
    say "a fresh login shell runs the managed $tool ($managed_real) in:${ok_shells}."
  fi
  return 0
}
