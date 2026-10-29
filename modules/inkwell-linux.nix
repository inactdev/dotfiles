{
  config,
  pkgs,
  lib,
  ...
}:

let
  managedPaths = import ./managed-paths.nix { homeDirectory = config.home.homeDirectory; };

  # Where the managed Inkwell backend binary lives - the same directory, from
  # the same one definition, as every other managed tool in this
  # configuration (see modules/managed-paths.nix).
  #
  # Named by this fixed path in the unit below, never by a store path, and
  # that is load-bearing rather than tidy: home-manager (re)starts exactly
  # those units whose text *changed*, so a unit that moved with every
  # generation would stop and start the backend on every single rebuild -
  # and a unit whose text never changes means a rebuilt binary needs
  # restarting by whatever rebuilt it, which is what
  # modules/inkwell-linux-sync.sh does. See
  # notes/20261021-dotfiles-auto-apply.md for where this rule came from.
  backendBin = "${managedPaths.goBin}/inkwell-backend";

  # The notes themselves: a git repository of markdown the backend writes and
  # commits into. It creates the directory and `git init`s it on first run,
  # so nothing here has to pre-create it. Deliberately outside ~/.dotfiles
  # and outside anything this configuration owns - it is the captain's data,
  # not state of this repository's.
  storageDir = "${config.home.homeDirectory}/inkwell-notes";

  # Where this box's notes are cloned from when it has none yet.
  #
  # Empty means "there is nothing to clone", and that is a complete, working
  # configuration: the backend starts its own repository at storageDir, which
  # is exactly what it does on the Mac. It just begins the box's notes from
  # nothing instead of continuing notes that already exist somewhere.
  #
  # Set it to the notes repository's URL - anything `git clone` accepts, and
  # any private repository this machine's GitHub credentials already cover
  # (modules/core.nix's gh credential helper) - and the activation step below
  # clones it once, before the backend is ever started, so the box carries on
  # the existing history rather than opening a second one beside it.
  #
  # Declared here rather than in a hand-placed file next to the key file: a
  # repository URL is not a secret, and a declaration belongs where the rest
  # of this host's declarations are. The key is the only thing about Inkwell
  # that must stay out of this repository.
  notesOrigin = "";

  # Loopback only. The phone reaches the backend through tailscale serve (see
  # the activation step at the bottom), which proxies to 127.0.0.1 on this
  # same machine, so nothing is gained by binding the LAN - and a note server
  # with no authentication of its own should not be on it.
  port = 8080;
  listenAddr = "127.0.0.1:${toString port}";

  # The key file - one file on this machine, read by every Fabrica job as
  # well as by the backend below, placed (empty, mode 600) by
  # modules/managed-key-file.nix and filled in by hand exactly once. Named
  # here by its canonical path from modules/managed-paths.nix rather than by
  # the old ~/.inkwell/env, which is now a symlink to it: the file systemd
  # loads and the file the guard reports about should be the one a human was
  # told to edit, and a refusal that names a symlink would send that human
  # to the wrong path. See modules/inkwell-key-file.sh for what is checked
  # about it and README.md for how the key gets into it.
  #
  # systemd loads it as the service's environment, so which variables are in
  # it is the file's business and not this module's.
  keyFile = managedPaths.keyFile;

  # The unit, by name, for the one script that has to start and restart it.
  # Written out rather than read back off the systemd.user.services
  # attribute below because home-manager's systemd module names a unit after
  # its attribute with no prefix of its own - unlike launchd, where the
  # label is generated and modules/inkwell.nix reads it back.
  unitName = "inkwell-backend.service";

  inkwellSync = ./inkwell-sync.sh;
  linuxSync = ./inkwell-linux-sync.sh;
  keyFileCheck = ./inkwell-key-file.sh;
  tailscaleServe = ./inkwell-tailscale-serve.sh;

  # The activation entries the key-file check and the install step must
  # follow - see the comment above each of them for what they are for. Bound
  # here rather than written inline only to keep those lines within the
  # formatter's width.
  checkAfter = [
    "writeBoundary"
    "placeManagedKeyFile"
  ];

  installAfter = [
    "linkGeneration"
    "reloadSystemd"
    "enableLinger"
    "cloneInkwellNotes"
  ];

  # go for the build and for reading the installed binary's build info, git
  # for the ls-remote and the clone (and for go's own VCS stamp), gawk for
  # the build-info parse, coreutils for mkdir/mktemp/mv/rm/stat/env - all
  # from the store, so the step behaves the same whatever a login shell has
  # on PATH. The same set modules/inkwell.nix gives the Mac's step, plus
  # nothing: the build being identical on both hosts is the whole reason
  # that script is shared.
  syncPath = lib.makeBinPath [
    pkgs.go
    pkgs.git
    pkgs.gawk
    pkgs.coreutils
  ];

  # coreutils alone for the other two: the serve step needs `timeout` and
  # `tr`, and the key-file check needs `stat`.
  coreutilsPath = lib.makeBinPath [ pkgs.coreutils ];

  # A systemd user service inherits a minimal environment, so the job gets an
  # explicit PATH of fixed directories - generation-independent, for the
  # reason given above the binary path. `git` is not optional here: the
  # backend shells out to the system git binary for every write (`git init`,
  # `git add`, `git commit` in its storage directory), so a service without
  # one would start, accept a request and fail it. The per-user profile is
  # where this configuration's git is; the rest are the ordinary system
  # directories, kept as a floor so a git found outside the Nix profile still
  # resolves.
  servicePath = lib.concatStringsSep ":" [
    "${config.home.profileDirectory}/bin"
    "/nix/var/nix/profiles/default/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
  ];
in

# Inkwell's backend on home-linux - the local server the phone posts a
# captured note to, which writes it into a git repository of markdown -
# installed, kept current, and kept running by home-manager rather than by
# hand, on the box that is always on.
#
# The Linux counterpart of modules/inkwell.nix, which does the same thing on
# the Mac with a launchd agent. Only ever composed into home-linux and into
# the ci-linux activation rehearsal (see flake.nix): systemd.user is a
# Linux-only home-manager option, and the Mac's module is Darwin-only for the
# mirror-image reason. Nothing is shared between the two beyond the build
# script and the serve script, because nothing else *can* be: launchd and
# systemd have only the idea of a user service in common.
#
# Four parts, in the order they run:
#
#   1. an activation step that says - during the switch, where somebody is
#      watching - whether the key file is there, has a key in it, and is
#      private enough to start the backend with (modules/inkwell-key-file.sh);
#   2. an activation step that clones the notes repository, once, onto a box
#      that has none yet (see notesOrigin above);
#   3. an activation step that builds the binary from the tip of inkwell's
#      main branch when what is installed is not already that, and then
#      starts the service, or restarts it onto what it just built
#      (modules/inkwell-linux-sync.sh, which delegates the build itself to
#      the same modules/inkwell-sync.sh the Mac uses);
#   4. an activation step that publishes it on this machine's tailnet address
#      over HTTPS, once, and never touches an existing serve configuration
#      (modules/inkwell-tailscale-serve.sh).
#
# Plus the service itself, below, which runs at boot and comes back when it
# dies. Two things it depends on that are not in this file: linger for this
# user, which modules/linux.nix enables on every home-linux switch (a systemd
# *user* service only runs while that user's systemd instance is up, so a
# headless box without linger would run the backend only while somebody was
# logged in), and the key file, which is modules/managed-key-file.nix's job
# because the same file is what every Fabrica job on the box reads - this
# module only reads it and refuses without it. Its *contents* remain the one
# thing about Inkwell nobody can declare anywhere in this repository.
{
  # Restart = always, unconditionally: this is a server, so every exit is a
  # reason to start it again - including the exits of its own making (the
  # backend calls log.Fatal when it cannot open its storage directory or
  # cannot bind the port) and the refusals of the ExecStartPre below.
  # StartLimitIntervalSec = 0 turns systemd's give-up-after-five-tries rate
  # limiter off, which is the same promise as the Mac agent's KeepAlive: the
  # backend is retried every ten seconds for as long as it takes, rather than
  # going quiet half a minute after a transient failure and staying down
  # until the next switch. The cost is the one case where the retry is
  # pointless until a human acts - no key file yet - where it buys a line in
  # the journal every ten seconds; the key-file step below names that file
  # during the switch, so that state is meant to be short-lived.
  #
  # Both streams go to the journal, which is where a Linux box keeps per-unit
  # logs: `journalctl --user -u inkwell-backend`. The backend writes a line
  # per request and its startup line to stderr, and systemd adds whatever a
  # failed start says.
  systemd.user.services.inkwell-backend = {
    Unit = {
      Description = "Inkwell's backend - the note server the phone posts to";
      StartLimitIntervalSec = "0";
    };

    Service = {
      # The key file, as systemd's own environment file - so the key reaches
      # the backend without this configuration ever holding it, naming the
      # variables in it, or being able to read it, and the day the backend
      # wants a second variable nothing here changes.
      #
      # The leading `-` makes a missing file systemd's non-event rather than
      # systemd's error, deliberately: the ExecStartPre below is what refuses
      # to start the backend without a key, and it says so in words that name
      # the file and the commands that fix it. It stays even though the switch
      # now places that file (modules/managed-key-file.nix), because the file
      # it places is *empty* until a human puts a key in it - which systemd
      # loads without complaint and the guard below is what catches. Nothing
      # guarantees the placing step has ever run on a box this unit is on
      # either. Without the `-`, systemd's own
      # "failed to load environment files" would get there first and be the
      # only thing in the journal.
      EnvironmentFile = "-${keyFile}";

      # The one hard refusal in this module. An ExecStartPre that exits
      # non-zero means ExecStart never runs and the unit is left failed, so a
      # key file that is missing, empty, or readable by other accounts on the
      # machine cannot quietly become a backend running without one. Run
      # through bash by absolute path because the script is a store *file*,
      # not an executable in a store package.
      ExecStartPre = "${pkgs.bash}/bin/bash ${keyFileCheck} ${keyFile}";

      ExecStart = "${backendBin} --addr ${listenAddr} --storage-dir ${storageDir}";

      Environment = [
        "HOME=${config.home.homeDirectory}"
        "PATH=${servicePath}"
      ];

      Restart = "always";
      RestartSec = "10s";
    };

    # default.target, so it comes up with this user's systemd instance -
    # which, with linger on, is at boot and not at login.
    Install.WantedBy = [ "default.target" ];
  };

  # Read-only, so it runs without `run` and reports the same thing on a dry
  # run as on a real one. `env` is what puts the store's coreutils on PATH
  # for the script's `stat`, and it is the first word on purpose: a bare
  # leading `PATH=...` is only an assignment when it is the first word at
  # parse time, so anything in front of it - an empty `$DRY_RUN_CMD`, or
  # `run`, which dispatches through `"$@"` - leaves it standing as the
  # command name instead. See notes/20261021-activation-step-env-path.md.
  #
  # This never fails the switch. The service's own ExecStartPre is the hard
  # refusal; this is the same question asked where a human can see the
  # answer, because the alternative is finding out from the journal that the
  # backend has been down since the box was built.
  # placeManagedKeyFile is modules/managed-key-file.nix's step, and naming it
  # is load-bearing: both entries are otherwise merely "after writeBoundary",
  # which puts them in no particular order relative to each other, and this
  # check reporting a missing key file on the very switch that placed it
  # would be the one run where its message is wrong. Naming an entry a host
  # does not have is harmless - home-manager's DAG simply never matches it.
  home.activation.checkInkwellKeyFile = lib.hm.dag.entryAfter checkAfter ''
    if ${pkgs.coreutils}/bin/env PATH="${coreutilsPath}:$PATH" ${pkgs.bash}/bin/bash \
      ${keyFileCheck} ${lib.escapeShellArg keyFile}; then
      echo "inkwell-backend: the key file at ${keyFile} is in place."
    else
      echo "inkwell-backend: ${unitName} will not start until that is dealt with." >&2
    fi
  '';

  # The notes, once, and only onto a box that has none: an existing
  # ~/inkwell-notes is the captain's data and is never touched, cloned over,
  # or inspected. With no origin declared this does nothing at all and says
  # nothing - the backend opening its own repository there is a correct
  # outcome, not a fallback worth a warning on every switch.
  #
  # Ordered before the service is ever started (see installAfter), because a
  # clone is only possible while the directory is still absent - once the
  # backend has created and committed into its own repository there, bringing
  # the old notes in is a merge, and a merge is a human's job.
  #
  # GIT_TERMINAL_PROMPT=0 so a box without credentials for a private notes
  # repository fails instead of blocking a non-interactive switch on a
  # username prompt, and the low-speed settings so a half-open connection
  # gives up in seconds rather than hanging the activation.
  home.activation.cloneInkwellNotes = lib.hm.dag.entryAfter [ "checkInkwellKeyFile" ] ''
    notes_origin=${lib.escapeShellArg notesOrigin}
    if [ -n "$notes_origin" ] && [ ! -e ${lib.escapeShellArg storageDir} ]; then
      if run ${pkgs.coreutils}/bin/env GIT_TERMINAL_PROMPT=0 ${pkgs.git}/bin/git \
        -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 \
        clone --quiet "$notes_origin" ${lib.escapeShellArg storageDir}; then
        echo "inkwell-notes: cloned $notes_origin into ${storageDir}."
      else
        echo "inkwell-notes: could not clone $notes_origin into ${storageDir}, so the" >&2
        echo "  backend will open an empty repository there instead the moment it" >&2
        echo "  starts. Clear the cause and re-run the switch before that happens," >&2
        echo "  or put the clone there by hand." >&2
      fi
    fi
  '';

  # Ordered after four things, each for its own reason. linkGeneration is
  # where the generation's files arrive in $HOME, which is the rule for any
  # step that reads them (see modules/inspector.nix). reloadSystemd is
  # home-manager's own step, which is what has written and read the unit
  # above - without naming it, this could ask systemctl to start a unit
  # systemd has never heard of. enableLinger is modules/linux.nix's step,
  # which is what brings this user's systemd instance up on a box that has
  # never had one, so naming it is the difference between starting the
  # backend now and starting it at the next login. cloneInkwellNotes must
  # have had its chance before anything starts the backend. Naming an entry
  # some host does not have is harmless - home-manager's DAG simply never
  # matches it - so this stays correct wherever it is composed.
  #
  # The script handles its own failures and exits 0 on all of them, so the
  # `||` is only a backstop against an unexpected one (a missing interpreter,
  # a bug): keeping the backend current is never worth losing the rest of an
  # activation over.
  home.activation.installInkwellBackend = lib.hm.dag.entryAfter installAfter ''
    run ${pkgs.coreutils}/bin/env PATH="${syncPath}:$PATH" ${pkgs.bash}/bin/bash \
      ${linuxSync} ${lib.escapeShellArg managedPaths.goBin} ${lib.escapeShellArg unitName} \
      ${inkwellSync} \
      || echo "inkwell-linux-sync exited non-zero; continuing activation." >&2
  '';

  # After the install step, not merely after it in the file: publishing a
  # tailnet address for a port that nothing is listening on yet would be true
  # but useless, and this way a first switch ends with an address the phone
  # can already reach.
  home.activation.serveInkwellOverTailscale = lib.hm.dag.entryAfter [ "installInkwellBackend" ] ''
    run ${pkgs.coreutils}/bin/env PATH="${coreutilsPath}:$PATH" ${pkgs.bash}/bin/bash \
      ${tailscaleServe} ${lib.escapeShellArg (toString port)} \
      || echo "inkwell-tailscale-serve exited non-zero; continuing activation." >&2
  '';
}
