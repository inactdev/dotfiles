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

{
  # Shared identity every host needs regardless of package set - `user` is
  # supplied per host in flake.nix (a hardcoded literal for personal-mac/
  # home-linux, read from the environment for codespace, which does not
  # run as the captain's own username).
  home.username = user;
  home.homeDirectory = if isDarwin then "/Users/${user}" else "/home/${user}";
  home.stateVersion = "24.11";

  home.packages = with pkgs; [
    # editors & terminal
    neovim
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

  # Identity (user.name/email) is deliberately NOT set here - it lives in
  # modules/desktop.nix instead, which only personal-mac/home-linux import.
  # A codespace gets git identity/auth injected by GitHub via env, and
  # setting it here would fight that (see install.sh's configure_git-era
  # comment history and README.md's Codespaces section).
  programs.git = {
    enable = true;
    settings = {
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
    # `cc` (the claude launcher alias) is deliberately NOT set here: it
    # varies by trust level - personal-mac/home-linux (modules/desktop.nix)
    # and personal-posture codespaces (modules/codespace.nix) always get
    # --dangerously-skip-permissions, but a work-posture codespace must
    # not, so each of those modules sets `cc` itself rather than this
    # shared one needing to know about posture at all.
    shellAliases = {
      bx = "bundle exec";
      vim = "nvim";
      cssh = "infocmp -x xterm-ghostty | ssh gh codespace ssh tic -x -h";
    };
    # Guarded rather than split per-platform: rbenv/brew are only ever
    # present on Darwin (installed via configuration.nix's homebrew
    # module), so this one shared block just no-ops cleanly on Linux and
    # in a codespace container, both of which have neither.
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
  home.file.".config/starship.toml".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/starship.toml";
  home.file."AGENTS.md".source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  # Makes it so that claude and all other LLMs behave the same
  home.file.".claude/CLAUDE.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  # Linked as a directory, not per-file, so a style added under
  # home/.claude/output-styles/ is picked up with no config change. Shared
  # here rather than in desktop.nix/codespace.nix: which styles exist is
  # discoverability, not a trust or posture decision (unlike
  # .claude/settings.json, which does vary by host) - every host, including
  # both codespace postures, should see the same set.
  home.file.".claude/output-styles".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.claude/output-styles";
}
