# The one definition of the two directories this configuration installs
# managed command-line tools into, shared by the three modules that have to
# agree about them: modules/inspector.nix (installs Inspector into the Go
# bin directory), modules/fabrica.nix (installs Fabrica into the npm global
# prefix) and modules/core.nix (puts both ahead of ~/.local/bin on PATH, so
# a stray copy dropped there by hand cannot shadow a managed one).
#
# A plain function file, deliberately NOT a home-manager module and never
# added to a host's homeModules list in flake.nix: an extra module would
# take its own position in the module tree and change the order
# home-manager concatenates list-typed options such as home.packages, which
# changes a host's derivation hash without changing anything it installs -
# see the homeModules comment in flake.nix.
{ homeDirectory }:

let
  # Go's own default GOBIN ($GOPATH/bin) - see modules/inspector.nix for
  # why the managed Inspector lives there rather than in a directory of its
  # own.
  goBin = "${homeDirectory}/go/bin";
  # The dedicated npm global prefix modules/fabrica.nix owns - see that
  # file for why npm's own default cannot be used on a Nix host.
  npmPrefix = "${homeDirectory}/.npm-global";
in

{
  inherit goBin npmPrefix;
  npmBin = "${npmPrefix}/bin";
}
