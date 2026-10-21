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
# This is also what makes a fresh cloud Linux box self-maintaining with no
# extra steps beyond `./run.sh bootstrap home-linux`. The one thing
# home-manager cannot declare for it: a *user* timer only runs while that
# user's systemd instance is up, so a headless box needs
# `loginctl enable-linger <user>` once, as root, or the timer only runs
# while someone is logged in. README.md says so too.
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

  # home-manager links the timer into timers.target.wants, but whether it
  # also *starts* it during activation depends on
  # systemd.user.startServices, whose default has changed across
  # home-manager releases. "it begins on your next login" is not what "no
  # extra steps" means on a box that was just bootstrapped over ssh, so the
  # timer is started here explicitly. Idempotent (starting a running timer
  # is a no-op), guarded on there being a systemd user session at all so it
  # cannot fail an activation, and OnStartupSec being long past by then
  # means the first run happens right away.
  home.activation.startDotfilesAutoApplyTimer = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
      $DRY_RUN_CMD systemctl --user daemon-reload || true
      $DRY_RUN_CMD systemctl --user start dotfiles-auto-apply.timer \
        || echo "could not start dotfiles-auto-apply.timer; it starts on the next login." >&2
    else
      echo "no systemd user session here, so dotfiles-auto-apply.timer was not started;" >&2
      echo "it starts on the next login (or at boot, once this user has linger enabled)." >&2
    fi
  '';
}
