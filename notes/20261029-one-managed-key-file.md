# One key file for every Fabrica and Inkwell job

`modules/managed-key-file.nix` + `modules/managed-key-file.sh`, with the
canonical path defined in `modules/managed-paths.nix` and read from there by
`modules/inkwell-linux.nix` (inkwell#46). What follows is only the decisions
a future session would otherwise re-litigate; the mechanism is in the
script's own header, and the user-facing description is in `README.md`'s "One
key file for every Fabrica and Inkwell job".

## `~/.fabrica/brain.env` is canonical, `~/.inkwell/env` is a symlink to it

The captain's ruling on the issue. Fabrica was reading that path first, and a
key file is named for whoever has to find it rather than for whichever job
was written last - so the Inkwell path became a link rather than the other
way round, and no third path (`~/.config/inact/env` and the like) was
invented.

`modules/inkwell-linux.nix` names the **canonical** path in
`EnvironmentFile=` and `ExecStartPre=`, not the link, even though either
would work (`modules/inkwell-key-file.sh` stats with `-L` precisely so a
symlinked key file is judged by the file systemd will read). The reason is
the refusals: every one of them names the path it was given and prints the
commands that fix it, and a human sent to edit `~/.inkwell/env` would be
editing through a link - or, worse, following `install -m 600 /dev/null
~/.inkwell/env` and replacing the link with an empty file. The link exists
for things that already reach for the old path, not as the name anything new
should use.

## Why a shell step and not `home.file` + `mkOutOfStoreSymlink`

home-manager can declare that symlink in one line, and it is the wrong tool
twice:

- it cannot create `~/.fabrica/brain.env`, and it cannot give anything
  outside the store a mode - "placed with mode 600" is most of what the
  issue asked for;
- its answer to an unmanaged file already sitting at the link path is to
  rename it to `<path>.hm-backup` (every `home-linux` switch passes
  `-b hm-backup`, and `personal-mac` sets `backupFileExtension`). For a file
  holding a key that leaves a *second copy of the key on disk* - the exact
  smell the issue exists to end, reintroduced by the fix.

A shell step can instead be lossless-or-refuse, and can say which it did.

## Every write is provably lossless, or is not made

This is the part to preserve if the script is ever rewritten. A key file is
never moved, overwritten or deleted unless the key demonstrably survives:

- **byte-identical duplicate** → removed, replaced by the symlink. The bytes
  are in the file the link resolves to, verified with `cmp -s` rather than
  assumed (which is why the step's PATH carries `diffutils` as well as
  `coreutils`).
- **canonical file holds nothing** (absent, or empty) and the old path holds
  a key → `mv` the key in. Overwriting nothing loses nothing, and a move
  means the key never exists in two files, not even for an instant. This is
  the migration; a copy-then-delete would have been one.
- **two different non-empty key files** → neither touched, by name, with the
  `diff`/edit/`rm` that resolve it. A step that guesses here is a step that
  can destroy the only copy of a key.
- **the canonical path is itself a symlink** → refused before anything is
  written. Somebody who has already linked `~/.fabrica/brain.env` →
  `~/.inkwell/env` (the opposite direction to this step's) would otherwise
  get a loop that resolves to nothing, which is worse than either state it
  started from.

The step always exits 0, and that is safe only because it is not the guard:
`modules/inkwell-key-file.sh` is, running from the service's
`ExecStartPre` before every single start.

It is silent when there is nothing to do, which matters more here than it
looks: the self-apply job (`home/.local/bin/dotfiles-auto-apply`) runs a
switch every 30 minutes, so anything this printed routinely would be printed
into that log 48 times a day. The flip side is deliberate - a refusal *does*
repeat every 30 minutes until a human resolves it, the same bargain
`modules/inkwell-linux.nix` makes with `StartLimitIntervalSec=0`.

## A placed file changes which refusal is the common one

The guard's "there is no key file at ..." used to be what a new box saw.
Now the switch places the file empty, so the common refusal is "... is
empty, so there is no key in it". Two consequences:

- the `-` in `EnvironmentFile=-...` stays. It covers a *missing* file;
  systemd loads an empty one without complaint, so the guard is what
  catches the state the switch now leaves behind.
- `checkInkwellKeyFile` names `placeManagedKeyFile` in its `entryAfter`.
  Both entries are otherwise merely `entryAfter [ "writeBoundary" ]`, which
  orders neither relative to the other, and the one switch where that
  matters is the first one on a box - where the check would otherwise report
  a missing key file that had just been placed.

## The two hosts, and the one that is only a rehearsal

`personal-mac` and `home-linux` compose the module: both run Fabrica jobs,
and `home-linux` also runs the backend. `ci-linux` composes it too, so the
step's *command line* is interpreted by a real activation in CI - the only
check that can catch the `PATH=...`-as-command-name class of bug
(`notes/20261021-activation-step-env-path.md`), which no hermetic test can
see. Codespaces deliberately do not: a container has neither job, so it has
no business being handed a key-file path.

One thing this change did **not** do: `modules/inkwell.nix`, the Mac's
launchd agent, still passes the backend no key file at all - it never did,
launchd has no `EnvironmentFile=` equivalent, and giving it one needs a
wrapper that reads the file and `exec`s the binary. The Mac now has the
managed key file and the symlink (Fabrica's jobs read them), but wiring the
Mac's *backend* to it is a separate change, and one that is only worth
making while that agent is still composed at all - see the note in
`README.md` about dropping it once the notes have moved to the Linux box.
