{
  config,
  pkgs,
  lib,
  ...
}:

let
  # The script modules/desktop.nix symlinks into place, named by its stable
  # ~/.local/bin path rather than by a store path - home-manager restarts
  # exactly those units whose text changed, at the end of the very
  # activation this job starts, so a unit that moved with every generation
  # would `systemctl restart` the job mid-rebuild. See
  # notes/20261021-dotfiles-auto-apply.md.
  autoApply = "${config.home.homeDirectory}/.local/bin/dotfiles-auto-apply";

  # A systemd user service inherits a minimal environment, so the job gets
  # an explicit PATH - fixed directories only, for the reason above. It
  # needs git and the rest of the CLI tooling (the per-user profile) and
  # `nix` itself (the daemon profile), which is what `./run.sh rebuild`
  # runs home-manager with on this host; no sudo is involved here, unlike
  # on personal-mac.
  schedulerPath = lib.concatStringsSep ":" [
    "${config.home.profileDirectory}/bin"
    "/nix/var/nix/profiles/default/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
  ];

  # The account whose user timer this is: the username home-manager was
  # configured with (modules/core.nix sets it from the host's `user`),
  # never $USER or `id -un`. A switch run through sudo reads root there,
  # and root's systemd instance is not the one that applies these
  # dotfiles.
  lingerUser = config.home.username;
in

# Only ever composed into home-linux (see flake.nix): this is the Linux
# counterpart to the launchd agent in modules/mac.nix, and systemd.user is
# a Linux-only home-manager option. A codespace deliberately doesn't get it
# either - a container is applied once at creation by install.sh and then
# thrown away, so there is nothing for a half-hourly self-apply to do.
#
# Self-applying dotfiles: fetch ~/.dotfiles every 30 minutes and once at
# login, and when origin/master has moved ahead of a clean master checkout,
# fast-forward and `./run.sh rebuild` (a plain user-level home-manager
# switch on this host). All of the judgement lives in the script - see its
# header for every way it declines to act, starting with never touching a
# dirty checkout; this file only supplies the clock and the environment.
#
# This is the host that still applies by itself, and the script decides
# that by reading .dotfiles-host rather than by being on Linux - so this
# unit passes it nothing about the host either. The switch here needs no
# sudo, which is the whole reason: personal-mac's needs root, has no
# terminal to type a password at, and therefore only announces (see
# modules/mac.nix).
#
# This is also what makes a fresh cloud Linux box self-maintaining with no
# extra steps beyond `./run.sh bootstrap home-linux` - including the one
# thing home-manager has no option for, which the activation step below
# does instead of asking a human to remember it: a systemd *user* timer
# only runs while that user's systemd instance is up, so a headless box
# needs linger enabled for that user or the timer only fires while
# somebody is logged in.
{
  systemd.user.services.dotfiles-auto-apply = {
    Unit.Description = "Apply ~/.dotfiles when origin/master has moved";
    Service = {
      Type = "oneshot";
      ExecStart = autoApply;
      Environment = [ "PATH=${schedulerPath}" ];
    };
  };

  systemd.user.timers.dotfiles-auto-apply = {
    Unit.Description = "Apply ~/.dotfiles every 30 minutes and at login";
    Timer = {
      # Monotonic rather than OnCalendar on purpose: OnStartupSec is
      # measured from the user manager starting, which is login (or boot,
      # with linger) - so "at login and every 30 minutes after" is the two
      # settings below and needs no wall-clock schedule, and no two
      # machines end up fetching in lockstep on the half hour.
      OnStartupSec = "1min";
      OnUnitActiveSec = "30min";
      AccuracySec = "1min";
      Unit = "dotfiles-auto-apply.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Linger: what makes the timer above survive logging out. Without it the
  # user's systemd instance exists only while a session does, so on a
  # headless cloud box the self-apply would stop the moment the last ssh
  # connection closed - and the symptom is silence, not an error. Enabling
  # it was the last manual step this host's setup carried; it is part of
  # the switch now, and install.container-test.sh's ci-linux rehearsal runs
  # this step for real.
  #
  # Three things it deliberately does not do:
  #
  #   - It never needs root or a password. logind authorizes
  #     SetUserLinger for the *calling* uid as
  #     org.freedesktop.login1.set-self-linger, whose default polkit
  #     answer is yes, so a user's own switch may do this; the same call
  #     for another account is set-user-linger, which needs admin rights.
  #     That is also why the username is passed explicitly rather than
  #     left implicit - a switch run through sudo must still target the
  #     human account, not root. `--no-ask-password` keeps the promise in
  #     notes/20261022-dotfiles-auto-apply-no-password.md: a machine whose
  #     polkit configuration would demand a password fails in
  #     milliseconds with loginctl's own message instead of blocking an
  #     activation that has no terminal to answer at.
  #   - It never re-asks once linger is on. The Linger property is read
  #     first, and a user that already has it is a reported no-op - so the
  #     half-hourly self-apply does not hang an authorization decision off
  #     every single run.
  #   - It never fails quietly. The only tolerated skip is a machine where
  #     logind cannot exist at all (no loginctl anywhere, or systemd is
  #     not the init system - the /run/systemd/system check sd_booted(3)
  #     documents), which has no user manager for the timer either; that
  #     warns, naming the command it skipped and why. Every other
  #     refusal fails the switch, because a timer that only runs while
  #     someone is logged in is precisely the state nobody notices.
  home.activation.enableLinger = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    linger_user="${lingerUser}"
    loginctl=""
    # Resolved against fixed locations as well as PATH: home-manager's
    # activation PATH is its own store packages plus whatever the caller
    # had, and a scheduled switch is not guaranteed to carry /usr/bin - a
    # loginctl missing for that reason must not be read as "this machine
    # has no logind".
    for candidate in loginctl /usr/bin/loginctl /bin/loginctl /run/current-system/sw/bin/loginctl; do
      if resolved="$(command -v "$candidate" 2>/dev/null)"; then
        loginctl="$resolved"
        break
      fi
    done

    if [ -z "$loginctl" ] || [ ! -d /run/systemd/system ]; then
      echo "dotfiles-auto-apply: skipped 'loginctl enable-linger $linger_user' -" >&2
      echo "  this machine has no systemd-logind (no loginctl found, or systemd" >&2
      echo "  is not the init system), so it cannot run a systemd user manager" >&2
      echo "  for dotfiles-auto-apply.timer in the first place and there is" >&2
      echo "  nothing for linger to keep alive." >&2
    elif [ "$("$loginctl" show-user "$linger_user" --property=Linger --value 2>/dev/null)" = "yes" ]; then
      echo "dotfiles-auto-apply: linger already enabled for $linger_user."
    elif run "$loginctl" --no-ask-password enable-linger "$linger_user"; then
      echo "dotfiles-auto-apply: enabled linger for $linger_user - its systemd"
      echo "  user manager now starts at boot, so the timer keeps firing with"
      echo "  nobody logged in."
    else
      echo "dotfiles-auto-apply: could not enable linger for $linger_user, so" >&2
      echo "  dotfiles-auto-apply.timer would stop as soon as nobody is logged" >&2
      echo "  in - loginctl's own reason is above. Enable it once, as root," >&2
      echo "  then re-run the switch:" >&2
      echo "    sudo loginctl enable-linger $linger_user" >&2
      exit 1
    fi
  '';

  # home-manager links the timer into timers.target.wants, but whether it
  # also *starts* it during activation depends on
  # systemd.user.startServices, whose default has changed across
  # home-manager releases. "it begins on your next login" is not what "no
  # extra steps" means on a box that was just bootstrapped over ssh, so the
  # timer is started here explicitly. Idempotent (starting a running timer
  # is a no-op), guarded on there being a systemd user session at all so it
  # cannot fail an activation, and OnStartupSec being long past by then
  # means the first run happens right away.
  #
  # Ordered after the linger step rather than after writeBoundary (which it
  # still follows, transitively, through that step) because that is the
  # only ordering that can help: enabling linger makes logind bring this
  # user's manager up right away, so on a box that had none the start below
  # gets a chance to work instead of being deferred to the next login.
  home.activation.startDotfilesAutoApplyTimer = lib.hm.dag.entryAfter [ "enableLinger" ] ''
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
      $DRY_RUN_CMD systemctl --user daemon-reload || true
      $DRY_RUN_CMD systemctl --user start dotfiles-auto-apply.timer \
        || echo "could not start dotfiles-auto-apply.timer; it starts on the next login." >&2
    else
      echo "no systemd user session here, so dotfiles-auto-apply.timer was not started;" >&2
      echo "it starts at the next login - or at boot, on a machine with logind, where" >&2
      echo "the step above has just enabled linger for this user." >&2
    fi
  '';
}
