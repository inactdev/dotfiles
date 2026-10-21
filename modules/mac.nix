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
  # above. It needs: git and the rest of the CLI tooling (the per-user
  # profile), `nix` itself (the daemon profile), `darwin-rebuild` and
  # `sudo` (/run/current-system/sw/bin and /usr/bin), and Homebrew's prefix
  # because `./run.sh rebuild` ends in a darwin-rebuild that drives
  # `brew bundle`.
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

  # Self-applying dotfiles: fetch ~/.dotfiles every 30 minutes and once at
  # login, and when origin/master has moved ahead of a clean master
  # checkout, fast-forward and `./run.sh rebuild`. All of the judgement
  # lives in the script (see its header for every way it declines to act,
  # starting with never touching a dirty checkout); this only supplies the
  # clock and the environment.
  #
  # One thing to know before expecting this to work on this host:
  # `./run.sh rebuild` here ends in `sudo darwin-rebuild switch`, and a
  # launchd *user* agent has no terminal for sudo to prompt at. Until this
  # Mac has a passwordless sudo rule for darwin-rebuild, every run that
  # finds new commits will fast-forward, fail the rebuild, notify, and
  # retry on the next tick - loudly, by design, rather than silently
  # pretending to have applied anything. README.md says what to add; a root
  # launchd.daemons job in configuration.nix is the other way out, and is
  # deliberately not what this is.
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
