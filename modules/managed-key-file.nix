{
  config,
  pkgs,
  lib,
  ...
}:

let
  managedPaths = import ./managed-paths.nix { homeDirectory = config.home.homeDirectory; };

  # The one key file, and the old Inkwell path that is now a symlink to it -
  # both from modules/managed-paths.nix, for the same reason the managed bin
  # directories come from there: modules/inkwell-linux.nix names the same
  # canonical path in the service's EnvironmentFile= and ExecStartPre=, and
  # one definition is the only way the file this step places and the file
  # that service reads cannot drift apart.
  keyFile = managedPaths.keyFile;
  keyFileLink = managedPaths.keyFileLink;

  keyFileStep = ./managed-key-file.sh;

  # coreutils for mkdir/chmod/install/stat/readlink/ln/mv/rm/env, diffutils
  # for the one `cmp` that decides whether a duplicate can be removed
  # losslessly - both from the store, so the step behaves the same whatever
  # a login shell has on PATH, and so the GNU spellings the script uses
  # (`stat -c`, `readlink -f`) are the ones it gets on the Mac too.
  stepPath = lib.makeBinPath [
    pkgs.coreutils
    pkgs.diffutils
  ];
in

# One key file for every job on this machine that needs the captain's model
# key - Fabrica's and Inkwell's backend's alike - placed by the switch,
# private from the moment it exists, and never duplicated by hand
# (inkwell#46).
#
# The whole mechanism is modules/managed-key-file.sh; see its header for what
# it places, what it migrates, and the cases where it deliberately touches
# nothing. What belongs here instead is why this is a module of its own and
# not a few lines inside another one:
#
#   - it is not Inkwell's. modules/inkwell-linux.nix is where the key file is
#     *read* (and where the one hard refusal about it lives, in the service's
#     ExecStartPre), but the same file is what every Fabrica job reads, on
#     both hosts - including personal-mac, which composes no Inkwell service
#     with a key file at all. A step that places it inside either tool's
#     module would make the key file look like that tool's property.
#   - it is not modules/core.nix's. Codespaces compose core and nothing else
#     here: a container is a place work gets done, not a place work gets
#     dispatched from (see modules/fabrica.nix), so it has no Fabrica, no
#     Inkwell backend and no business being handed a key-file path at all.
#
# So: composed into personal-mac, home-linux and ci-linux (see flake.nix) -
# the hosts that actually run those jobs, plus the rehearsal host that runs
# their activation steps for real in CI.
#
# This module declares no file, no systemd unit and no launchd agent on
# purpose. home.file with mkOutOfStoreSymlink could declare the symlink
# itself, and is the wrong tool twice over: it cannot create the canonical
# file nor give it a mode (nothing outside the store gets one), and its
# answer to an unmanaged file already sitting at the link path is to rename
# it to <path>.hm-backup - which, for a file holding a key, leaves a second
# copy of that key on disk and is precisely the smell this exists to end.
{
  # Ordered *before* home-manager's own "checkLinkTargets", which makes this
  # the first thing any switch does. Two reasons, and the second is why it is
  # not the usual `entryAfter [ "writeBoundary" ]`:
  #
  #   - nothing here needs the write boundary. That marker is the point after
  #     which a step may touch files home-manager itself links, and the two
  #     paths this step writes - ~/.fabrica/brain.env and ~/.inkwell/env - are
  #     paths no module declares and linkGeneration never touches. The step
  #     also reads nothing from the generation.
  #   - checkLinkTargets aborts the *entire* activation with exit 1 whenever
  #     an unmanaged file or symlink is sitting where a managed file goes
  #     (a symlink is not rescued by -b hm-backup, and a backup that would
  #     clobber an existing one is refused outright). Every step after it,
  #     this one included, then silently does not run - and a key file is the
  #     wrong thing to lose to an unrelated collision somewhere else in the
  #     home directory, because the Inkwell backend's guard and every Fabrica
  #     job are left pointing at a file that does not exist. Placing it first
  #     costs nothing and takes the whole rest of the activation out of the
  #     question: an empty private file and a symlink are correct on their own
  #     terms whether or not the generation that follows them links.
  #
  # The step stays idempotent and silent once the file is there, so being
  # first changes nothing on any later switch, and `run` still only prints
  # under a dry run.
  #
  # modules/inkwell-linux.nix's checkInkwellKeyFile names *this* entry in its
  # own entryAfter, which is what keeps the check downstream of the placement
  # (it would otherwise be merely "after writeBoundary", which orders it
  # against nothing) - and the check reporting a missing key file on the very
  # switch that placed it would be the one run where its message is wrong.
  #
  # `run`, because this step writes: a dry run prints the command instead of
  # executing it. `env` is what applies the PATH, and it is the first word on
  # purpose - a bare leading `PATH=...` is only an assignment when it is the
  # first word at parse time, so anything in front of it (an empty
  # `$DRY_RUN_CMD`, or `run`, which dispatches through `"$@"`) leaves it
  # standing as the command name instead. See
  # notes/20261021-activation-step-env-path.md.
  #
  # The script reports its own refusals and exits 0 on every one of them, so
  # the `||` is only a backstop against an unexpected failure (a missing
  # interpreter, a bug): the hard refusal about this key file belongs to the
  # service that reads it, and tidying one key file is never worth losing the
  # rest of an activation over.
  home.activation.placeManagedKeyFile = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    run ${pkgs.coreutils}/bin/env PATH="${stepPath}:$PATH" ${pkgs.bash}/bin/bash \
      ${keyFileStep} ${lib.escapeShellArg keyFile} ${lib.escapeShellArg keyFileLink} \
      || echo "managed-key-file exited non-zero; continuing activation." >&2
  '';
}
