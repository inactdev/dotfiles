# The one definition of the paths more than one module in this
# configuration has to agree about, which is two things:
#
#   - the two directories managed command-line tools are installed into,
#     shared by modules/inspector.nix (installs Inspector into the Go bin
#     directory), modules/fabrica.nix (installs Fabrica into the npm global
#     prefix) and modules/core.nix (puts both ahead of ~/.local/bin on PATH,
#     so a stray copy dropped there by hand cannot shadow a managed one);
#   - the one key file every job that needs the captain's model key reads,
#     shared by modules/managed-key-file.nix (places it, and links the old
#     Inkwell path to it) and modules/inkwell-linux.nix (hands it to the
#     backend's service as its environment file).
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
  # The one key file every Fabrica and Inkwell job on a machine reads, and
  # the path Inkwell's key was duplicated to by hand before there was one
  # (inkwell#46), now kept as a symlink to the canonical file so anything
  # still reaching for it reads the same bytes.
  #
  # Fabrica's path is the canonical one because Fabrica was reading it
  # first: a key file is named for whoever has to find it, not for
  # whichever job was written last. Neither path is a secret - the key
  # itself never enters this repository, encrypted or not (see
  # modules/managed-key-file.sh).
  keyFile = "${homeDirectory}/.fabrica/brain.env";
  keyFileLink = "${homeDirectory}/.inkwell/env";
in

{
  inherit
    goBin
    npmPrefix
    keyFile
    keyFileLink
    ;
  npmBin = "${npmPrefix}/bin";
}
