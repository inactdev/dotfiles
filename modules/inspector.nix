{
  config,
  pkgs,
  lib,
  ...
}:

let
  managedPaths = import ./managed-paths.nix { homeDirectory = config.home.homeDirectory; };

  # Where the managed Inspector binary lives, used both for the install
  # (passed to the script, which hands it to go as GOBIN) and for the PATH
  # entry below. The value comes from modules/managed-paths.nix rather than
  # being written out here because modules/core.nix needs the same answer
  # to put it on PATH ahead of ~/.local/bin, and one of the two had to stop
  # guessing.
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
  goBin = managedPaths.goBin;

  inspectorSync = ./inspector-sync.sh;
  managedBinGuard = ./managed-bin-guard.sh;

  # go for the install and for reading the installed binary's build info,
  # git for the ls-remote (and for go's own fetch), gawk for the build-info
  # parse, coreutils for mkdir/cat/date/env/mv - all from the store, so the
  # activation step behaves the same whatever a login shell has on PATH.
  #
  # bash and zsh are here for the guard, which asks a fresh login shell of
  # each what `command -v inspector` answers (see
  # modules/managed-bin-guard.sh): the guarantee is not allowed to depend on
  # which shell is in use, so neither is the check, and a store copy of each
  # means the check happens even on a machine that is missing one. They read
  # this user's own startup files either way, which is the part that decides
  # the answer.
  syncPath = lib.makeBinPath [
    pkgs.go
    pkgs.git
    pkgs.gawk
    pkgs.coreutils
    pkgs.bash
    pkgs.zsh
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
  #
  # `env` sets that PATH, for the reason spelled out in full above the
  # matching line in modules/fabrica.nix: a bare leading `PATH=...` is only
  # an assignment when it is the first word at parse time, so prefixing it
  # with anything that can expand to nothing (`$DRY_RUN_CMD`, as this line
  # did) or that dispatches through `"$@"` (`run`, which replaces it) turns
  # it into the command name instead. `run` is the supported replacement
  # for the deprecated `$DRY_RUN_CMD`; `env` is what makes the assignment
  # real wherever it sits in the argument list.
  home.activation.installInspector = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.coreutils}/bin/env PATH="${syncPath}:$PATH" ${pkgs.bash}/bin/bash \
      ${inspectorSync} ${lib.escapeShellArg goBin} ${managedBinGuard} \
      || echo "inspector-sync exited non-zero; continuing activation." >&2
  '';
}
