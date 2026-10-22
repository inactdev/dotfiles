# Linger is part of the switch, so the Linux timer survives logging out

A systemd *user* timer only runs while that user's systemd instance is up,
and without linger that instance exists only while a session does. So
`modules/linux.nix`'s `dotfiles-auto-apply.timer` stopped firing on a
headless cloud box as soon as the last ssh connection closed - and the
symptom was silence. Enabling linger was the last manual step the
`home-linux` setup carried (`README.md` named the command, which is the
leftover this removes); it is now an activation step in
`modules/linux.nix`, ordered before the step that starts the timer. This
note supersedes the closing paragraph of
`notes/20261021-dotfiles-auto-apply.md` ("The Linux timer needs one thing
home-manager cannot declare").

**An activation step, not `run.sh bootstrap`.** The cheaper-looking place
was `cmd_bootstrap_nix`'s `home-linux` branch. Rejected for two reasons,
and the first is the stronger: the `ci-linux` rehearsal in
`install.container-test.sh` never runs `run.sh` - it does a bare
`home-manager switch` - so a step placed there would have had no
real-execution coverage anywhere, which is precisely the gap
`notes/20261021-activation-step-env-path.md` created that host to close.
Second, a bootstrap-only step never reaches a box that was bootstrapped
before it existed, while an activation step is applied by the next switch,
hand-run or scheduled. Writing logind's state file
(`/var/lib/systemd/linger/<user>`) directly was also considered and
dropped: it is not a documented interface, and logind reads it at startup,
so the user manager would not come up until the next boot.

**The account comes from `config.home.username`, never `$USER`.** That is
the username the host's `flake.nix` output was evaluated with
(`modules/core.nix` sets it), so a switch run through `sudo` still targets
the human account whose timer this is instead of `root`. It also decides
*which* polkit action is in play, which is the whole reason this needs no
privilege: logind authorizes `SetUserLinger` for the calling uid as
`org.freedesktop.login1.set-self-linger`, whose default answer is yes, and
only the same call for *another* account is `set-user-linger`, which needs
admin rights.

**`--no-ask-password`, for the same reason the sudo guard exists.** A
polkit configuration that does require authentication must fail in
milliseconds with loginctl's own message rather than block an activation
that has no terminal to answer at - the rule
`notes/20261022-dotfiles-auto-apply-no-password.md` sets for this feature.
The cost is that a human at a terminal can no longer authenticate the
first enable interactively; the hard-failure message names
`sudo loginctl enable-linger <user>` instead.

**The `Linger` property is read before anything is enabled.** Not for
idempotence of the *effect* - `enable-linger` is already idempotent - but
because the authorization decision is not free: on a box where polkit
would refuse, a step that called it unconditionally would turn every
future switch, including the half-hourly self-apply, into a failure.
Reading `loginctl show-user <user> --property=Linger --value` first means
an already-lingering user is a reported no-op, so the only run that can
fail is one where linger is genuinely missing.

**Exactly one tolerated skip, and it is never silent.** A machine where
logind cannot exist at all - no `loginctl` found, or systemd is not the
init system (`/run/systemd/system`, the check `sd_booted(3)` documents) -
has no systemd user manager for the timer either, so there is nothing for
linger to keep alive; that warns, naming the command it skipped and why,
and the switch carries on. Every other refusal exits 1 and fails the
switch. The reasoning is the same one behind the rehearsal: a timer that
only runs while someone happens to be logged in produces no error
message of its own, ever.

**`loginctl` is resolved from fixed paths as well as `PATH`.**
home-manager's activation `PATH` is its own store packages plus whatever
the caller had (`home.emptyActivationPath` defaults to false), and a
scheduled switch is not guaranteed to carry `/usr/bin`. A `loginctl`
missing for *that* reason must not be read as "this box has no logind",
because that reading is a silent skip on a machine that needed the step -
so the step tries `PATH`, then `/usr/bin`, `/bin` and
`/run/current-system/sw/bin`.

**Ordering: linger first, then the timer start.** Both steps end up after
`writeBoundary`; `startDotfilesAutoApplyTimer` now depends on
`enableLinger` instead, and gets `writeBoundary` transitively. That is the
only ordering that can help - enabling linger makes logind bring the
user's manager up immediately, so on a box that had none the
`systemctl --user start` afterwards gets a chance to work instead of being
deferred to the next login. (It can still fail for want of
`XDG_RUNTIME_DIR` in the activation environment, which is why that step
keeps its own message.)

**What the rehearsal asserts depends on the container, deliberately.**
`install.container-test.sh` branches on the module's own definition of
"logind cannot exist here" so the two cannot disagree: in today's
`ubuntu:24.04` container (PID 1 is `sleep`) it requires the
skipped-and-why warning in the activation log; where logind is present it
requires that `loginctl show-user <user> --property=Linger --value`
answers `yes` afterwards - logind itself, not the log. A zero exit from
the switch proves nothing here, exactly as with the two sync steps next to
it.

**Same shape elsewhere - nothing left to fix, two things to know.**
`modules/mac.nix` schedules the same job with a launchd *user* agent, and
macOS has no linger equivalent; a LaunchAgent is bound to a user session
by design, and that host only announces anyway. The codespace hosts never
compose `modules/linux.nix` (a container is applied once at creation and
thrown away), so they need none of this. The one remaining
"needs something from the machine itself" claim in `README.md` is the
*absence* of one on the Mac - no `/etc/sudoers.d` rule, no root
`launchd.daemons` job - which is a decision, not a leftover.
