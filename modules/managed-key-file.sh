#!/usr/bin/env bash
#
# managed-key-file - one key file on this machine, placed by the switch and
# private from the moment it exists, for every job that needs the captain's
# model key: Fabrica's, and Inkwell's backend's.
#
# The smell this ends (inkwell#46): ~/.inkwell/env had been created by hand
# holding the same key that ~/.fabrica/brain.env already held, so one secret
# sat in two files and rotating it meant remembering both. There is one file
# now - ~/.fabrica/brain.env, canonical because Fabrica was reading it first
# and because a key file is named for whoever has to find it, not for
# whichever job was written last - and Inkwell's old path is a symlink to it.
#
# What this does, and the one thing it deliberately cannot do:
#
#   - it places the *file*, never the key. `install -m 600 /dev/null` creates
#     it already private, so the key is never written into a file that was
#     briefly readable by other accounts, and nothing in ~/.dotfiles ever
#     holds the key itself, encrypted or not (the captain's ruling on
#     inkwell#37). An empty managed file is the finished state of this step;
#     putting a key in it stays a human's job, exactly once per machine.
#   - it tightens a key file it finds readable by other accounts, and says
#     so, because a key that has been exposed is worth a line in the log.
#   - it makes the old Inkwell path a symlink to the canonical file, so
#     anything that still reaches for ~/.inkwell/env - a backend run by
#     hand, an older note, muscle memory - reads the one file.
#
# Every write here is either provably lossless or not made at all. A key
# this cannot account for is never moved, overwritten or deleted:
#
#   - a duplicate that is byte-identical to the canonical file is removed,
#     because the bytes demonstrably survive in the file it is replaced by a
#     link to;
#   - a duplicate whose canonical file holds nothing (absent, or empty) is
#     *moved* into the canonical path, because overwriting nothing loses
#     nothing - this is the migration the issue asks for, and it keeps the
#     key in exactly one file without ever copying it;
#   - two different non-empty key files are a question only a human can
#     answer, so both are left exactly as they are and the refusal names
#     them and the commands that resolve it.
#
# Nothing here ever fails a switch: every refusal is a warning on stderr and
# this exits 0 regardless, like the other activation scripts in this
# directory. That is safe because it is not the guard - the hard refusal
# lives in modules/inkwell-key-file.sh, which the backend's service runs
# before every single start and which will not let it start without a usable
# key. This step's job is to make sure there is only ever one file for that
# guard to be about.
#
# Run as: managed-key-file <canonical-key-file> <compatibility-link>
#
# Both paths come from modules/managed-paths.nix, which holds the one
# definition of them (modules/inkwell-linux.nix names the same canonical
# path in the service's EnvironmentFile=). It runs with the store's
# coreutils and diffutils ahead of PATH, put there by
# modules/managed-key-file.nix: `stat -c`, `readlink -f` and `install -m`
# are the GNU spellings, and on the Mac the system's own BSD versions do not
# answer to them.
set -uo pipefail

canonical=${1:?usage: managed-key-file <canonical-key-file> <compatibility-link>}
link=${2:?usage: managed-key-file <canonical-key-file> <compatibility-link>}

# One message style per stream: what was done goes to stdout, what a human
# has to deal with goes to stderr - and both are prefixed, so a switch log
# says which step is talking (the container rehearsal greps for exactly
# this prefix to prove the step ran at all).
say() { printf 'managed-key-file: %s\n' "$*"; }
warn() { printf 'managed-key-file: %s\n' "$*" >&2; }

# The directory of a path, without `dirname`: the one thing this script must
# manage on a machine with a half-built PATH is its own explanations.
dir_of() {
  local path=$1 dir=${1%/*}
  if [ -z "$dir" ] || [ "$dir" = "$path" ]; then
    printf '%s\n' "."
  else
    printf '%s\n' "$dir"
  fi
}

# Created at 700 when absent, and left strictly alone when it is already
# there. A key file's own 0600 is what keeps the key private; the directory
# mode is a second lock on a door this step does not own - ~/.fabrica holds
# Fabrica's own state besides this file, and tightening a directory somebody
# else's tool created is not this step's call to make.
ensure_dir() {
  local dir=$1
  if [ -d "$dir" ]; then
    return 0
  fi
  if [ -e "$dir" ]; then
    warn "$dir exists and is not a directory, so the key file under it could not"
    warn "be placed. Move whatever that is aside and re-run the switch:"
    warn "  ls -l $dir"
    return 1
  fi
  if ! mkdir -p "$dir"; then
    warn "could not create $dir, so the key file under it could not be placed."
    return 1
  fi
  chmod 700 "$dir" 2>/dev/null || warn "created $dir but could not set its mode to 700."
  return 0
}

# The questions that have to be answered before anything is written, because
# each of them makes every later step wrong rather than merely unnecessary.
#
# The symlink case is the sharp one: a canonical path that is itself a
# symlink - including one somebody has already pointed at ~/.inkwell/env, in
# the opposite direction to this step's - would turn the link below into a
# loop that resolves to nothing, and a key file that resolves to nothing is
# the failure this whole area exists to prevent. So it refuses, and refuses
# before the link is touched.
canonical_shape_is_usable() {
  if [ -L "$canonical" ]; then
    warn "$canonical is itself a symlink, so nothing was placed or linked - the one"
    warn "real key file has to be at that path, or linking $link to it would be a"
    warn "loop. Put the key in the canonical path and drop the link:"
    warn "  ls -l $canonical"
    warn "  \$EDITOR $canonical   # after replacing the link with a real file"
    return 1
  fi
  if [ -e "$canonical" ] && [ ! -f "$canonical" ]; then
    warn "$canonical is not a regular file, so nothing was placed or linked. The"
    warn "key file is a plain file of KEY=value lines - a directory there is"
    warn "somebody else's doing:"
    warn "  ls -ld $canonical"
    return 1
  fi
  # -O rather than a stat of the owner: bash answers this one without a
  # command at all. A file another account owns is not a mode problem that
  # chmod can fix, and it is not the key file this step placed.
  if [ -e "$canonical" ] && [ ! -O "$canonical" ]; then
    warn "$canonical is owned by another account, not by you, so nothing was"
    warn "placed or linked - this is not the key file this configuration manages."
    warn "Check what it is before replacing it:"
    warn "  ls -l $canonical"
    return 1
  fi
  return 0
}

# The migration, and the only path on which a key file is ever moved: the
# canonical file holds nothing, and the old Inkwell path holds something.
# `mv` rather than a copy, so the key does not briefly exist twice, and the
# mode comes right in the step after this one.
#
# A *symlinked* old path is deliberately not migrated here: its target is
# some other file this step knows nothing about, and moving another file's
# contents out from under it is not lossless. The link step below compares
# the two and refuses instead.
migrate_duplicate_into_canonical() {
  if [ -e "$canonical" ] && [ -s "$canonical" ]; then
    return 0
  fi
  if [ -L "$link" ] || [ ! -f "$link" ] || [ ! -s "$link" ] || [ ! -O "$link" ]; then
    return 0
  fi
  if ! mv -f "$link" "$canonical"; then
    warn "could not move the key at $link into $canonical, so both were left as"
    warn "they are."
    return 1
  fi
  say "moved the key from $link into $canonical, which held nothing - it is the"
  say "one key file now, and $link becomes a symlink to it."
  return 0
}

place_canonical() {
  if [ -e "$canonical" ]; then
    return 0
  fi
  if ! install -m 600 /dev/null "$canonical"; then
    warn "could not create $canonical, so there is no key file for Fabrica or"
    warn "Inkwell's backend to read."
    return 1
  fi
  say "placed $canonical, empty and readable only by you (mode 600). It is the"
  say "one key file every Fabrica and Inkwell job on this machine reads - put"
  say "the key in it, one KEY=value line per variable, and nothing else has to"
  say "change when a job wants one more of them:"
  say "  \$EDITOR $canonical"
  return 0
}

# Mode 0600 is what this places, and 0400 passes untouched too, because a key
# a job only ever reads is allowed to be read-only. Anything with a group or
# other bit set is tightened - a key readable by every account on the machine
# is the thing this step is for - and said out loud on stderr, because it
# means the key was exposed until now.
#
# Unreadable mode is a warning and nothing else: there is no chmod that
# follows from an answer nobody got, and the service's own guard
# (modules/inkwell-key-file.sh) fails closed on the same question before the
# backend is ever started.
make_canonical_private() {
  local mode
  mode=$(stat -c '%a' "$canonical" 2>/dev/null) || mode=
  if [ -z "$mode" ] || ! [[ $mode =~ ^[0-7]+$ ]]; then
    warn "could not read $canonical's mode, so nothing could confirm the key in it"
    warn "is private. Check it by hand: ls -l $canonical"
    return 1
  fi
  if [ "$((8#$mode & 8#077))" -eq 0 ]; then
    return 0
  fi
  if ! chmod 600 "$canonical"; then
    warn "$canonical is mode 0$mode - readable by other accounts on this machine -"
    warn "and could not be tightened. Do it by hand: chmod 600 $canonical"
    return 1
  fi
  warn "$canonical was mode 0$mode - readable by other accounts on this machine -"
  warn "and has been tightened to 600. Treat the key in it as having been seen,"
  warn "and rotate it if this is a machine other people have accounts on."
  return 0
}

# `ln -sfn`, never a bare `ln -sf`: -n is what replaces a symlink that points
# at a directory instead of writing *inside* the directory it points at. The
# path is only ever a symlink or a file this has just removed by the time
# this is called, which is the same care run.sh takes over ~/.dotfiles.
relink() {
  if ! ln -sfn "$canonical" "$link"; then
    warn "could not link $link to $canonical."
    return 1
  fi
  return 0
}

# Two different non-empty key files: the one outcome where a human has to
# decide, so neither file is touched and the message is the whole remedy.
refuse_divergent_duplicate() {
  warn "$link holds a key of its own and it is not the one in $canonical, so"
  warn "neither file was touched. There has to be exactly one key file, and"
  warn "$canonical is it - keep whichever lines you want in that file, then drop"
  warn "the duplicate and re-run the switch:"
  warn "  diff $canonical $link"
  warn "  \$EDITOR $canonical"
  warn "  rm $link"
  warn "  ./run.sh rebuild"
  return 1
}

# The old Inkwell path, as a symlink to the canonical file - or a refusal
# that leaves it exactly as it was.
#
# Resolved paths are compared, never `readlink`'s raw text: a hand-made
# relative link (../.fabrica/brain.env) is already correct and must not be
# rewritten, which is the same rule run.sh applies to ~/.dotfiles.
place_link() {
  local target canonical_target
  canonical_target=$(readlink -f "$canonical" 2>/dev/null) || canonical_target=

  if [ -L "$link" ]; then
    target=$(readlink -f "$link" 2>/dev/null) || target=
    if [ -n "$canonical_target" ] && [ "$target" = "$canonical_target" ]; then
      return 0
    fi
    # A dangling link holds nothing, so repointing it can lose nothing.
    if [ ! -e "$link" ]; then
      if relink; then
        say "repointed $link, which was a symlink to nothing, at $canonical."
      fi
      return 0
    fi
    if cmp -s "$link" "$canonical"; then
      if relink; then
        say "repointed $link at $canonical - it pointed at a second copy of the"
        say "same key, which is the thing there is now only one of."
      fi
      return 0
    fi
    refuse_divergent_duplicate
    return 1
  fi

  if [ ! -e "$link" ]; then
    if relink; then
      say "linked $link to $canonical, so both Fabrica and Inkwell's backend read"
      say "one file."
    fi
    return 0
  fi

  if [ ! -f "$link" ]; then
    warn "$link is not a regular file or a symlink, so it was left alone and"
    warn "nothing links to $canonical. Move it aside and re-run the switch:"
    warn "  ls -ld $link"
    return 1
  fi

  if ! cmp -s "$link" "$canonical"; then
    refuse_divergent_duplicate
    return 1
  fi

  # Byte-identical, so removing it loses nothing that is not in the file the
  # link now resolves to. This is the hand-made duplicate from inkwell#46,
  # and this line is what stops there being two of them.
  if ! rm -f "$link"; then
    warn "could not remove the duplicate key file at $link, so it was left in"
    warn "place and nothing links to $canonical."
    return 1
  fi
  if relink; then
    say "removed the duplicate key file at $link, which was byte-identical to the"
    say "key in $canonical, and put a symlink to that file there instead."
  fi
  return 0
}

main() {
  ensure_dir "$(dir_of "$canonical")" || return 0
  canonical_shape_is_usable || return 0
  migrate_duplicate_into_canonical
  place_canonical || return 0
  make_canonical_private
  ensure_dir "$(dir_of "$link")" || return 0
  place_link
  return 0
}

# Silent when there was nothing to do, which is every switch after the first:
# a line per activation saying the key file is still a key file would say
# nothing, and the switch already gets a confirmation from the step that
# checks it (modules/inkwell-linux.nix).
#
# Always exit 0 - see the header: this step is not the guard, and keeping the
# one key file tidy is never worth losing the rest of an activation over.
main
exit 0
