{
  config,
  pkgs,
  lib,
  ...
}:

let
  isDarwin = pkgs.stdenv.isDarwin;
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
in

# This module is exactly the {personal-mac, home-linux} host set - a
# codespace container never imports it - so it's also where anything
# structurally excluded from a codespace by design lives, not just the
# literal screen/terminal-app pieces the name suggests: git identity
# (GitHub Codespaces injects that via env instead) and the local-machine
# Claude settings variant (its axi-tool hooks assume tools that only exist
# on personal-mac/home-linux).
lib.mkMerge [
  {
    programs.git.settings.user = {
      name = "inactdev";
      email = "aris.a.perez@gmail.com";
    };

    # The captain's own machines are always trusted - see core.nix's
    # shellAliases comment for why this isn't set there instead.
    programs.zsh.shellAliases.cc = "claude --dangerously-skip-permissions";

    home.file.".config/ghostty".source =
      config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/ghostty";
    home.file.".config/wezterm".source =
      config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/wezterm";
    # codespaces/claude-settings.json (linked by modules/codespace.nix
    # instead) is this file with the axi-tool hooks stripped.
    home.file.".claude/settings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.claude/settings.json";
  }

  # Linux-only: the Nerd Font has no Homebrew-cask equivalent to fall back
  # on here, so it's installed explicitly rather than via home-manager's
  # fonts.fontconfig alone - landed in ~/.local/share/fonts (not the Mac
  # ~/Library/Fonts path, which doesn't exist on Linux) with an explicit
  # fc-cache refresh so terminals see it without a re-login.
  #
  # ghostty's home.packages entry lives in this same isDarwin-gated block,
  # not a separate lib.optionals-on-Darwin one: mkIf false drops the whole
  # attrset (no definition contributed at all), where lib.optionals would
  # still contribute an empty-list definition on Darwin. An extra
  # definition - even an empty one - changes the *order* home-manager's
  # module system concatenates the various home.packages contributions
  # (this module's, core.nix's, and each enabled `programs.*`'s own), which
  # changes the built profile's derivation hash on personal-mac even though
  # the actual installed package set is unaffected either way.
  (lib.mkIf (!isDarwin) {
    home.packages = with pkgs; [ ghostty ];

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
