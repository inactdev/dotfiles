{
  config,
  pkgs,
  lib,
  user,
  ...
}:

let
  isDarwin = pkgs.stdenv.isDarwin;
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
in

lib.mkMerge [
  {
    home.username = user;
    home.homeDirectory = if isDarwin then "/Users/${user}" else "/home/${user}";
    home.stateVersion = "24.11";

    home.packages =
      with pkgs;
      [
        # editors & terminal
        neovim
        tmux
        starship
        # search / files
        ripgrep
        fd
        fzf
        jq
        # dev toolchain
        nodejs
        go
        cmake
        gnumake # nix's name for make
        python3 # instead of python@3.14 — pinned via flake.lock like everything else
        tree-sitter # covers both tree-sitter and tree-sitter-cli
        watchman
        # utilities
        imagemagick
        graphviz
        cloudflared
        arp-scan

        # formatters
        stylua
        prettierd
        ruff
        nixfmt
      ]
      # ghostty is a Homebrew cask on Darwin (configuration.nix); nixpkgs
      # ships a Linux build directly, so there's no cask equivalent to lean on.
      ++ lib.optionals (!isDarwin) [ ghostty ];

    home.sessionVariables.EDITOR = "nvim";

    programs.git = {
      enable = true;
      settings = {
        user = {
          name = "inactdev";
          email = "aris.a.perez@gmail.com";
        };
        push.autoSetupRemote = true;
        core.editor = "nvim";
      };
    };

    programs.gh = {
      enable = true;
      gitCredentialHelper.enable = true;
    };

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    programs.starship.enable = true;

    programs.zsh = {
      enable = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      shellAliases = {
        bx = "bundle exec";
        vim = "nvim";
        tww = "tmux new -s work-windows";
        tdd = "tmux new -s daemons";
        cssh = "infocmp -x xterm-ghostty | ssh gh codespace ssh tic -x -h";
        cc = "claude --dangerously-skip-permissions";
      };
      # Guarded rather than split per-platform: rbenv/brew are only ever
      # present on Darwin (installed via configuration.nix's homebrew
      # module), so this one shared block just no-ops cleanly on Linux.
      initContent = ''
        if [ -x /opt/homebrew/bin/brew ]; then
          eval "$(/opt/homebrew/bin/brew shellenv)"
        fi

        export PATH="$HOME/.local/bin:$PATH"

        if command -v rbenv >/dev/null 2>&1; then
          eval "$(rbenv init - zsh)"
        fi

        [ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
      '';
    };

    # Edit-in-place symlinks: the real files stay in this repo.
    # Editing ~/.config/nvim IS editing the repo. Commit to port changes.
    home.file.".config/nvim".source =
      config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/nvim";
    home.file.".tmux.conf".source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.tmux.conf";
    home.file.".config/starship.toml".source =
      config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/starship.toml";
    home.file.".config/ghostty".source =
      config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/ghostty";
    home.file.".config/wezterm".source =
      config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/wezterm";
    home.file."AGENTS.md".source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
    # Makes it so that claude and all other LLMs behave the same
    home.file.".claude/CLAUDE.md".source =
      config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
    home.file.".claude/settings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.claude/settings.json";
  }

  # Darwin-only: herdr itself is a Homebrew cask (configuration.nix, which
  # stays Darwin-only), and launchd is a macOS-only home-manager option
  # that doesn't exist in a standalone Linux homeConfiguration at all, so
  # this whole block must be kept out of the merged config on Linux, not
  # just left with no effect.
  (lib.mkIf isDarwin {
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
  })

  # Linux-only: the Nerd Font has no Homebrew-cask equivalent to fall back
  # on here, so it's installed explicitly rather than via home-manager's
  # fonts.fontconfig alone - landed in ~/.local/share/fonts (not the Mac
  # ~/Library/Fonts path, which doesn't exist on Linux) with an explicit
  # fc-cache refresh so terminals see it without a re-login.
  (lib.mkIf (!isDarwin) {
    fonts.fontconfig.enable = true;

    home.activation.installNerdFont = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p "$HOME/.local/share/fonts"
      $DRY_RUN_CMD find "$HOME/.local/share/fonts" -maxdepth 1 \
        -xtype l -lname '/nix/store/*' -delete
      $DRY_RUN_CMD find "${pkgs.nerd-fonts.inconsolata}" -name '*.ttf' \
        -exec ln -sf {} "$HOME/.local/share/fonts/" \;
      $DRY_RUN_CMD ${pkgs.fontconfig}/bin/fc-cache -f "$HOME/.local/share/fonts"
    '';
  })
]
