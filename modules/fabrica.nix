{
  config,
  pkgs,
  lib,
  ...
}:

let
  managedPaths = import ./managed-paths.nix { homeDirectory = config.home.homeDirectory; };

  # Where the managed global npm install lives, used both for the install
  # itself and for the PATH entry below. The value comes from
  # modules/managed-paths.nix rather than being written out here because
  # modules/core.nix needs the same answer to put it on PATH ahead of
  # ~/.local/bin, and one of the two had to stop guessing.
  #
  # A dedicated prefix rather than npm's own default: on a Nix host the
  # default global prefix is the nodejs package's store path, which is
  # read-only, so `npm install -g` cannot work there at all. The other
  # candidate - whichever prefix fnm's currently active Node owns - moves
  # with the directory the shell happens to be in, so a Fabrica installed
  # from one project would be off PATH in the next one. This one is stable
  # and writable, and modules/core.nix's fnm block leaves it alone.
  npmPrefix = managedPaths.npmPrefix;

  fabricaSync = ./fabrica-sync.sh;
  managedBinGuard = ./managed-bin-guard.sh;

  # git for the ls-remote, nodejs for npm (and for reading build info),
  # coreutils for mkdir/tr/date/env/mv - all from the store, so the
  # activation step behaves the same whatever a login shell has on PATH.
  #
  # bash and zsh are here for the guard, which asks a fresh login shell of
  # each what `command -v fabrica` answers (see
  # modules/managed-bin-guard.sh): the guarantee is not allowed to depend on
  # which shell is in use, so neither is the check, and a store copy of each
  # means the check happens even on a machine that is missing one. They read
  # this user's own startup files either way, which is the part that decides
  # the answer.
  syncPath = lib.makeBinPath [
    pkgs.nodejs
    pkgs.git
    pkgs.coreutils
    pkgs.bash
    pkgs.zsh
  ];
in

# Fabrica, the task orchestrator the captain runs against this and other
# repositories, installed and kept current by home-manager rather than by
# hand. See modules/fabrica-sync.sh for what the activation step does and
# every way it declines to do it; the short version is that it compares
# the installed copy's commit against origin/master and only runs
# `npm install -g github:inactdev/fabrica` when they differ, so the cost
# of an ordinary switch is one `git ls-remote`.
#
# `fabrica update` stays the day-to-day way to move Fabrica forward. This
# step is the floor under it, not a replacement for it: it guarantees that
# a freshly switched machine has Fabrica at all, and that one that has sat
# unswitched for a while is not left behind without saying so.
#
# Only personal-mac and home-linux compose this module (see flake.nix).
# Codespaces are deliberately left out: a container is a place work gets
# done, not a place work gets dispatched from, and adding a private-repo
# install to every codespace creation would cost a clone and a credential
# it has no use for. Adding it later is one line in that host's
# homeModules list.
{
  home.sessionPath = [ managedPaths.npmBin ];

  # entryAfter "writeBoundary" for the same reason every other activation
  # step here uses it: it must run after home-manager has finished writing
  # the new generation's files.
  #
  # The script handles its own failures and exits 0 on all of them, so the
  # `||` is only a backstop against an unexpected one (a missing
  # interpreter, a bug): keeping Fabrica current is never worth losing the
  # rest of an activation over. PATH is set here rather than inside the
  # script so the store paths stay declared where every other Nix-level
  # dependency in this repo is declared.
  home.activation.installFabrica = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    $DRY_RUN_CMD PATH="${syncPath}:$PATH" ${pkgs.bash}/bin/bash \
      ${fabricaSync} ${lib.escapeShellArg npmPrefix} ${managedBinGuard} \
      || echo "fabrica-sync exited non-zero; continuing activation." >&2
  '';
}
