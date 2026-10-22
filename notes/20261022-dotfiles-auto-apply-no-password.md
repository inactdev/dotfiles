# The self-update timer never needs a password, which means the Mac only announces

`home/.local/bin/dotfiles-auto-apply` used to fetch, fast-forward and then
run `./run.sh rebuild` on both Nix hosts. On `personal-mac` that last step
ends in `sudo darwin-rebuild switch`, and a launchd *user* agent has no
terminal for sudo to prompt at, so every run that found new commits logged
`sudo: a terminal is required to read the password` and retried half an
hour later, forever. It now splits by host: `personal-mac` fetches,
fast-forwards and *announces*; `home-linux` still applies by itself.
This note supersedes two paragraphs of
`notes/20261021-dotfiles-auto-apply.md` - the one about needing a
passwordless sudo rule on the Mac, and the one about local-ahead
deliberately never notifying.

**The two obvious ways to make the Mac switch on a timer were both
declined.** A `NOPASSWD` rule for `darwin-rebuild` in `/etc/sudoers.d`
(the cheapest), and a root `launchd.daemons` job in `configuration.nix`
(needs no sudoers edit at all). Both buy an unattended switch by widening
what runs as root without a password on the captain's own machine - which
is the opposite of "never needs a password". Announcing costs one
notification and one line in a log that was already being written, and
`cd ~/.dotfiles && ./run.sh rebuild` is a single command at a terminal
that already exists. The old note called the daemon "the clean
alternative"; it isn't, once not-needing-a-password is the actual
requirement rather than an obstacle.

**The host comes from `.dotfiles-host`, never from `uname` or the
hostname.** That is the per-clone marker `run.sh` writes and reads to know
which recipe it applies (`run.sh`'s `$MARKER`, line one; line two is its
`nix`/`no-nix` flag, which this job ignores). A missing or unrecognized
value stops the run with a log line naming the file - the timer must not
guess what `run.sh` would refuse to guess, and the failure mode of
guessing is the worst one available: auto-switching a machine nobody
declared. Two consequences worth knowing: a machine that was only ever
bootstrapped with an explicit host argument has no marker (only the
interactive menu writes one), so it needs `./run.sh choose` once before
the timer does anything; and `work` is recognized but refused, because
that host has no Nix switch to schedule. The marker is read with bash's
own `read`, not `sed`/`head`, so the hermetic suite doesn't have to put
another binary on its PATH.

**`sudo -n` is a shim on PATH, not a pre-flight probe.** Probing `sudo -n
true` before the rebuild is what the earlier note rejected, and that
reasoning still holds: a `NOPASSWD` rule scoped to one command makes the
probe fail on a correctly configured machine, so the probe would block the
feature it was meant to protect. Instead, just before the rebuild the
script writes `$state_dir/sudo-guard/sudo` (`exec <real sudo> -n "$@"`)
and prepends that directory to PATH. Any sudo the switch reaches then
*cannot* prompt: a password-needing rule fails in milliseconds with sudo's
own message, a `NOPASSWD` rule works exactly as before, and nothing has to
predict which it will be. The real sudo is resolved *before* the shim goes
on PATH, and a resolution landing inside the shim directory is declined,
so no second call can build a shim that execs itself. Belt and braces
around it: the rebuild's stdin is `/dev/null`, and its output is teed to a
third file the script reads back, so sudo's refusal is explained in the
log (`it failed on a sudo password prompt, which a scheduled run has no
terminal to answer`) instead of being left as a raw line nobody connects
to the timer.

**Why `./run.sh rebuild` now records the commit it applied.** The Mac's
reminder has to stop when the human acts on it, and the only thing that
knows a human acted is the command they ran. So `cmd_rebuild` and
`cmd_bootstrap_nix` end in `record_applied_commit`, writing HEAD to the
same `${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-auto/last-applied`
the job writes after a rebuild of its own. That is also what makes the
announce state honest rather than a nag: the reminder line is logged on
*every* run while the update is outstanding (the log is the record), while
the notification fires once per new upstream commit. Someone who switches
their Mac with a bare `darwin-rebuild` instead of `./run.sh rebuild` keeps
the log line until the next commit lands - a cosmetic cost, paid only in a
file, and the alternative (deriving the applied commit from
`system.configurationRevision`) couples the timer to a flake input and
only works for commits made after it is wired up.

**Dedup state is three one-line files, and losing any of them is
harmless.** `last-applied` (what this machine applied), `last-announced`
(the commit the Mac last notified about) and `last-blocked` (a key naming
the last fetch it couldn't act on: `dirty|ahead|diverged` plus both
commits). `last-blocked` is cleared on every path where nothing is in the
way, so a situation that returns is a new occurrence and notifies again;
without that clear, one weekend of uncommitted edits would silence the
next month of them. Deleting any of the three costs at most one repeated
notification, which is why every write to them is best-effort and none can
fail a run.

**One non-obvious state transition the tests pin down.** On a Mac that has
*only* ever been announced at, `last-applied` is empty - and "no record"
is deliberately read as "this is the first run, record where the machine
stands and switch nothing", so the very next run would have gone quiet
about an update still waiting. `update_due` therefore also fires when
`last-announced` names a commit that `last-applied` doesn't, which is the
only state that distinguishes "never run here" from "announced, not yet
applied".

**Unpushed local commits now notify, once.** The earlier design left
local-ahead deliberately quiet as "an ordinary working state". The new
rule is that no fetch this job couldn't act on is silent: uncommitted
changes, local commits and a real divergence each log their own line and
raise one notification per occurrence on both hosts. The "once per
occurrence" part is what makes that tolerable - an unpushed commit
interrupts you once, not 48 times a day - and `home-linux` still applies a
local commit it finds, so the notification is information, not a refusal.
A dirty checkout with *nothing* to fast-forward to is the one case left
quiet on purpose: the uncommitted work is in nobody's way there.
