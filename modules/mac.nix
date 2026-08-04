{
  config,
  pkgs,
  lib,
  ...
}:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
in

# Only ever composed into personal-mac (see flake.nix) - herdr itself is a
# Homebrew cask (configuration.nix, which stays Darwin-only) and launchd is
# a macOS-only home-manager option that doesn't exist in a standalone Linux
# homeConfiguration at all, so none of this can be evaluated for
# home-linux or codespace.
{
  home.file.".config/herdr".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/herdr";
  home.file.".local/bin/herdr-agent-handoff-marker".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.local/bin/herdr-agent-handoff-marker";

  # Herdr shows "working" the same way for an agent actively thinking and one
  # that has handed off to a background shell (see the fm_handed_off_shell_running
  # override in home/.config/herdr/agent-detection/claude.toml). This polls
  # `herdr agent explain` on a short interval and prefixes a crewmate task tab's
  # label with an hourglass while that specific rule matches, clearing it once
  # the agent resumes - see home/.local/bin/herdr-agent-handoff-marker for the
  # logic (including why only crewmate tabs are ever marked) and why this is a
  # poller rather than a herdr plugin.
  # --all opts into the whole-workspace sweep deliberately: the script
  # refuses to run with no scope at all, so this is the one place that is
  # meant to touch every agent tab. Manual runs and tests should always use
  # --only <tab-id> (and/or --dry-run) against a throwaway tab instead.
  launchd.agents.herdr-agent-handoff-marker = {
    enable = true;
    config = {
      ProgramArguments = [
        "${config.home.homeDirectory}/.local/bin/herdr-agent-handoff-marker"
        "--all"
      ];
      RunAtLoad = true;
      StartInterval = 5;
      ProcessType = "Background";
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
        PATH = "${config.home.profileDirectory}/bin:/opt/homebrew/bin:/usr/bin:/bin";
      };
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/herdr-agent-handoff-marker.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/herdr-agent-handoff-marker.log";
    };
  };
}
