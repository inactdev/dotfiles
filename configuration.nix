{
  user,
  pkgs,
  lib,
  ...
}:

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

  # Two steps that both have to run after nix-darwin's own defaults step
  # above. postActivation is its only supported extension point and runs
  # there (see notes/2026-10-17-personal-mac-ac-no-sleep.md); `lib.mkAfter`
  # additionally puts this fragment behind every ordinary definition of the
  # same option - home-manager's darwin module contributes one too - so the
  # Dock warning below lands as near the end of a rebuild's output as a
  # declarative step can, rather than buried in the middle of it.
  #
  # Never sleep while on AC power, via pmset's -c (charger) profile only, so
  # battery behaviour stays at macOS' defaults. nix-darwin's own power.sleep.*
  # options are deliberately unused: they drive `systemsetup -setComputerSleep`,
  # which is power-source-agnostic (it would keep the machine awake on battery
  # too) and takes precedence over pmset's per-profile timers. Absolute path
  # because activation runs as root under `env -i` with a minimal PATH; writing
  # the same two values is idempotent, which matters as this runs every rebuild.
  #
  # Then: leave the machine with a running Dock. Applying the defaults above
  # restarts the Dock, and on this macOS the restart can be the end of it -
  # the agent exits cleanly, launchd leaves the service inactive, and there
  # is no Dock and no Spaces swiping until the next login. The guard checks
  # before it acts, never bounces a live Dock, and never fails the switch;
  # all of that judgement lives in the script, which has its own test suite
  # (modules/dock-agent-guard.sh, notes/20261101-dock-agent-guard.md).
  # coreutils from the store for its `id` and `sleep`, because the activate
  # script's own PATH is minimal, with `env` between the interpreter and the
  # assignment rather than a bare leading PATH=..., which would be parsed as
  # a command name (notes/20261021-activation-step-env-path.md). The primary
  # user is passed by name because this runs as root and the Dock lives in
  # that user's GUI domain, not root's.
  system.activationScripts.postActivation.text = lib.mkAfter ''
    echo "setting the AC power profile to never sleep..." >&2
    /usr/bin/pmset -c sleep 0 disksleep 0

    ${pkgs.coreutils}/bin/env PATH="${pkgs.coreutils}/bin:$PATH" \
      ${pkgs.bash}/bin/bash ${./modules/dock-agent-guard.sh} ${lib.escapeShellArg user}
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
      # the GUI app; the like-named homebrew-core "tailscale" formula is the
      # CLI/daemon and declares conflicts_with cask: "tailscale-app"
      "tailscale-app"
      "my-monkeys/tap/opensuperwhisper"
    ];
  };
}
