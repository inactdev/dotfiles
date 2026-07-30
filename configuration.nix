{ user, ... }:

{
  # Determinate Nix manages its own daemon; nix-darwin must not fight it.
  nix.enable = false;

  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = "aarch64-darwin";  # x86_64-darwin for Intel

  system.primaryUser = user;
  users.users.${user} = {
    home = "/Users/${user}";
  };
  system.stateVersion = 6;

  system.defaults = {
    NSGlobalDomain = {
      KeyRepeat = 2;          # fast key repeat
      InitialKeyRepeat = 15;  # short delay before repeat
      _HIHideMenuBar = true;  # auto-hide the menu bar
      AppleShowAllExtensions = true;
    };
    dock.autohide = true;
    finder.FXPreferredViewStyle = "Nlsv";  # list view by default
    finder.CreateDesktop = false;          # clean desktop
  };

  nix-homebrew = {
    enable = true;
    inherit user;
  };
  homebrew = {
    enable = true;
    # "none" = adoption mode: never uninstall things not listed here.
    # Once your list is complete, flip to "zap" for true no-drift.
    onActivation.cleanup = "none";
    brews = [
      { name = "ollama"; restart_service = "changed"; }
      "herdr"
      "rbenv"
    ];
    casks = [
      "ghostty"
      "wezterm"
      "claude-code"
      "docker-desktop"
      # add more GUI apps from your Brewfile triage here
    ];
  };
}
