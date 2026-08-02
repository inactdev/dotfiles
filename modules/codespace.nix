{
  config,
  pkgs,
  lib,
  posture,
  ...
}:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
  isPersonal = posture == "personal";
in

# The codespace-only delta on top of modules/core.nix (see flake.nix's
# homeConfigurations."codespace-personal"/"codespace-work") - everything a
# codespace needs that isn't shared with personal-mac/home-linux, and isn't
# already excluded simply by never importing modules/desktop.nix or
# modules/mac.nix. Both codespace postures import this same module; `posture`
# (an extraSpecialArg set per flake output, mirroring install.sh's own
# detect_posture) picks the two things that still differ between them -
# nothing else does, since work Mac's separate --no-nix path
# (work/bootstrap.sh) is untouched by this and out of scope here.
{
  # personal-mac gets Claude Code via the Homebrew cask (configuration.nix);
  # a codespace has no Homebrew, so it comes from nixpkgs here instead, for
  # both postures. Deliberately not in modules/core.nix: adding it there
  # would give personal-mac/home-linux a package they don't have today,
  # which the module-split refactor must not do (see the drvPath comparison
  # in the PR description).
  home.packages = [ pkgs.claude-code ];

  # codespaces/claude-settings.json is home/.claude/settings.json (linked
  # by modules/desktop.nix for personal-mac/home-linux) with the axi-tool
  # hooks stripped, since those tools aren't installed in a codespace;
  # work/claude-settings.json is the same work Mac uses (see README.md).
  home.file.".claude/settings.json".source = config.lib.file.mkOutOfStoreSymlink (
    if isPersonal then "${dotfiles}/codespaces/claude-settings.json" else "${dotfiles}/work/claude-settings.json"
  );

  # Personal posture gets the same --dangerously-skip-permissions `cc` as
  # personal-mac/home-linux (modules/desktop.nix); work posture keeps the
  # safe, locked-down plain alias - see core.nix's shellAliases comment for
  # why `cc` isn't set there.
  programs.zsh.shellAliases.cc = if isPersonal then "claude --dangerously-skip-permissions" else "claude";
}
