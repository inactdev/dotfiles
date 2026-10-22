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
  # The two managed bin directories, by their one definition - see the PATH
  # line in the zsh block below for why this module needs to know them.
  managedPaths = import ./managed-paths.nix { homeDirectory = config.home.homeDirectory; };
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
    nodejs # fallback node, for anywhere fnm has no .node-version to act on
    fnm
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

  # Enabled for the startup files it writes, not because anyone's daily
  # shell changes: zsh (below) stays that. But bash is what a login over
  # ssh, a script, an agent harness and the managed-binary guard all end up
  # in, and home-manager only writes ~/.bash_profile, ~/.bashrc and
  # ~/.profile when this is on. Those files are the only thing that puts
  # home.sessionPath on a bash login shell's PATH: ~/.bash_profile sources
  # ~/.profile, which sources hm-session-vars.sh, which is where
  # home-manager exports the session path - prepending it, so the managed
  # directories come ahead of whatever was there already. Without them a
  # bash login shell saw neither ~/go/bin nor ~/.npm-global/bin, because
  # the line that covers zsh is in the zsh block below and nowhere else -
  # so a managed tool was installed and then not found, which is exactly
  # what the guard at the end of each sync script exists to catch. Nothing
  # of zsh's ordering is duplicated here on purpose: hm-session-vars is the
  # only PATH edit on the bash side, so there is no hand-added
  # ~/.local/bin for a stale copy to be found in first.
  #
  # One consequence on a machine that has never been switched: those three
  # files become files home-manager owns, and it stops rather than
  # overwrite an existing regular file at any of them unless the switch is
  # given a backup extension. install.sh passes one (`-b hm-backup`) and
  # personal-mac's nix-darwin configuration sets one; `./run.sh`'s
  # home-linux switch passes none, so a box with its distribution's own
  # ~/.bashrc or ~/.profile still in place needs those moved aside once by
  # hand, or the switch given `-b`, before the first apply after this
  # lands.
  programs.bash.enable = true;

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

      # The two directories this configuration installs managed tools into
      # go ahead of ~/.local/bin, which is the whole point of writing them
      # out here: home.sessionPath (modules/inspector.nix,
      # modules/fabrica.nix) lands in hm-session-vars.sh, which is sourced
      # before this line runs, so a bare `export PATH="$HOME/.local/bin:$PATH"`
      # put every hand-dropped copy in front of every managed one - that is
      # how a stale ~/.local/bin/inspector came to shadow ~/go/bin/inspector.
      # The directories are named by modules/managed-paths.nix, which the two
      # installing modules read as well, so there is still one definition of
      # each. Shared here rather than per-module because PATH order is only
      # meaningful in one place: naming all three in a single line is what
      # makes the order reviewable. A codespace composes this module without
      # those two (see flake.nix), where the entries are simply directories
      # that do not exist - which PATH ignores.
      export PATH="${managedPaths.goBin}:${managedPaths.npmBin}:$HOME/.local/bin:$PATH"

      if command -v rbenv >/dev/null 2>&1; then
        eval "$(rbenv init - zsh)"
      fi

      # Per-project node: fnm switches on cd to whatever .node-version (or
      # .nvmrc) declares. `fnm env` prepends its own bin dir to PATH, so an
      # active version beats the nodejs package above, which is left as the
      # fallback for everywhere that declares nothing.
      if command -v fnm >/dev/null 2>&1; then
        eval "$(fnm env --use-on-cd --shell zsh --version-file-strategy=recursive)"
        # Then replace the body of the chpwd hook that eval just registered.
        # Redefining it by name (rather than registering a second hook of our
        # own) leaves fnm owning the wiring, and degrades to stock fnm
        # behavior if a future version renames it. Two changes:
        #   - --install-if-missing: cd'ing into a project whose version isn't
        #     downloaded yet installs it instead of failing.
        #   - a version-file guard: the recursive strategy's own hook drops
        #     fnm's local-strategy guard and runs `fnm use` on every cd, which
        #     prints "Can't find version in dotfiles" in any directory with no
        #     version file above it (fnm issues #681, #1308) unless a `fnm
        #     default` alias is set. Walking up in the shell keeps that quiet
        #     without hiding real install errors behind 2>/dev/null.
        _fnm_version_file_above() {
          local dir=$PWD
          while [ -n "$dir" ]; do
            if [ -f "$dir/.node-version" ] || [ -f "$dir/.nvmrc" ]; then
              return 0
            fi
            dir=''${dir%/*}
          done
          return 1
        }
        _fnm_autoload_hook() {
          if _fnm_version_file_above; then
            fnm use --install-if-missing --silent-if-unchanged
          fi
        }
        _fnm_autoload_hook
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
  # .claude/settings.json, which does vary by host) - every Nix host,
  # personal-posture codespaces included, should see the same set. The two
  # --no-nix hosts (work Mac, codespace-work) don't link it at all, same as
  # they never have.
  home.file.".claude/output-styles".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.claude/output-styles";
}
