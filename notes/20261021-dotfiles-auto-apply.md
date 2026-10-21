# Self-applying dotfiles: the scheduler is the hard part, not the git

`home/.local/bin/dotfiles-auto-apply` fetches `~/.dotfiles`, fast-forwards
a clean `master` to `origin/master` when it has moved, and applies the
result with `./run.sh rebuild`. The OS schedules it: a launchd user agent
on `personal-mac` (`modules/mac.nix`) and a systemd user timer on
`home-linux` (`modules/linux.nix`), both every 30 minutes and once at
login. The git half is four commands. Everything below is what made the
rest of it non-obvious.

**The chosen shape, and the alternative that looks simpler.** The obvious
cheaper option was a `home.activation` step, exactly like
`modules/fabrica-sync.sh` and `modules/inspector-sync.sh` next to it.
Rejected: activation only runs when somebody already ran
`./run.sh rebuild`, which is the manual step this is supposed to delete.
Keeping Fabrica current is a floor under a command you were going to run
anyway; applying the dotfiles *is* that command, so it needs a clock,
which only the OS has.

**Why both unit files point at stable paths, never at the store.** The
launchd plist and the systemd unit exec
`~/.local/bin/dotfiles-auto-apply` (a `mkOutOfStoreSymlink` into this
repo, declared in `modules/desktop.nix`) and set a PATH built only from
the profile directory and fixed system directories - no
`lib.makeBinPath` over `pkgs.git`/`pkgs.coreutils`, which is how the two
activation scripts do it. That is deliberate and load-bearing:
home-manager restarts exactly those units whose text changed, and it does
so at the end of the activation that *this script just started*. With
store paths in the unit, every nixpkgs bump or script edit rewrites the
unit text, so the job would `launchctl bootout` / `systemctl restart`
itself in the middle of its own `./run.sh rebuild`. Stable paths keep
both unit files byte-identical across generations, so the only way to
restart the job is to deliberately edit its Nix.

**Concurrency comes free from the schedulers.** Neither launchd nor
systemd will start a second copy of a job that is still running (one
instance per launchd label; a `Type=oneshot` service that is still
active just absorbs the timer trigger), which matters when a 30-minute
interval meets a rebuild that can take longer than that on a cold
closure. So the script needs no lock file. A hand-run
`./run.sh rebuild` racing a scheduled one is still possible and is left
to the human - Nix, not this script, is what would arbitrate it.

**`git fetch origin master` really does move the tracking ref.** The
comparison reads `refs/remotes/origin/master` rather than `FETCH_HEAD`,
which is only correct because a `<remote> <branch>` fetch with no
destination in the refspec updates the remote-tracking branch too.
Verified against git 2.54 in a throwaway repository rather than taken on
trust: before the fetch `refs/remotes/origin/master` was the old commit,
after it the new one, and `FETCH_HEAD` agreed. A transport failure exits
128, which is why the fetch is checked rather than assumed.

**Four states, not two, which is why it is not `git pull --ff-only`.**
`pull` collapses "already current", "fast-forwardable", "local is ahead"
and "genuinely diverged" into one exit status, and would start merging
before anything has looked at whether the tree is clean. The script
classifies with `merge-base --is-ancestor` in both directions and treats
each case differently: current and local-ahead are quiet no-ops,
fast-forwardable is the working path, and only a true divergence (neither
commit is an ancestor of the other) notifies. Local-ahead deliberately
does *not* notify - an unpushed commit in the dotfiles repo is a normal
working state, not a thing to be woken up about.

**The recorded commit is what keeps a failed rebuild from being
forgotten.** Without it the sequence "fast-forward succeeds, rebuild
fails" leaves the checkout level with `origin/master` and the machine
un-applied, and the next run sees nothing to do - forever. So the commit
of the last *successful* rebuild is written to
`~/.local/state/dotfiles-auto/last-applied`, and a run whose HEAD differs
from that record rebuilds even when the fetch brought nothing new. The
one wrinkle: on a machine that has never run this, there is no record,
and treating "no record" as "rebuild now" would make installing the timer
trigger an unasked-for switch. So the first run records HEAD and applies
nothing.

**`./run.sh rebuild` needs root on the Mac, and a launchd user agent has
no terminal.** `cmd_rebuild` ends in `sudo darwin-rebuild switch` on
`personal-mac`; under launchd there is no tty, so unless sudo needs no
password for it, the rebuild fails with sudo's own message, the script
notifies, and - because the record was not updated - it retries every 30
minutes. That is the designed failure mode, not a surprise, but the Mac
half of this feature does nothing useful until a passwordless sudo rule
for `darwin-rebuild` exists on that machine. The script deliberately does
*not* pre-flight `sudo -n true`: a NOPASSWD rule scoped to
`darwin-rebuild` alone makes that probe fail on a machine that is
configured correctly, so the probe would block the feature it was meant
to protect. `home-linux` has no such problem - `cmd_rebuild` there is a
plain user-level `home-manager switch`. The clean alternative on the Mac
is a root `launchd.daemons` job in `configuration.nix` instead of a user
agent, which needs no sudoers edit at all; it was not taken because the
brief placed the agent in `modules/mac.nix`, and a root daemon switching
the whole system on a timer is a bigger decision than it looks.

**PATH is not enough to make `nix` work from a scheduled job.** On a
multi-user (Determinate) install, a non-root client that does not know to
talk to the daemon tries to use the store directly and fails on
permissions, and a launchd agent or systemd user service inherits none of
what a login shell gets. So before the rebuild the script sources
`/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh` - the same
path `run.sh`'s own bootstrap sources right after installing Nix - unless
`NIX_REMOTE` is already set or the file is not there. It is sourced with
`set +u` around it, because that file is generated and makes no promise
about being readable under `set -u`. The suite pre-sets `NIX_REMOTE`,
which is both what the real hosts run with and what keeps the tests from
reading that file on a machine that has Nix.

**Notification is a runtime lookup, not a per-host Nix conditional.**
`command -v osascript`, then `command -v notify-send`, then nothing - so
one script is correct on the captain's Mac, on a Linux box with a desktop
session, and on a headless cloud box where no notification can be
delivered at all and the log plus journald are the whole record. Message
text is stripped of `"` and `\` before it reaches `osascript -e`, because
that argument is AppleScript source, not an argv slot.

**The log is written by the script and captured by the scheduler, into
two different files on purpose.** Every line goes to
`~/.local/state/dotfiles-auto/apply.log` via `>>` and to stdout, which
launchd writes to `~/Library/Logs/dotfiles-auto-apply.log` and journald
keeps on `home-linux`. The launchd path is deliberately *not* the state
log: the script trims its own log by writing a tail to a temp file and
renaming it, and a `StandardOutPath` pointed at the same path would leave
launchd holding a file descriptor on the unlinked inode, silently losing
every later line.

**`home/.local/bin/*` is back in both shellcheck lists.** It was dropped
when the firstmate handoff watcher left that directory empty (git tracks
no empty directory, so the glob reached shellcheck as a literal path and
failed the job - see
`notes/2026-10-17-remove-firstmate-handoff-watcher.md`, which asked for it
to be re-added only alongside a script). This is that script, so
`.github/workflows/ci-floor.yml` and `check.sh` both list the glob again.
It stays a glob rather than two explicit names for a reason that will
outlive this change: the script itself carries no `.sh` extension, so
every narrower pattern this repo uses elsewhere would skip it silently.

**The Linux timer needs one thing home-manager cannot declare.** A
systemd *user* timer only runs while that user's systemd instance is up,
which on a headless box means `loginctl enable-linger <user>` (root, once
per machine). Without it the timer runs only while someone is logged in.
`modules/linux.nix` also starts the timer from an activation step guarded
by `command -v systemctl`, because home-manager's own
`systemd.user.startServices` default has changed across releases and
"the timer begins on the next login" is not what "no extra steps" means.
