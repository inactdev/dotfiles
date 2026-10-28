# Inkwell's backend as a systemd user service on home-linux

`modules/inkwell-linux.nix` + `modules/inkwell-linux-sync.sh` +
`modules/inkwell-key-file.sh`, the Linux counterpart of
`notes/20261024-inkwell-backend-launchd-agent.md`. Everything in that note
about *building* the backend still applies unchanged - it is the same
`modules/inkwell-sync.sh` on both hosts. What follows is only what differs,
plus the decisions a future session would otherwise re-litigate.

## The key file is the only thing that is allowed to refuse

The backend's key lives at `~/.inkwell/env`, placed by hand once with mode
`600`, and **nothing in this repository holds it, encrypted or not** (the
captain's ruling on inkwell#37). Two mechanisms, and both halves are
load-bearing:

- `EnvironmentFile=-/home/<user>/.inkwell/env` on the service. systemd's
  leading `-` means a missing file is a non-event rather than systemd's own
  error - which is deliberate, because systemd's wording ("Failed to load
  environment files") would otherwise be the only thing in the journal and
  it names no remedy.
- `ExecStartPre=` running `modules/inkwell-key-file.sh`. An `ExecStartPre`
  that exits non-zero means `ExecStart` never runs and the unit is left
  *failed*, which is the behaviour wanted: a key that is missing, empty,
  owned by somebody else or readable by any other account cannot quietly
  become a backend running without one.

`ExecCondition=` was the obvious-looking alternative and is wrong here: a
condition that fails leaves the unit **inactive, not failed, and makes
`systemctl start` report success** - so the activation step that starts it
would see nothing wrong and the backend would be silently not running,
which is the exact state this repository keeps refusing to create.

The guard reads mode and owner with `stat -L`. Neither GNU's nor busybox's
`stat` dereferences by default, a symlink's own mode is always `0777`, and
`EnvironmentFile=` reads *through* a link - so without `-L` every symlinked
key file is refused for a reason that is not true of the file systemd will
actually read. It also fails closed: no `stat`, or a `stat` whose answer is
not an octal mode, is a refusal rather than a shrug.

## Why the unit's text must never change, and what that costs

Same rule as the Mac's plist, same reason (see
`notes/20261021-dotfiles-auto-apply.md`): home-manager restarts exactly
those units whose *text* changed, so the unit names the fixed
`~/go/bin/inkwell-backend` rather than a store path, and therefore **a
rebuilt binary behind an unchanged unit restarts nothing**. Whatever
rebuilds has to restart it.

`modules/inkwell-linux-sync.sh` is that, and it detects the rebuild rather
than being told about it: it reads `stat -c '%i %s %Y'` of the installed
binary, delegates the build, reads it again, and restarts only when the two
differ. The build script installs by renaming a freshly built file into
place, so the inode alone already answers the question - no hash of a 10MB
binary on every switch, and no state file. Two unreadable reads compare
equal, which is the conservative outcome.

One consequence worth knowing: `ExecStartPre` names a store path
(`${pkgs.bash}/bin/bash ${./inkwell-key-file.sh}`), so a nixpkgs bump or an
edit to that script *does* change the unit text and bounce the backend
once. That is correct - it is a real change to how the service starts - and
it is not the every-generation churn the fixed binary path exists to avoid.

## Linger is already somebody else's job

A systemd *user* service needs linger on a headless box for exactly the
reason `notes/20261022-dotfiles-auto-apply-linger.md` gives, and
`modules/linux.nix` already enables it on every `home-linux` switch - as a
step that *fails* the switch when it cannot. So `modules/inkwell-linux.nix`
deliberately does **not** enable linger a second time; it names
`enableLinger` in its install step's `entryAfter` instead, which is also
what gives the backend a user manager to be started in on a box that never
had one. Naming an entry a host does not have is harmless (home-manager's
DAG simply never matches it), so this stays correct wherever the module is
composed.

`reloadSystemd` is named in the same `entryAfter` for the systemd analogue
of the Mac's `setupLaunchAgents` problem: it is home-manager's own step,
`entryAfter [ "linkGeneration" ]`, and it is what has written and read the
unit. Without naming it, a first switch could ask `systemctl` to start a
unit systemd has never heard of. The script still runs `daemon-reload`
itself, because whether home-manager reloads anything depends on
`systemd.user.startServices`, whose default has changed across releases.

## First switch on a new box, in order

1. home-manager writes the unit and (depending on `startServices`) tries to
   start it. The binary does not exist yet, so it fails and is retried every
   ten seconds - the designed path, not a failure.
2. The key-file step says, during the switch, whether `~/.inkwell/env` is
   there and private.
3. The notes step clones the notes repository, if `notesOrigin` is set -
   before anything starts the backend, because once the backend has opened
   its own repository at `~/inkwell-notes`, bringing old notes in is a merge
   and a merge is a human's job.
4. The build step installs the binary and restarts the unit onto it.
5. The serve step publishes `127.0.0.1:8080` on the tailnet address.

`Restart=always` with `RestartSec=10s` and `StartLimitIntervalSec=0`: the
rate limiter is off on purpose, so a transient failure cannot leave the
backend down until the next self-apply half an hour later. The cost is that
a box with no key file yet logs a failed start every ten seconds, which is
why step 2 exists.

## What this change deliberately did not do

The issue says the backend belongs on the Linux box "not the Mac", and
`modules/inkwell.nix` is nevertheless still composed into `personal-mac`.
That is not an oversight: the notes that exist today are in the Mac's
`~/inkwell-notes`, and dropping the module stops the agent that serves them
while the new box starts empty. Removing that one line from `flake.nix` is a
one-line follow-up once the notes have been moved - and removing it stops
the agent but leaves the Mac's `tailscale serve` configuration standing,
because tailscaled keeps that itself and nothing here ever takes one away.

`notesOrigin` ships empty for the same reason nothing else about the notes
is guessed here: where the existing notes should be cloned from was not
stated anywhere, and an empty origin is a correct configuration (the backend
opens its own repository, exactly as on the Mac) rather than a half-built
feature. Setting it is one line in `modules/inkwell-linux.nix`.
