{
  config,
  pkgs,
  user,
  ...
}:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
in

{
  home.username = user;
  home.homeDirectory = "/Users/${user}";
  home.stateVersion = "24.11";

  home.packages = with pkgs; [
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
  ];

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
    initContent = ''
      eval "$(/opt/homebrew/bin/brew shellenv)"

      export PATH="$HOME/.local/bin:$PATH"

      eval "$(rbenv init - zsh)"

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
  home.file.".config/herdr".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/herdr";
  home.file.".config/wezterm".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/wezterm";
  home.file."AGENTS.md".source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  # Makes it so that claude and all other LLMs behave the same
  home.file.".claude/CLAUDE.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  home.file.".claude/settings.json".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.claude/settings.json";
  home.file.".local/bin/herdr-agent-handoff-marker".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.local/bin/herdr-agent-handoff-marker";

  # Herdr shows "working" the same way for an agent actively thinking and one
  # that has handed off to a background shell (see the fm_handed_off_shell_running
  # override in home/.config/herdr/agent-detection/claude.toml). This polls
  # `herdr agent explain` on a short interval and prefixes the tab label with an
  # hourglass while that specific rule matches, clearing it once the agent
  # resumes - see home/.local/bin/herdr-agent-handoff-marker for the logic and
  # why this is a poller rather than a herdr plugin.
  launchd.agents.herdr-agent-handoff-marker = {
    enable = true;
    config = {
      ProgramArguments = [ "${config.home.homeDirectory}/.local/bin/herdr-agent-handoff-marker" ];
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
