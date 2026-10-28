#!/usr/bin/env bash
#
# inkwell-key-file - is the hand-placed key file for Inkwell's backend there,
# and is it private enough to start the backend with?
#
# The key never enters this repository, encrypted or not. It lives at a fixed
# path outside it - ~/.inkwell/env - put there by hand once, and the backend's
# systemd user service loads it with systemd's own `EnvironmentFile=`. Nothing
# here knows, or needs to know, which variables are in it: the file's own
# KEY=value lines decide that, which is also why the day the backend reads one
# more of them nothing in these dotfiles has to change.
#
# Two call sites, one answer, so that "usable key file" has a single
# definition (see modules/inkwell-linux.nix for both):
#
#   - the service's own ExecStartPre=. A non-zero exit there means systemd
#     never runs the backend and leaves the unit failed, so a key that is
#     missing - or readable by every account on the machine - cannot be the
#     thing nobody noticed.
#   - an activation step of the same module, which runs this during the
#     switch, where a human is actually watching, rather than leaving the
#     only copy of the message in the journal.
#
# Every refusal is therefore written for somebody who has never seen this
# file: it names the path, says what is wrong with it, and gives the exact
# commands that fix it. And every refusal fails closed - a mode this cannot
# read is a refusal, not a shrug.
#
# Run as: inkwell-key-file <path>
set -uo pipefail

file=${1:?usage: inkwell-key-file <path-to-key-file>}

# Everything this script says is a refusal, so there is one message style
# and it goes to stderr - the journal keeps both streams, and an activation
# wants its warnings where warnings go.
warn() { printf 'inkwell-key-file: %s\n' "$*" >&2; }

# Where a stat can be, resolved against fixed locations as well as PATH for
# the same reason modules/linux.nix resolves loginctl that way: this runs
# both from a home-manager activation (whose PATH is its own store packages
# plus whatever the caller had) and from a systemd user service (whose PATH
# is the fixed list that module gives it), and neither is guaranteed to be
# the other. Overridable only so the test suite can exercise the
# fail-closed paths - there is no stat, or it answers something
# unreadable - on a machine that has a perfectly good one.
INKWELL_STAT_CANDIDATES=${INKWELL_STAT_CANDIDATES:-"stat /usr/bin/stat /bin/stat /run/current-system/sw/bin/stat"}

find_stat() {
  local candidate resolved
  # shellcheck disable=SC2086 # INKWELL_STAT_CANDIDATES is a deliberate word-split list
  for candidate in $INKWELL_STAT_CANDIDATES; do
    if resolved=$(command -v "$candidate" 2>/dev/null); then
      printf '%s\n' "$resolved"
      return 0
    fi
  done
  return 0
}

# How to put the file there, named in full every time this refuses: the
# commands are the message. `install -m 600 /dev/null` creates it already
# private, so the key is never written to a file that was briefly readable.
#
# The directory is taken with a parameter expansion rather than `dirname`,
# because the one thing this script must be able to do on a machine with a
# half-built PATH is explain itself.
how_to_place_it() {
  local dir=${file%/*}
  if [ -z "$dir" ] || [ "$dir" = "$file" ]; then
    dir=.
  fi
  warn "  mkdir -p $dir"
  warn "  install -m 600 /dev/null $file"
  warn "  \$EDITOR $file   # one KEY=value line per variable, no quotes needed"
  warn "then start the backend again:"
  warn "  systemctl --user start inkwell-backend.service"
}

main() {
  local stat_bin mode owner

  stat_bin=$(find_stat)
  if [ -z "$stat_bin" ]; then
    warn "could not find a stat command to read $file's permissions with, so"
    warn "nothing could confirm the key file is private and Inkwell's backend"
    warn "was not started. This is a broken PATH rather than a broken key file."
    return 1
  fi

  if [ ! -e "$file" ]; then
    warn "there is no key file at $file, so Inkwell's backend was not started."
    warn "Put the backend's key there yourself - nothing in ~/.dotfiles holds it,"
    warn "encrypted or not, deliberately:"
    how_to_place_it
    return 1
  fi

  if [ ! -f "$file" ]; then
    warn "$file is not a regular file, so Inkwell's backend was not started."
    warn "The key file is a plain file of KEY=value lines - a directory or a"
    warn "socket there is somebody else's doing. Move it aside and place it"
    warn "properly:"
    how_to_place_it
    return 1
  fi

  # -L, so both answers are about the file the name resolves to rather than
  # about a symlink standing in front of it: stat does not dereference on its
  # own (neither GNU's nor busybox's), a symlink's own mode is always 0777,
  # and systemd's EnvironmentFile= reads through the link - so the target's
  # mode is the one that decides who can read the key. A dangling link never
  # reaches here; the existence check above has already refused it.
  mode=$("$stat_bin" -L -c '%a' "$file" 2>/dev/null) || mode=
  owner=$("$stat_bin" -L -c '%u' "$file" 2>/dev/null) || owner=
  if [ -z "$mode" ] || [ -z "$owner" ] || ! [[ $mode =~ ^[0-7]+$ ]]; then
    warn "could not read $file's owner and permissions, so nothing could confirm"
    warn "the key is private and Inkwell's backend was not started."
    return 1
  fi

  # Owner first, because a file somebody else owns is not a permissions
  # problem that chmod can fix - and $EUID rather than `id -u` so this
  # question needs no command at all.
  if [ "$owner" != "$EUID" ]; then
    warn "$file is owned by uid $owner, not by you (uid $EUID), so Inkwell's"
    warn "backend was not started - this is not the key file you placed. Check"
    warn "what it is before replacing it:"
    warn "  ls -l $file"
    return 1
  fi

  # The whole point: no group bits and no other bits, so nothing but this
  # account can read the key. 0600 is what to place it with; 0400 passes too,
  # because a key the backend only ever reads is allowed to be read-only.
  if [ "$((8#$mode & 8#077))" -ne 0 ]; then
    warn "$file is mode 0$mode - readable by other accounts on this machine, so"
    warn "Inkwell's backend was not started. Make it yours alone, then start it:"
    warn "  chmod 600 $file"
    warn "  systemctl --user start inkwell-backend.service"
    return 1
  fi

  if [ ! -s "$file" ]; then
    warn "$file is empty, so there is no key in it and Inkwell's backend was not"
    warn "started. Put the backend's key in it - one KEY=value line per"
    warn "variable - and start it again:"
    warn "  \$EDITOR $file"
    warn "  systemctl --user start inkwell-backend.service"
    return 1
  fi

  # Silent on success, on purpose: this runs before every single start of the
  # service, and a line per start in the journal would say nothing. The
  # activation step is where a confirmation is worth printing, and it prints
  # its own.
  return 0
}

# `if`, not a bare `main`, so the exit status is this script's own answer and
# nothing else: ExecStartPre= reads it as the decision to start the backend
# or not.
if main; then
  exit 0
fi
exit 1
