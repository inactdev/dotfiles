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
      # The codespace container user, read from the environment (see the
      # codespace comment block below). getEnv returns "" both when USER is
      # unset and under pure evaluation, and an empty username would silently
      # activate home-manager against /home/ - so refuse it here rather than
      # failing confusingly downstream.
      codespaceUser =
        let
          envUser = builtins.getEnv "USER";
        in
        if envUser == "" then
          throw "codespace-personal/codespace-work need USER set in the evaluating environment - evaluate or build them with --impure"
        else
          envUser;
      # The container user install.container-test.sh creates for the
      # ci-linux rehearsal below. A hardcoded literal rather than
      # builtins.getEnv "USER" (which the codespace outputs have no choice
      # about) on purpose, for two reasons: this output then evaluates
      # without --impure-only environment reads wherever CI checks it, and
      # the flake and the rehearsal cannot drift apart about which home
      # directory is being activated - home-manager aborts outright when
      # $HOME is not the home.homeDirectory it was evaluated with, so the
      # name here and the `useradd` in install.container-test.sh have to
      # stay the same string.
      ciUser = "ci-activation";
      # The two codespace outputs differ only in the posture string handed
      # to modules/codespace.nix - see the codespace comment block below.
      mkCodespace =
        posture:
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            config.allowUnfree = true;
          };
          extraSpecialArgs = {
            user = codespaceUser;
            inherit posture;
          };
          modules = [
            (homeModules [
              ./modules/core.nix
              ./modules/codespace.nix
            ])
          ];
        };
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
              ./modules/fabrica.nix
              ./modules/inspector.nix
              ./modules/mac.nix
            ];
          }
        ];
      };

      # home-linux: the captain's home Ubuntu 24.04 box, or any cloud Linux
      # box set up as this host. No nix-darwin here - it's a standalone
      # home-manager configuration (not a darwinSystem) composed from the
      # same modules/core.nix + modules/desktop.nix + modules/fabrica.nix +
      # modules/inspector.nix as personal-mac, minus modules/mac.nix
      # (Darwin-only: herdr, and the launchd half of the self-apply job)
      # plus modules/linux.nix (Linux-only: the systemd user timer that is
      # the other half of it).
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
            ./modules/fabrica.nix
            ./modules/inspector.nix
            ./modules/linux.nix
          ])
        ];
      };

      # codespace-personal / codespace-work: GitHub Codespaces containers -
      # applied by install.sh non-interactively (posture picked by its own
      # detect_posture), never through run.sh's menu (see README.md).
      # codespace-work is the exception: install.sh's work branch bypasses
      # Nix entirely for work/codespace-bootstrap.sh, so nothing applies
      # that output anymore - it's kept (and CI-eval-checked) deliberately,
      # see README.md's Codespaces section. Both compose modules/core.nix
      # plus the codespace-only delta in modules/codespace.nix - no
      # modules/desktop.nix (no ghostty, no fonts, no git identity, no
      # local-machine Claude settings), no modules/mac.nix (no herdr) and
      # no modules/linux.nix (no self-apply timer - a container is applied
      # once at creation by install.sh and then thrown away), all
      # structurally absent because mkCodespace's module list never
      # imports those files. `posture` picks the two things
      # modules/codespace.nix still varies by hand (which
      # claude-settings.json, and the `cc` alias) - everything else is
      # identical between the two, including the full modules/core.nix
      # package set. modules/fabrica.nix and modules/inspector.nix are
      # absent the same way, and for a reason of their own - see those
      # files' headers. Work Mac's separate --no-nix path
      # (work/bootstrap.sh) is a different host entirely and untouched by
      # this.
      #
      # `user` is NOT the top-level `inactdev` binding above - a codespace
      # runs as its own container user (typically "codespace", never the
      # captain's own username), read from the environment instead. That
      # makes these the only flake outputs that require --impure to
      # evaluate or build; install.sh always passes that flag for them.
      homeConfigurations."codespace-personal" = mkCodespace "personal";
      homeConfigurations."codespace-work" = mkCodespace "work";

      # ci-linux: not a machine anybody uses - the host
      # install.container-test.sh activates for real, with an actual
      # `home-manager switch`, inside its disposable ubuntu container
      # against a throwaway user's scratch HOME.
      #
      # It exists because eval coverage and hermetic bash tests are not
      # enough for modules/fabrica.nix and modules/inspector.nix. Both of
      # those contribute an activation *step*, and a step's command line is
      # only ever interpreted by a shell at activation time: their steps
      # began with `$DRY_RUN_CMD PATH=...:$PATH bash ...`, which every test
      # in this repo was happy with and which failed on every real switch,
      # because the empty `$DRY_RUN_CMD` left `PATH=...` as the command
      # name. Nothing short of running the activation catches that, so this
      # host is what CI runs it against.
      #
      # modules/core.nix + modules/fabrica.nix + modules/inspector.nix +
      # modules/linux.nix, deliberately: the two modules under test, the
      # one they share their PATH ordering with, and the other Linux-only
      # module a home-linux activation would carry. No modules/desktop.nix
      # and nothing Darwin-only or secret-dependent, so the activation
      # needs no credentials, no fonts, and no git identity. One
      # consequence worth knowing: modules/linux.nix's systemd user unit
      # points at ~/.local/bin/dotfiles-auto-apply, which
      # modules/desktop.nix is what normally symlinks - on this host the
      # unit is written with no such file behind it, which is harmless
      # because the container has no systemd user session to start it with
      # (both that module's own activation step and home-manager's
      # reloadSystemd check for one and skip).
      #
      # NOT the "personal-mac minus Homebrew" CI host the note below still
      # describes, and not a substitute for it: this one is scoped to
      # proving the activation steps run.
      homeConfigurations."ci-linux" = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          system = "x86_64-linux";
          config.allowUnfree = true;
        };
        extraSpecialArgs = { user = ciUser; };
        modules = [
          (homeModules [
            ./modules/core.nix
            ./modules/fabrica.nix
            ./modules/inspector.nix
            ./modules/linux.nix
          ])
        ];
      };

      # The "work" host is NOT a Nix host - it's the brew-only --no-nix path
      # under work/ (see README.md), so it never appears here. There is no
      # work-linux host either: GitHub Codespaces (see install.sh) covers
      # work-on-Linux instead.
      # Later: a full "ci" host goes here (personal-mac minus Homebrew) for
      # GitHub Actions - distinct from ci-linux above, which is scoped to
      # activating the Fabrica/Inspector steps for real.
    };
}
