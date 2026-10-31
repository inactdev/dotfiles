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

  # The one Node version Fabrica is supported on, taken from the single
  # plain-text pin at the repository root - the same file work/bootstrap.sh
  # reads for the work Mac (see its own FABRICA_NODE_VERSION block). The
  # sync script takes it as an argument and generates a launcher that runs
  # Fabrica through `fnm exec --using=<version>`, so a repository's own
  # .node-version cannot decide which Node the orchestrator itself gets on
  # these hosts either.
  #
  # Read here and interpolated into the activation command line, rather
  # than read by the script at run time, so the pinned version is part of
  # this generation's derivation: bumping the file changes the activation
  # script, which is what makes a switch notice the bump at all.
  fabricaNodeVersion = lib.strings.trim (builtins.readFile ../fabrica-node-version);

  # git for the ls-remote, nodejs for npm (and for reading build info),
  # coreutils for mkdir/tr/date/env/mv, fnm for the Node pin above - all
  # from the store, so the activation step behaves the same whatever a
  # login shell has on PATH.
  #
  # fnm is the one of these whose *own* state lives outside the store: it
  # downloads the pinned Node into its default base directory under $HOME,
  # which is exactly where the fnm that modules/core.nix puts in a login
  # shell's PATH looks for it. Neither side sets FNM_DIR, so both agree.
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
    pkgs.fnm
    pkgs.bash
    pkgs.zsh
  ];
in

# Fabrica, the task orchestrator the captain runs against this and other
# repositories, installed and kept current by home-manager rather than by
# hand. See modules/fabrica-sync.sh for what the activation step does and
# every way it declines to do it; the short version is that it compares
# the installed copy's commit against origin/master and only installs
# (a `git clone` of its own, `npm pack` inside that clone, then
# `npm install -g` of the tarball - the script's own comments say why it
# is three steps and why no shorter form works) when they differ, so the
# cost of an ordinary switch is one `git ls-remote`.
#
# The step also pins which Node that copy runs on - exactly
# ./fabrica-node-version, through `fnm exec --using`, regardless of the
# .node-version of whatever directory `fabrica` is invoked from. That half
# runs on every activation, including the ones that install nothing: see
# modules/fabrica-sync.sh's pin_fabrica_to_node.
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

  # entryAfter "linkGeneration", not "writeBoundary": the step has to run
  # after the new generation's files are *linked into $HOME*, not merely
  # written into the store. home-manager's writeBoundary is only the point
  # after which a step may touch the user's files at all; linkGeneration is
  # the step that creates the symlinks, and it comes later. The difference
  # is load-bearing here because the sync script ends by asking a fresh
  # login shell of each shell what `command -v fabrica` answers (see
  # modules/managed-bin-guard.sh), and on a home directory that has never
  # been switched before, a shell started any earlier than this has no
  # startup files yet - so the probe finds nothing and the guard reports a
  # managed tool that a shell cannot see, on the one run where that is
  # guaranteed to be wrong.
  #
  # The script handles its own failures and exits 0 on all of them, so the
  # `||` is only a backstop against an unexpected one (a missing
  # interpreter, a bug): keeping Fabrica current is never worth losing the
  # rest of an activation over. PATH is set here rather than inside the
  # script so the store paths stay declared where every other Nix-level
  # dependency in this repo is declared.
  #
  # `env` sets that PATH, and the two details about this line are both
  # load-bearing:
  #
  #   - `run` rather than the deprecated `$DRY_RUN_CMD` prefix, which
  #     home-manager keeps only for backward compatibility. `run` executes
  #     its arguments, echoing them instead on a dry run.
  #   - `env`, not a bare leading `PATH=...` word. A shell only treats
  #     `PATH=...` as an assignment when it is the first word *at parse
  #     time*, so `$DRY_RUN_CMD PATH=... bash ...` left `PATH=...` standing
  #     as the command name the moment DRY_RUN_CMD expanded to nothing -
  #     which is every real switch - and the step died with
  #     `PATH=/nix/store/...: No such file or directory` before the sync
  #     script was ever reached. `run` would do the same thing for the same
  #     reason: it dispatches through `"$@"`, so a leading `PATH=...` is an
  #     argument, not an assignment. `env` is what actually applies it.
  #     install.container-test.sh activates this step for real on Linux so
  #     that a return to either shape fails CI instead of passing it.
  home.activation.installFabrica = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run ${pkgs.coreutils}/bin/env PATH="${syncPath}:$PATH" ${pkgs.bash}/bin/bash \
      ${fabricaSync} ${lib.escapeShellArg npmPrefix} \
      ${lib.escapeShellArg fabricaNodeVersion} ${managedBinGuard} \
      || echo "fabrica-sync exited non-zero; continuing activation." >&2
  '';
}
