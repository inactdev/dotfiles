{
  config,
  pkgs,
  lib,
  ...
}:

let
  # The one definition of where the managed Inspector binary lives, used
  # both for the install (passed to the script, which hands it to go as
  # GOBIN) and for the PATH entry below.
  #
  # Go's own default GOBIN - $GOPATH/bin, i.e. ~/go/bin - rather than a
  # dedicated directory: it is writable on a Nix host (unlike npm's
  # default global prefix, which is the read-only nodejs store path and is
  # why modules/fabrica.nix has to own one of its own), it is where
  # anything else the captain `go install`s already goes, and it keeps the
  # module and build caches under the same ~/go the machine already uses.
  # It is passed explicitly all the same, so a `go env -w GOBIN=...` done
  # for some other reason cannot move the binary out from under the PATH
  # entry below.
  goBin = "${config.home.homeDirectory}/go/bin";

  inspectorSync = ./inspector-sync.sh;

  # go for the install and for reading the installed binary's build info,
  # git for the ls-remote (and for go's own fetch), gawk for the build-info
  # parse, coreutils for mkdir/cat - all from the store, so the activation
  # step behaves the same whatever a login shell has on PATH.
  syncPath = lib.makeBinPath [
    pkgs.go
    pkgs.git
    pkgs.gawk
    pkgs.coreutils
  ];
in

# Inspector, the checker that runs this repository's `check.sh` against a
# worker's branch, installed and kept current by home-manager rather than
# by hand - the same floor modules/fabrica.nix puts under Fabrica, for the
# same reason. See modules/inspector-sync.sh for what the activation step
# does and every way it declines to do it; the short version is that it
# compares the installed binary's module version against the tip of
# origin/main and only runs `go install
# github.com/inactdev/inspector/cmd/inspector@<that commit>` when they
# differ, so the cost of an ordinary switch is one `git ls-remote`.
#
# Only personal-mac and home-linux compose this module (see flake.nix).
# Codespaces are deliberately left out, exactly as for Fabrica: a
# container is a place work gets done, not a place work gets checked or
# dispatched from, and the cloud half of the gate runs Inspector in
# GitHub Actions rather than on anyone's machine. Adding it later is one
# line in that host's homeModules list.
{
  home.sessionPath = [ goBin ];

  # entryAfter "writeBoundary" for the same reason every other activation
  # step here uses it: it must run after home-manager has finished writing
  # the new generation's files.
  #
  # The script handles its own failures and exits 0 on all of them, so the
  # `||` is only a backstop against an unexpected one (a missing
  # interpreter, a bug): keeping Inspector current is never worth losing
  # the rest of an activation over. PATH is set here rather than inside
  # the script so the store paths stay declared where every other
  # Nix-level dependency in this repo is declared.
  home.activation.installInspector = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    $DRY_RUN_CMD PATH="${syncPath}:$PATH" ${pkgs.bash}/bin/bash \
      ${inspectorSync} ${lib.escapeShellArg goBin} \
      || echo "inspector-sync exited non-zero; continuing activation." >&2
  '';
}
