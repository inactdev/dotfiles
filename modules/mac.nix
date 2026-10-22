{
  config,
  pkgs,
  lib,
  ...
}:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";

  # The script modules/desktop.nix symlinks into place. Named by its stable
  # ~/.local/bin path, never by a store path: home-manager restarts exactly
  # those launchd agents whose plist text changed, and it does that at the
  # end of the activation this job itself started - so a plist that moved
  # with every generation would `launchctl bootout` the job mid-rebuild.
  # See notes/20261021-dotfiles-auto-apply.md.
  autoApply = "${config.home.homeDirectory}/.local/bin/dotfiles-auto-apply";

  # launchd agents inherit almost nothing, so the job gets an explicit PATH
  # of fixed directories - also generation-independent, for the reason
  # above. What it actually needs on this host is small, because the job
  # here only fetches and announces (see the agent below): git and the rest
  # of the CLI tooling (the per-user profile), and `osascript` for the
  # notification (/usr/bin). The remaining directories are the ordinary
  # system ones plus Homebrew's prefix, kept as a floor so a git (or
  # anything else the script grows) found outside the Nix profile still
  # resolves - not because a switch runs from here any more.
  schedulerPath = lib.concatStringsSep ":" [
    "${config.home.profileDirectory}/bin"
    "/run/current-system/sw/bin"
    "/nix/var/nix/profiles/default/bin"
    "/opt/homebrew/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
  ];
in

# Only ever composed into personal-mac (see flake.nix) - herdr itself is a
# Homebrew cask (configuration.nix, which stays Darwin-only), and launchd is
# a macOS-only home-manager option that doesn't exist in a standalone Linux
# homeConfiguration at all, so neither half of this can be evaluated for
# home-linux or a codespace. home-linux's equivalent of the agent below is
# the systemd user timer in modules/linux.nix.
{
  home.file.".config/herdr".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/herdr";

  # Self-updating dotfiles: fetch ~/.dotfiles every 30 minutes and once at
  # login, and when origin/master has moved ahead of a clean master
  # checkout, fast-forward to it - and then stop, with a notification that
  # an update is ready and the one command to apply it. All of the
  # judgement lives in the script (see its header for every way it declines
  # to act, starting with never touching a dirty checkout); this only
  # supplies the clock and the environment.
  #
  # The script decides that by reading .dotfiles-host, not by being on a
  # Mac, so this agent passes it nothing about the host. Why this host
  # announces instead of applying: `./run.sh rebuild` here ends in `sudo
  # darwin-rebuild switch`, and a launchd *user* agent has no terminal for
  # sudo to prompt at, so a scheduled switch could only ever fail with
  # "sudo: a terminal is required to read the password" and retry every
  # half hour. The two ways to make it switch anyway were both declined: a
  # passwordless sudo rule in /etc/sudoers.d (a privilege widened by hand,
  # outside this repo, to save one command), and a root launchd.daemons job
  # in configuration.nix (a timer switching the whole system as root).
  # home-linux keeps applying by itself, because its switch is a plain
  # user-level home-manager switch with no sudo in it at all.
  #
  # StandardOutPath is Library/Logs and NOT the script's own
  # ~/.local/state/dotfiles-auto/apply.log: the script trims that file by
  # renaming a tail over it, and launchd would go on writing to the
  # unlinked inode for the rest of the session.
  launchd.agents.dotfiles-auto-apply = {
    enable = true;
    config = {
      ProgramArguments = [ autoApply ];
      RunAtLoad = true;
      StartInterval = 1800;
      ProcessType = "Background";
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
        PATH = schedulerPath;
      };
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/dotfiles-auto-apply.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/dotfiles-auto-apply.log";
    };
  };
}
