{
  config,
  pkgs,
  lib,
  ...
}:

let
  managedPaths = import ./managed-paths.nix { homeDirectory = config.home.homeDirectory; };

  # Where the managed Inkwell backend binary lives. The directory comes from
  # modules/managed-paths.nix for the same reason modules/inspector.nix and
  # modules/fabrica.nix read it from there: modules/core.nix needs the same
  # answer to put it ahead of ~/.local/bin on PATH, and one definition of it
  # is the only way those stay in step.
  #
  # Named by this fixed path in the agent below, never by a store path, and
  # that is load-bearing rather than tidy: home-manager (re)loads exactly
  # those launchd agents whose plist text *changed*, so a plist that moved
  # with every generation would boot the backend out and back in on every
  # single rebuild - and a plist that never changes means a rebuilt binary
  # needs restarting by whatever rebuilt it, which is what
  # modules/inkwell-sync.sh does. See notes/20261021-dotfiles-auto-apply.md
  # for where this rule came from.
  backendBin = "${managedPaths.goBin}/inkwell-backend";

  # The notes themselves: a git repository of markdown the backend creates
  # and commits into on first run (it does the mkdir and the `git init`
  # itself, so nothing here has to pre-create it). Deliberately outside
  # ~/.dotfiles and outside anything this configuration owns - it is the
  # captain's data, not state of this repository's.
  storageDir = "${config.home.homeDirectory}/inkwell-notes";

  # Loopback only. The phone reaches the backend through tailscale serve
  # (see the activation step at the bottom), which proxies to 127.0.0.1 on
  # this same machine, so nothing is gained by binding the LAN - and a note
  # server with no authentication of its own should not be on it.
  port = 8080;
  listenAddr = "127.0.0.1:${toString port}";

  logFile = "${config.home.homeDirectory}/Library/Logs/inkwell-backend.log";

  # The label home-manager gives the agent below, read back off the agent
  # rather than written out again here, so the sync script is always
  # restarting the job this module actually defines.
  agentLabel = config.launchd.agents.inkwell-backend.config.Label;

  inkwellSync = ./inkwell-sync.sh;
  tailscaleServe = ./inkwell-tailscale-serve.sh;

  # The two activation entries the install step below must follow - see the
  # comment above that step for what each of them is for. Bound here rather
  # than written inline only to keep that line within the formatter's width.
  installAfter = [
    "linkGeneration"
    "setupLaunchAgents"
  ];

  # go for the build and for reading the installed binary's build info, git
  # for the ls-remote and the clone (and for go's own VCS stamp), gawk for
  # the build-info parse, coreutils for mkdir/mktemp/mv/rm/id/env - all from
  # the store, so the activation step behaves the same whatever a login
  # shell has on PATH.
  syncPath = lib.makeBinPath [
    pkgs.go
    pkgs.git
    pkgs.gawk
    pkgs.coreutils
  ];

  # coreutils alone: the serve step needs `timeout` (macOS ships none at
  # all) and `tr`. It deliberately needs no JSON parser - see that script
  # for why it matches the serve configuration as text.
  servePath = lib.makeBinPath [ pkgs.coreutils ];

  # A launchd agent inherits almost nothing, so the job gets an explicit
  # PATH of fixed directories - generation-independent, for the reason given
  # above the binary path. `git` is not optional here: the backend shells
  # out to the system git binary for every write (`git init`, `git add`,
  # `git commit` in its storage directory), so an agent without one would
  # start, accept a request and fail it. The per-user profile is where this
  # configuration's git is; the rest are the ordinary system directories
  # plus Homebrew's prefix, kept as a floor so a git found outside the Nix
  # profile still resolves.
  agentPath = lib.concatStringsSep ":" [
    "${config.home.profileDirectory}/bin"
    "/run/current-system/sw/bin"
    "/nix/var/nix/profiles/default/bin"
    "/opt/homebrew/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
  ];
in

# Inkwell's backend - the local server the phone posts a captured note to,
# which writes it into a git repository of markdown - installed, kept
# current, and kept running by home-manager rather than by hand.
#
# Three parts, in the order they run:
#
#   1. the launchd agent below, which runs the installed binary at every
#      login and restarts it whenever it dies;
#   2. an activation step that builds the binary from the tip of inkwell's
#      main branch when what is installed is not already that, and restarts
#      the agent when it does (see modules/inkwell-sync.sh - including why
#      this one builds where modules/inspector.nix `go install`s);
#   3. an activation step that publishes it on this machine's tailnet
#      address over HTTPS, once, and never touches an existing serve
#      configuration (see modules/inkwell-tailscale-serve.sh).
#
# Only ever composed into personal-mac (see flake.nix). launchd is a
# macOS-only home-manager option that does not exist in a standalone Linux
# homeConfiguration at all, and the thing this publishes to a tailnet is
# this one machine's notes: there is no second host that should answer for
# them. home-linux's equivalent, if it is ever wanted, is a systemd user
# service in modules/linux.nix and a serve step of its own.
{
  # KeepAlive = true, unconditionally: this is a server, so every exit is a
  # reason to start it again - including the exits of its own making (the
  # backend calls log.Fatal when it cannot open its storage directory or
  # cannot bind the port). launchd's own 10-second throttle is left at its
  # default, which is what bounds a crash loop; the cost of that state is
  # the one line per attempt in the log file below.
  #
  # Both streams go to ~/Library/Logs, where macOS keeps per-user logs and
  # Console.app finds them: the backend writes a line per request and its
  # startup line to stderr, and launchd adds whatever a failed spawn says.
  launchd.agents.inkwell-backend = {
    enable = true;
    config = {
      ProgramArguments = [
        backendBin
        "--addr"
        listenAddr
        "--storage-dir"
        storageDir
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
        PATH = agentPath;
      };
      StandardOutPath = logFile;
      StandardErrorPath = logFile;
    };
  };

  # Ordered after both "linkGeneration" and home-manager's own
  # "setupLaunchAgents", and each for its own reason. linkGeneration is
  # where the generation's files arrive in $HOME, which is the rule for any
  # step that reads them (see modules/inspector.nix). setupLaunchAgents is
  # what writes and bootstraps the plist above - and it is ordered after
  # "writeBoundary" rather than after linkGeneration, so without naming it
  # here the two would be in no particular order relative to each other,
  # and on a first switch this step could try to restart an agent that did
  # not exist yet. Naming an entry that some host does not have is harmless
  # (home-manager's DAG simply never matches it), so this stays correct if
  # the module is ever composed somewhere launchd is absent.
  #
  # The script handles its own failures and exits 0 on all of them, so the
  # `||` is only a backstop against an unexpected one (a missing
  # interpreter, a bug): keeping the backend current is never worth losing
  # the rest of an activation over. PATH is set here rather than inside the
  # script so the store paths stay declared where every other Nix-level
  # dependency in this repo is declared.
  #
  # `env` sets that PATH, for the reason spelled out in full above the
  # matching line in modules/fabrica.nix and in
  # notes/20261021-activation-step-env-path.md: a bare leading `PATH=...` is
  # only an assignment when it is the first word at parse time, so anything
  # in front of it - an empty `$DRY_RUN_CMD`, or `run`, which dispatches
  # through `"$@"` - leaves it standing as the command name instead. `env`
  # is what makes the assignment real wherever it sits.
  home.activation.installInkwellBackend = lib.hm.dag.entryAfter installAfter ''
    run ${pkgs.coreutils}/bin/env PATH="${syncPath}:$PATH" ${pkgs.bash}/bin/bash \
      ${inkwellSync} ${lib.escapeShellArg managedPaths.goBin} ${lib.escapeShellArg agentLabel} \
      || echo "inkwell-sync exited non-zero; continuing activation." >&2
  '';

  # After the install step, not merely after it in the file: publishing a
  # tailnet address for a port that nothing is listening on yet would be
  # true but useless, and this way a first switch ends with an address the
  # phone can already reach.
  home.activation.serveInkwellOverTailscale = lib.hm.dag.entryAfter [ "installInkwellBackend" ] ''
    run ${pkgs.coreutils}/bin/env PATH="${servePath}:$PATH" ${pkgs.bash}/bin/bash \
      ${tailscaleServe} ${lib.escapeShellArg (toString port)} \
      || echo "inkwell-tailscale-serve exited non-zero; continuing activation." >&2
  '';
}
