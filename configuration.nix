{ user, ... }:

{
  # Determinate Nix manages its own daemon; nix-darwin must not fight it.
  nix.enable = false;

  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = "aarch64-darwin"; # x86_64-darwin for Intel

  system.primaryUser = user;
  users.users.${user} = {
    home = "/Users/${user}";
  };
  system.stateVersion = 6;

  system.defaults = {
    NSGlobalDomain = {
      KeyRepeat = 2; # fast key repeat
      InitialKeyRepeat = 15; # short delay before repeat
      _HIHideMenuBar = true; # auto-hide the menu bar
      AppleShowAllExtensions = true;
    };
    dock.autohide = true;
    finder.FXPreferredViewStyle = "Nlsv"; # list view by default
    finder.CreateDesktop = false; # clean desktop
  };

  # Never sleep while on AC power, via pmset's -c (charger) profile only, so
  # battery behaviour stays at macOS' defaults. nix-darwin's own power.sleep.*
  # options are deliberately unused: they drive `systemsetup -setComputerSleep`,
  # which is power-source-agnostic (it would keep the machine awake on battery
  # too) and takes precedence over pmset's per-profile timers. Absolute path
  # because activation runs as root under `env -i` with a minimal PATH; writing
  # the same two values is idempotent, which matters as this runs every rebuild.
  system.activationScripts.postActivation.text = ''
    echo "setting the AC power profile to never sleep..." >&2
    /usr/bin/pmset -c sleep 0 disksleep 0
  '';

  nix-homebrew = {
    enable = true;
    autoMigrate = true;
    inherit user;
  };
  homebrew = {
    enable = true;
    # "zap" = true no-drift: removes any brew/cask/tap not listed here.
    onActivation.cleanup = "zap";
    taps = [
      "my-monkeys/tap"
    ];
    brews = [
      {
        name = "ollama";
        restart_service = "changed";
      }
      "herdr"
      "rbenv"
      # kept for app HTTPS work; may move to per-app provisioning when
      # Inkwell's transport decision lands
      "mkcert"
      # mkcert's Firefox trust-store companion
      "nss"
      # this repo's own test suites lint with it
      "shellcheck"
      # Inkwell project generation
      "xcodegen"
    ];
    casks = [
      "ghostty"
      "wezterm"
      "claude-code"
      "docker-desktop"
      "my-monkeys/tap/opensuperwhisper"
    ];
  };
}
