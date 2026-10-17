{
  config,
  pkgs,
  lib,
  ...
}:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
in

# Only ever composed into personal-mac (see flake.nix) - herdr itself is a
# Homebrew cask (configuration.nix, which stays Darwin-only), so this
# config has nothing to point at on home-linux or in a codespace.
{
  home.file.".config/herdr".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/herdr";
}
