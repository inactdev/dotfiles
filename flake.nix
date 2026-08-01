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
            home-manager.users.${user} = import ./home.nix;
          }
        ];
      };

      # home-linux: the captain's home Ubuntu 24.04 box. No nix-darwin here -
      # it's a standalone home-manager configuration (not a darwinSystem)
      # sharing home.nix with personal-mac; home.nix conditionalizes the
      # Darwin-only pieces (launchd, herdr) on pkgs.stdenv.isDarwin.
      # Apply with: nix run github:nix-community/home-manager/release-26.05#home-manager -- switch --flake .#home-linux
      homeConfigurations."home-linux" = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          system = "x86_64-linux";
          config.allowUnfree = true;
        };
        extraSpecialArgs = { inherit user; };
        modules = [ ./home.nix ];
      };

      # The "work" host is NOT a Nix host - it's the brew-only --no-nix path
      # under work/ (see README.md), so it never appears here. There is no
      # work-linux host either: GitHub Codespaces (see install.sh) covers
      # work-on-Linux instead.
      # Later: "ci" host goes here (personal-mac minus Homebrew) for GitHub Actions.
    };
}
