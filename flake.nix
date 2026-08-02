{
  description = "Ari's dotfiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
  };

  outputs =
    inputs@{
      self,
      nix-darwin,
      nix-homebrew,
      home-manager,
      nixpkgs,
    }:
    let
      user = "inactdev"; # <-- output of `whoami`, nothing else
      inherit (nixpkgs) lib;
      # Composes module files into the single function-module home-manager
      # expects (for `home-manager.users.<user>` directly, or wrapped in a
      # one-element `modules` list) - mirroring how the old single home.nix
      # used lib.mkMerge internally instead of `imports`. `imports` would put
      # each file at its own position in the overall module tree, which
      # changes the *order* nixpkgs' module system concatenates any
      # list-typed option (home.packages, chiefly) even when every file's
      # own contribution is unchanged - see the refactor-safety drvPath
      # comparison in the PR description for how this was found.
      homeModules =
        files:
        {
          config,
          pkgs,
          lib,
          ...
        }@args:
        lib.mkMerge (map (f: import f args) files);
    in
    {
      # Nix HOSTS live here. Each entry below is one named machine recipe.
      # A machine applies exactly one of them: ./run.sh rebuild <host-name>
      darwinConfigurations."personal-mac" = nix-darwin.lib.darwinSystem {
        specialArgs = { inherit user; };
        modules = [
          ./configuration.nix
          nix-homebrew.darwinModules.nix-homebrew
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-backup";
            home-manager.extraSpecialArgs = { inherit user; };
            home-manager.users.${user} = homeModules [
              ./modules/core.nix
              ./modules/desktop.nix
              ./modules/mac.nix
            ];
          }
        ];
      };

      # home-linux: the captain's home Ubuntu 24.04 box. No nix-darwin here -
      # it's a standalone home-manager configuration (not a darwinSystem)
      # composed from the same modules/core.nix + modules/desktop.nix as
      # personal-mac, minus modules/mac.nix (Darwin-only: herdr, launchd).
      # Apply with: nix run github:nix-community/home-manager/release-26.05#home-manager -- switch --flake .#home-linux
      homeConfigurations."home-linux" = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          system = "x86_64-linux";
          config.allowUnfree = true;
        };
        extraSpecialArgs = { inherit user; };
        modules = [
          (homeModules [
            ./modules/core.nix
            ./modules/desktop.nix
          ])
        ];
      };

      # codespace-personal / codespace-work: GitHub Codespaces containers -
      # applied by install.sh non-interactively (posture picked by its own
      # detect_posture), never through run.sh's menu (see README.md). Both
      # compose modules/core.nix plus the codespace-only delta in
      # modules/codespace.nix - no modules/desktop.nix (no ghostty, no
      # fonts, no git identity, no local-machine Claude settings) and no
      # modules/mac.nix (no herdr, no launchd), all structurally absent
      # because this list never imports those files. `posture` picks the
      # two things modules/codespace.nix still varies by hand (which
      # claude-settings.json, and the `cc` alias) - everything else is
      # identical between the two, including the full modules/core.nix
      # package set. Work Mac's separate --no-nix path (work/bootstrap.sh)
      # is a different host entirely and untouched by this.
      #
      # `user` is NOT the top-level `inactdev` binding above - a codespace
      # runs as its own container user (typically "codespace", never the
      # captain's own username), read from the environment instead. That
      # makes these the only flake outputs that require --impure to
      # evaluate or build; install.sh always passes that flag for them.
      homeConfigurations."codespace-personal" = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          system = "x86_64-linux";
          config.allowUnfree = true;
        };
        extraSpecialArgs = {
          user = builtins.getEnv "USER";
          posture = "personal";
        };
        modules = [
          (homeModules [
            ./modules/core.nix
            ./modules/codespace.nix
          ])
        ];
      };

      homeConfigurations."codespace-work" = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          system = "x86_64-linux";
          config.allowUnfree = true;
        };
        extraSpecialArgs = {
          user = builtins.getEnv "USER";
          posture = "work";
        };
        modules = [
          (homeModules [
            ./modules/core.nix
            ./modules/codespace.nix
          ])
        ];
      };

      # The "work" host is NOT a Nix host - it's the brew-only --no-nix path
      # under work/ (see README.md), so it never appears here. There is no
      # work-linux host either: GitHub Codespaces (see install.sh) covers
      # work-on-Linux instead.
      # Later: "ci" host goes here (personal-mac minus Homebrew) for GitHub Actions.
    };
}
