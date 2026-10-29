# dotfiles

My configs, covering five machine profiles from one repo: a home Mac and
home Linux box via Nix, a work Mac via plain Homebrew, and GitHub
Codespaces (personal posture via Nix, work posture via the same
Homebrew-free approach as the work Mac) via a non-interactive install
script.

### NOTE: Requires Go to be installed to run fzf-lua

## Getting started

Clone the repo and run `./run.sh` (or `./run.sh bootstrap`). With no host
remembered yet, it asks once whether this is a home or work computer and
remembers the answer for next time (`./run.sh choose` to change it later,
`./run.sh plan` to preview changes, `./run.sh rebuild` to re-apply after
editing a tracked config file). To skip the menu, pass a host and/or
`--no-nix` explicitly. Full details, including exactly how host selection
works: `./run.sh help`.

## Home hosts (Nix)

`personal-mac`, `home-linux`, and Codespaces' *personal* posture (below)
get the full setup via Nix + home-manager, composed from `modules/`:

- `modules/core.nix` - cross-host CLI tooling (nvim, ripgrep, fd, fzf, jq,
  node + fnm, formatters, git behavior, zsh + aliases, starship, direnv) and the
  AGENTS.md/nvim-config symlinks. Every host imports this. It also enables
  `programs.bash`, purely so home-manager writes the bash startup files
  that put `home.sessionPath` (`~/go/bin`, `~/.npm-global/bin`) on a bash
  login shell's PATH - zsh is still the shell everything else here is
  built around. On a machine that already has its own `~/.bashrc`,
  `~/.bash_profile` or `~/.profile`, home-manager will refuse to overwrite
  them - so every switch here carries a backup extension and moves them to
  `<name>.hm-backup` instead: `-b hm-backup` from `./run.sh` and
  `install.sh`, `home-manager.backupFileExtension` from `personal-mac`'s
  nix-darwin configuration. Only a hand-written `home-manager switch` of
  your own needs the flag added by hand (before the `switch` word - after
  it, home-manager ignores it).
- `modules/desktop.nix` - ghostty, fonts, git *identity*, and the
  local-machine Claude settings variant (`home/.claude/settings.json`,
  axi-tool hooks included) - anything that needs a screen, a local
  terminal app, or is specific to a machine the captain owns outright.
  `personal-mac` and `home-linux` import this; Codespaces does not, so all
  of it is structurally absent there.
- `modules/fabrica.nix` - the Fabrica CLI, installed and kept current by
  home-manager activation (see "Fabrica" below). `personal-mac` and
  `home-linux` import this; Codespaces does not.
- `modules/inspector.nix` - the Inspector CLI, installed and kept current
  by home-manager activation the same way (see "Inspector" below).
  `personal-mac` and `home-linux` import this; Codespaces does not.
- `modules/inkwell.nix` - Inkwell's backend as a launchd user agent, built
  and kept running by home-manager activation (see "Inkwell's backend on
  the Mac" below). `personal-mac` only; launchd exists nowhere else.
- `modules/inkwell-linux.nix` - the same backend as a systemd user service,
  with the key-file check and the notes clone (see "Inkwell's backend on
  `home-linux`" below). `home-linux` only - and the host it is actually
  meant to run on, being the one that is always on.
- `modules/managed-key-file.nix` - the one key file every Fabrica and
  Inkwell job reads, placed privately by the switch and never duplicated by
  hand (see "One key file for every Fabrica and Inkwell job" below).
  `personal-mac` and `home-linux` import this - the hosts that run those
  jobs; Codespaces does not, having neither.
- `modules/mac.nix` - the herdr config symlink, and the launchd agent that
  drives the self-update job below (on this host it fetches and tells you
  an update is ready; it never switches). `personal-mac` only (herdr is a
  Homebrew cask, and launchd doesn't exist elsewhere).
- `modules/linux.nix` - the systemd user timer that drives the same job,
  which on this host also applies what it fetched. `home-linux` only;
  Codespaces does not import it (a container is applied once at creation
  and then thrown away).
- `modules/codespace.nix` - the Codespaces-only delta (Claude Code itself,
  since there's no Homebrew cask to lean on; which Claude settings file;
  the `cc` alias) - see the Codespaces section below.

`flake.nix` defines `darwinConfigurations.personal-mac` and
`homeConfigurations.home-linux`/`.codespace-personal`/`.codespace-work` by
composing these module files per host (`personal-mac` =
core+desktop+fabrica+inkwell+inspector+mac, `home-linux` =
core+desktop+fabrica+inkwell-linux+inspector+linux, each codespace posture
= core+codespace).
`configuration.nix` adds Darwin-only system settings and Homebrew (for the
handful of casks/formulas Nix doesn't cover well on macOS, e.g. GUI apps).

`homeConfigurations.codespace-work` still exists in `flake.nix` and is
still eval-checked by CI, but nothing in this repo applies it anymore -
`install.sh` never invokes Nix for work-posture Codespaces (see below).
It's left in place deliberately rather than removed, since removing it
isn't required by the no-Nix work-posture change and would touch
`flake.nix`/`modules/codespace.nix` beyond what that change needs.

Homebrew on the Mac host runs with `onActivation.cleanup = "zap"`:
`darwin-rebuild switch` uninstalls and untaps anything installed but not
declared in `configuration.nix`, including unlisted taps (only
`homebrew/core` is exempt). Everything in the `brews`/`casks`/`taps` lists
there is what's meant to survive; if something disappears after a rebuild
that you wanted kept, add it there rather than re-installing by hand.

### Fabrica

`fabrica update` is still the day-to-day way to move Fabrica forward -
nothing here replaces it, and nothing here needs running by hand.

What `modules/fabrica.nix` adds is a floor under it. On every activation
(`./run.sh rebuild`, or a plain `home-manager switch`) on `personal-mac`
and `home-linux`, `modules/fabrica-sync.sh` reads the tip of
`master` from `github.com/inactdev/fabrica` with `git ls-remote`,
compares it against the commit the installed copy was built from (its own
build info, or failing that what this step recorded the last time it
installed), and installs only when the two differ. Matching commits cost
one network read and change nothing; a machine with no Fabrica on it at
all gets one installed.

The install itself is a `git clone --depth 1` of `master` into a
temporary directory, `npm pack` inside that clone, and `npm install -g`
of the tarball that produced - never `npm install -g
github:inactdev/fabrica`, and never `npm pack` of that spec either.
Neither shorter form works. The one-step install is broken by npm for
everyone: it installs a git spec globally by symlinking the prefix at its
own temporary clone and then deleting the clone, so Fabrica's build step
is left running in a directory that no longer exists. Packing the
`github:` spec instead fails more quietly: for a `github:` spec npm
fetches GitHub's tarball of the tree rather than cloning, so there is no
`.git` for Fabrica's build step to read its commit out of - the install
succeeds, `build-info.json` lands saying `{"commit":null}`, and the only
symptom is `fabrica doctor` refusing to work afterwards. Cloning first
gives that build step a real repository to read, and the tarball installs
like any other package.

Two details worth knowing:

- **It never fails a switch.** Offline, rate-limited, or without
  credentials for the repo, the step prints a warning saying the
  installed copy was left alone and activation carries on.
- **The install is in `~/.npm-global`,** which `home.sessionPath` puts on
  PATH, rather than in npm's own default global prefix. On a Nix host that
  default is the read-only `nodejs` store path, where `npm install -g`
  cannot write at all; the other candidate - whichever prefix fnm's
  active Node owns - changes with the directory you are standing in. Note
  the consequence: if you run `fabrica update` (or any `npm install -g`)
  in a shell where fnm has switched Node, npm installs into *that*
  version's prefix, and fnm's PATH entry means the copy you get is the one
  you just installed, not the managed one. That is a question of which
  file runs rather than which version - both are being pointed at the same
  `master` - and `which fabrica` answers it. The next activation moves
  that copy aside and says so (see "The managed copy is the one a shell
  finds" below).

### Inspector

`modules/inspector.nix` is the same floor under Inspector that
`modules/fabrica.nix` is under Fabrica, and likewise needs nothing run by
hand. On every activation (`./run.sh rebuild`, or a plain `home-manager
switch`) on `personal-mac` and `home-linux`,
`modules/inspector-sync.sh` reads the tip of `main` from
`github.com/inactdev/inspector` with `git ls-remote`, compares it against
the module version baked into the installed binary, and runs `go install
github.com/inactdev/inspector/cmd/inspector@<that commit>` only when the
two differ. A match costs one network read and changes nothing; a machine
with no Inspector on it at all gets one installed.

Three details worth knowing:

- **It never fails a switch.** Offline, rate-limited, or without
  credentials for the repo, the step prints a warning saying the
  installed copy was left alone and activation carries on. Same for a
  `go install` that fails for any reason of its own.
- **Nothing has to be recorded to make the comparison work.** Unlike
  npm, `go install <pkg>@<commit>` writes the version it resolved into
  the binary, and `go version -m` reads it back: an untagged commit
  resolves to a pseudo-version ending in the commit's first 12
  characters, so the installed revision is simply there to be read. (The
  one case that would not be - a commit carrying a semver tag, which
  resolves to the tag instead - is covered by a line the step writes
  under `$XDG_STATE_HOME/inspector-sync/`, so even then it reinstalls
  once rather than on every switch. See
  `notes/20261021-inspector-home-manager-install.md`.)
- **The binary goes to `~/go/bin`,** Go's own default `GOBIN`, which
  `home.sessionPath` puts on PATH - so anything else you have
  `go install`ed is already there too. It is also the copy a shell finds,
  which is a guarantee rather than a hope - see below.

### The managed copy is the one a shell finds

Installing the right binary is only half the job: the one `inspector` or
`fabrica` resolves to has to be that same binary. Two things make sure of
it on `personal-mac` and `home-linux` alike.

`modules/core.nix` puts `~/go/bin` and `~/.npm-global/bin` on PATH
*ahead* of `~/.local/bin` (all three in one line, so the order is
reviewable in one place). The directories themselves are named once, in
`modules/managed-paths.nix`, which the two installing modules read too.

Then, on every activation, both sync scripts end by calling
`modules/managed-bin-guard.sh` - on every path through them, including the
ones that install nothing, since a machine with nothing to install today
is where a stale copy survives longest. It asks a fresh `bash` *and* `zsh`
login shell what `command -v <tool>` answers, and:

- another copy under your home directory is **moved aside**, not deleted,
  into `~/.cache/dotfiles-shadowed/<timestamp>/<its path under $HOME>`,
  with both paths printed - so a copy moved by mistake is one `mv` from
  coming back. (The stale `~/.local/bin/inspector` that shadowed
  `~/go/bin/inspector` is the case this exists for.)
- a copy it must not touch - outside your home directory, or one that
  resolves into the Nix store, which means something installs it
  declaratively - gets a loud warning on stderr naming the exact path, and
  is left exactly where it is.
- if the managed copy is not installed at all (a failed or skipped
  install), nothing is moved: the stale copy may be the only one on the
  machine.
- a leftover `npm link` symlink at `~/.local/lib/node_modules/<tool>` is
  **removed**, which is the one thing here that is deleted rather than
  moved: the link holds no content, one `npm link` puts it back, and the
  checkout on the far end of it is never touched. It has to go because
  while it stands, npm reads `~/.local` as having the tool installed,
  `npm install -g` into that prefix fails with `ENOTDIR`, and
  `fabrica doctor` fails on a machine whose managed copy is perfectly
  fine. Only a symlink, and only one pointing at a git checkout of that
  tool, is removed - a real directory there, or a link to anything else,
  gets a warning naming it and stays put.

Like everything else in these two steps it never fails a switch - every
outcome is a message and an exit 0. `fabrica doctor` is the hard stop that
refuses to start work when the wrong Inspector would win.

### One key file for every Fabrica and Inkwell job

There is exactly one file on a machine holding the model key that Fabrica's
jobs and Inkwell's backend both need: **`~/.fabrica/brain.env`**. The switch
places it, at mode `600`, on `personal-mac` and `home-linux`
(`modules/managed-key-file.nix`); the key itself goes in by hand, once per
machine, and **never enters this repository, encrypted or not**.

```sh
$EDITOR ~/.fabrica/brain.env   # one KEY=value line per variable, no quotes needed
```

That is the whole of it on a new box - the file is already there and already
private, because `install -m 600 /dev/null` creates it that way and the key
is therefore never written into a file that was briefly readable by other
accounts. Nothing here knows which variables are in it, so the day a job
reads one more of them, nothing in these dotfiles changes.

`~/.inkwell/env` is a **symlink** to that file. It used to be a second,
hand-made copy of the same key (inkwell#46), which meant rotating the key
meant remembering both files; anything that still reaches for the old path -
a backend run by hand, an older note - now reads the one file. What the step
does with a duplicate it finds is deliberately narrow:

- byte-identical to `~/.fabrica/brain.env`: **removed**, and replaced by the
  symlink. The bytes demonstrably survive in the file the link resolves to.
- a key whose canonical file holds nothing (absent, or empty): **moved**
  into `~/.fabrica/brain.env`, which is the migration - overwriting nothing
  loses nothing, and the key is never copied, so it never exists twice.
- two *different* non-empty key files: **neither is touched.** That is a
  question only a human can answer, and the step says so by name with the
  `diff`, the edit and the `rm` that answer it.

A key file it finds readable by other accounts is tightened to `600` and
said out loud on stderr, because a key that has been exposed is worth
knowing about. Like the sync steps, none of this ever fails a switch: the
hard refusal about this file belongs to whatever reads it (for Inkwell's
backend, the `ExecStartPre` below, which will not start it without a usable
key).

### Inkwell's backend on the Mac (`personal-mac`)

The local server the phone posts a captured note to - it writes each one
into `~/inkwell-notes`, a git repository of markdown it creates and commits
to itself - runs on the Mac as a launchd user agent, and there is nothing
to start, nothing to leave a terminal tab open for, and nothing to redo
after a reboot. `modules/inkwell.nix` is all three parts:

- **It runs at login and comes back when it dies.** The agent
  (`RunAtLoad` + `KeepAlive`) runs `~/go/bin/inkwell-backend --addr
  127.0.0.1:8080 --storage-dir ~/inkwell-notes`, with both its streams in
  `~/Library/Logs/inkwell-backend.log`. Loopback only, on purpose: the
  phone comes in through tailscale (below), which proxies to `127.0.0.1` on
  this same machine, and a note server with no authentication of its own
  has no business on the LAN. The agent also gets an explicit `PATH`,
  because the backend shells out to `git` for every write.
- **The binary is kept current by the switch.** On every activation
  `modules/inkwell-sync.sh` reads the tip of `main` from
  `github.com/inactdev/inkwell` with `git ls-remote`, compares it against
  the VCS revision stamped into the installed binary (`go version -m`
  reads it back), and only when they differ builds that commit in a
  throwaway shallow clone and moves the result into place - then restarts
  the agent, because the plist deliberately never changes and so
  home-manager has no reason to. A match costs one network read. Unlike
  Inspector this *builds* rather than `go install`s, and not by choice:
  inkwell's backend declares `module inkwell/backend`, and Go refuses a
  module path with no dot in its first element for any remote install.
  Reading and cloning a private `inkwell` needs this machine's GitHub
  credentials, which `programs.gh`'s credential helper (`modules/core.nix`)
  already supplies - and nothing here ever prompts for one. It never fails
  a switch either: offline, no credentials, a failed build, a `launchctl`
  that refuses - each warns and leaves what is installed and running alone.
- **The phone's address is configured once.** The last step publishes
  `127.0.0.1:8080` on this machine's tailnet address over HTTPS with
  `tailscale serve --bg`, which tailscaled keeps across reboots by itself,
  and only when serve is not already configured: a node already serving
  this port is reported and left alone, and a node serving *something else*
  is never overwritten - it says what it refused to do and the one command
  to do it by hand. Every call runs under a `timeout`, because a tailnet
  that has not enabled HTTPS certificates sends the CLI into a flow that
  waits for a human in the admin console, and an activation has nobody to
  ask.

`~/go/bin/inkwell-backend` needs none of the shadowing guard below: launchd
runs it by absolute path, and nothing resolves `inkwell-backend` by name.

### Inkwell's backend on `home-linux`

The same backend, the same port, the same `~/inkwell-notes`, on the box
that is always on - which is where a server the phone posts to belongs,
since a laptop that is shut answers nothing. `modules/inkwell-linux.nix` is
the Linux counterpart of the module above: a **systemd user service**
instead of a launchd agent, and the same two shared scripts for the two
halves that are genuinely identical on both hosts (the build, and the
tailnet address). Setting a cloud Linux box up as `home-linux` later is
therefore the same switch, with nothing extra to remember.

- **It runs at boot and comes back when it dies.** The service runs
  `~/go/bin/inkwell-backend --addr 127.0.0.1:8080 --storage-dir
  ~/inkwell-notes` with `Restart=always`, a ten-second `RestartSec` and
  systemd's give-up rate limiter switched off, so it is retried for as long
  as it takes rather than going quiet after five tries. Both its streams go
  to the journal: `journalctl --user -u inkwell-backend`. It is wanted by
  `default.target`, and because every `home-linux` switch enables linger
  for this user (`modules/linux.nix`), "boot" rather than "login" is
  literally true - nobody has to be logged in.
- **The key never enters this repository.** The backend reads the one key
  file every Fabrica job reads, `~/.fabrica/brain.env` (see "One key file
  for every Fabrica and Inkwell job" above for what places it and what
  `~/.inkwell/env` is now), and systemd loads it with `EnvironmentFile=` -
  so nothing here holds it, names the variables in it, or has to change
  when the backend reads one more of them. It is also the one thing in this
  area that *refuses* rather than warns: the service's `ExecStartPre` runs
  `modules/inkwell-key-file.sh`, which will not let the backend start when
  that file is missing, empty, owned by somebody else or readable by any
  other account on the machine, and says so by name with the command that
  fixes it. The same check runs during the switch too - after the step that
  places the file, so its message is about an empty file rather than a
  missing one - and so the message arrives where somebody is watching
  instead of only in the journal. On a new box, the whole of what is left
  to do:

  ```sh
  $EDITOR ~/.fabrica/brain.env   # one KEY=value line per variable
  ```

- **The notes can come from somewhere.** With a notes repository to
  continue, set `notesOrigin` in `modules/inkwell-linux.nix` to its URL and
  the switch clones it once, before the backend is ever started - a box
  that already has `~/inkwell-notes` is never touched, cloned over, or
  inspected. Left empty, which is how it ships, the backend opens its own
  repository there exactly as it does on the Mac.
- **The binary is kept current by the switch**, by the same
  `modules/inkwell-sync.sh` the Mac uses, so "what to build and when" has
  one implementation. `modules/inkwell-linux-sync.sh` wraps it and owns the
  half that cannot be shared: it notes which binary is installed, delegates
  the build, and restarts the service only when the binary actually
  changed - the unit text deliberately never changes, so home-manager has
  no reason to restart anything by itself. On the switches that build
  nothing it still makes sure the service is up, which is what brings a
  unit back that failed for want of a key file since placed.
- **The phone's address is configured once**, by the same
  `tailscale serve --bg` step as the Mac - including the same refusal to
  overwrite a node that already serves something else. The app is pointed
  at *this* box's `https://<host>.<tailnet>.ts.net` address.

Two things are deliberately left for a human. The *contents* of the key file
above are one - the file itself is placed by the switch, but no key is.
The other is the Mac: `modules/inkwell.nix` is still composed into
`personal-mac`, because the notes that exist today are there and stopping
that agent would stop serving them - drop that one line from `flake.nix`
once they have been moved over. Removing the Mac's module stops its agent
but leaves its tailnet address published, since tailscaled keeps the serve
configuration itself and nothing in this repository ever takes one away;
`tailscale serve status` on the Mac is what shows whether it still answers.

### Applying itself

`personal-mac` and `home-linux` keep themselves current without anyone
running anything, and without ever asking for a password. Every 30
minutes, and once at login, the OS's own scheduler runs
`home/.local/bin/dotfiles-auto-apply`, which fetches `~/.dotfiles`' origin
and - when `origin/master` has moved ahead of a clean `master` checkout -
fast-forwards to it. A launchd user agent does the scheduling on the Mac
(`modules/mac.nix`), a systemd user timer on Linux
(`modules/linux.nix`), so a cloud Linux box set up as `home-linux` gets
this from its bootstrap with nothing extra to install.

What happens after the fast-forward differs by host, and the job decides
which host it is on by reading `.dotfiles-host` - the same per-clone
marker `./run.sh` itself reads. It never guesses from `uname` or the
hostname: a missing or unrecognized marker stops the run with a log line
naming the file, because a scheduled job must not guess what `./run.sh`
would refuse to guess. (Record it once with `./run.sh choose`.)

- **`personal-mac` announces, and switches nothing.** `./run.sh rebuild`
  ends in `sudo darwin-rebuild switch` there, and a launchd *user* agent
  has no terminal for sudo to prompt at - a scheduled switch could only
  ever fail with *"sudo: a terminal is required to read the password"* and
  retry every half hour. So this host fast-forwards the checkout, raises
  one notification saying an update is ready, and logs the same line,
  including the one command to apply it:
  `cd ~/.dotfiles && ./run.sh rebuild`. The notification fires once per
  new upstream commit, not once per run; the log line is written on every
  run until you apply it, because the log is the record.
- **`home-linux` applies it.** Its switch is a plain user-level
  `home-manager switch` with no sudo anywhere in it, so there is nothing
  to prompt for and nothing to wait on.

Nothing has to be run by hand, but it is also just
`dotfiles-auto-apply` on PATH if you want a run now.

What it will not do:

- **It never needs a password.** The one host whose switch needs root
  doesn't switch here at all, and the switch that does run is wrapped in a
  `sudo` that always carries `-n`, so anything that ever did ask for a
  password fails in milliseconds with a log line that says exactly that
  instead of blocking a job with no terminal.
- **It never touches a dirty checkout.** Any staged or unstaged change,
  and any untracked file git doesn't ignore, stops the run before the
  fast-forward - nothing merged, nothing applied, nothing announced, and
  the log says what is in the way. A `~/.dotfiles` parked on a branch
  other than `master`, or on a detached HEAD, is left alone the same way.
- **It only ever fast-forwards.** A `master` that has genuinely diverged
  from `origin/master` is never merged, rebased or reset; that one
  notifies and exits non-zero, because only you can resolve it.
- **It is never silent about a fetch it couldn't act on.** Uncommitted
  changes, unpushed local commits and a real divergence each log their own
  line and raise one notification per occurrence - once, not once every
  half hour - on both hosts.
- **It never leaves the machine quietly behind.** The commit this machine
  last applied is recorded - by the job itself on `home-linux`, and by
  `./run.sh rebuild` wherever you run it by hand - so a rebuild that
  failed is retried on the next run rather than forgotten once the
  checkout has caught up, and the Mac's reminder goes quiet the moment you
  actually apply the update. That record, not the fetch, is what decides
  an update is outstanding - so a commit made straight on local `master`,
  or a `git pull` nobody applied, is picked up on the next tick too.

Where to look when you want to know what it did:

- `~/.local/state/dotfiles-auto/apply.log` - every run, trimmed to its
  last 2000 lines, including the output of each `./run.sh rebuild`.
- The scheduler's own copy of the same lines:
  `~/Library/Logs/dotfiles-auto-apply.log` on the Mac,
  `journalctl --user -u dotfiles-auto-apply` on Linux.
- A desktop notification, for the outcomes that need you: an update ready
  to apply on the Mac, a checkout that needs a hand, and a failed rebuild.
  The notifier is looked up at runtime (`osascript`, then `notify-send`),
  so a headless box simply logs - nothing fails for want of a notification
  daemon.
- `~/.local/state/dotfiles-auto/` also holds the three small state files
  behind all of that: `last-applied` (the commit this machine applied),
  `last-announced` (the commit it last notified you about) and
  `last-blocked` (the last thing it couldn't act on, so it only tells you
  once). Deleting any of them costs you at most one repeated notification.

The one thing a headless Linux box needs from the machine itself - linger -
is part of the switch, not a step to remember:

- **A systemd *user* timer only runs while that user's systemd instance is
  up.** With linger that instance comes up at boot; without it, only while
  someone is logged in - so an unattended cloud box would stop applying
  anything the moment the last ssh session closed, and say nothing about
  it. Every `home-linux` switch therefore enables linger itself
  (`modules/linux.nix`), so `./run.sh bootstrap home-linux` really is all a
  new box needs.
- **It needs no root and no password.** logind lets an account turn linger
  on for itself, and the account is the username this host is configured
  with - so a switch run through `sudo` still targets the human account,
  never `root`. The call carries `--no-ask-password`, so a machine whose
  policy would demand one fails in milliseconds instead of blocking a
  scheduled run with no terminal, and a user who already has linger is a
  no-op rather than a fresh authorization request every half hour.
- **It is never silently skipped.** A machine that cannot have logind at
  all (systemd isn't the init system, or there is no `loginctl`) has no
  systemd user manager for the timer either; that one prints a warning
  naming the command it skipped and why, and the switch carries on.
  Anything else - logind there, linger off, and the call refused - fails
  the switch and tells you the one command to run as root
  (`sudo loginctl enable-linger <user>`), because a timer that only fires
  while you happen to be logged in is exactly the state nobody notices.

There is deliberately nothing to set up on the Mac - no `/etc/sudoers.d`
rule, no root `launchd.daemons` job. Both were the obvious ways to let the
timer switch the Mac itself; both buy that by widening what runs without a
password, which is exactly what this is meant not to need.

## The work host (`--no-nix`)

Corporate Macs where Nix isn't allowed use the `work` host instead:
`./run.sh bootstrap work --no-nix` installs a smaller, captain-approved
package set with plain Homebrew and wires up configs with plain shell - no
Nix, no home-manager. Everything for that path lives under `work/`:

- `work/Brewfile` - the exact formula/cask list for the work host, and the
  intent Codespaces' work posture mirrors via apt/npm/release binaries
  (below).
- `work/bootstrap.sh` - installs Homebrew if missing, runs `brew bundle`,
  symlinks the same `home/.config/*` and `AGENTS.md` files the Nix path
  uses plus ghostty (no wezterm/herdr - see below), links `work/zshrc` and
  `work/claude-settings.json` into place, configures git (identity is
  prompted for, never defaulted), and applies the macOS `defaults` the Nix
  path also sets. Idempotent - safe to re-run any time, including via
  `./run.sh rebuild` once `work` is the remembered/chosen host. It also
  installs Fabrica and Inspector (see below).
  Everything in it except the Homebrew/`brew bundle` install step, the
  macOS `defaults`, and the Fabrica/Inspector steps is plain shell with
  nothing macOS-specific about it, and is sourced (not copied) by
  `work/codespace-bootstrap.sh` below - see that file's own header comment
  for exactly which functions are shared.
- `work/zshrc` - the real `~/.zshrc` for *both* the work Mac and
  Codespaces' work posture: it self-detects Homebrew vs. apt at runtime
  (`command -v brew`) rather than existing as two files that would need
  to be kept in sync by hand. Never linked on the personal Mac, which
  gets its zshrc generated by home-manager instead.
- `work/claude-settings.json` - a work variant of `home/.claude/settings.json`,
  shared by the work Mac and Codespaces' work posture alike.
  Re-derive it after editing the source file with:
  `jq 'del(.hooks, .skipDangerousModePermissionPrompt)' home/.claude/settings.json > work/claude-settings.json`,
  then reapply the two standing work overrides below - the `jq` command
  alone reproduces the home file's `model`/`effortLevel`, which is *not*
  what we want at work:
  - `hooks` and `skipDangerousModePermissionPrompt` are stripped (those
    hooks point at a home-machine path and call tools not installed at
    work).
  - `model` is pinned to `"opus"` and `effortLevel` to `"xhigh"` -
    captain decision: Opus at extra-high effort is the standing default
    at work, deliberately diverging from home's default model. Treat
    this divergence as intentional, not drift, when comparing the two
    files.

### Fabrica and Inspector on the work Mac

The work host gets the same floor under both tools that
`modules/fabrica.nix` and `modules/inspector.nix` give `personal-mac` and
`home-linux` - every `./run.sh bootstrap work --no-nix` and every
`./run.sh rebuild` on this host installs the current Fabrica and the
current Inspector. `node` and `go` come from `work/Brewfile`, which
already lists both.

- **Fabrica** is installed the three-step way its own README prescribes:
  `git clone --depth 1 --branch master` of
  `github.com/inactdev/fabrica` into a temporary directory, `npm pack`
  inside that clone, then `npm install -g` of the tarball that produced.
  Never `npm install -g github:inactdev/fabrica`, and never `npm pack` of
  that spec either - the reasons are the same ones spelled out under
  "Fabrica" above for the Nix hosts, and the symptom of either shortcut is
  `fabrica doctor` refusing to start work. The clone and the tarball are
  removed whichever way the install goes.
- **Inspector** is installed with the one command its own documentation
  gives: `go install github.com/inactdev/inspector/cmd/inspector@latest`.
- **Both land under `~/.local`** (`~/.local/bin/fabrica`,
  `~/.local/bin/inspector`), which `work/zshrc` already exports on PATH -
  not in npm's own global prefix and not in Go's default `~/go/bin`, which
  this host does not put on PATH at all. One directory, no sudo, nothing
  that depends on a writable Homebrew prefix.
- **Neither failure is fatal.** Fabrica's repository is private, so a
  machine whose `gh auth login` is still pending cannot clone it at all;
  that warns, lands in the closing summary as "Fabrica: not installed",
  and leaves the rest of the bootstrap - which has already linked every
  config and installed every package - alone. Same for any `go install`
  failure. Both steps run *after* the git/`gh auth setup-git` step for
  exactly that reason.

Unlike the Nix hosts, there is no `git ls-remote` comparison first: a
home-manager activation runs on its own schedule and must not cost a clone
every time, whereas a work-host bootstrap or rebuild is a command someone
ran on purpose. So these simply install the current version every time,
which is what "idempotent" has to mean for a step whose job is "be
current".

Codespaces' work posture is deliberately left out of this, exactly as both
codespace hosts are left out of `modules/fabrica.nix`/`modules/inspector.nix`:
a container is a place work gets done, not a place it gets dispatched from
or checked.

Deliberately excluded from the work host, by captain decision:
wezterm, herdr, opensuperwhisper, ollama, cloudflared, arp-scan,
imagemagick, graphviz, tree-sitter, cmake, make, watchman, fzf, nixfmt.

The bootstrap ends with a short summary of anything it couldn't finish
(GitHub login, MDM-locked macOS settings, a still-unset git identity, a
Fabrica or Inspector install that didn't land).

## GitHub Codespaces

Codespaces never goes through `run.sh`: GitHub auto-clones this repo and
runs `install.sh` at container creation, fully non-interactively (it
requires `CODESPACES=true`). Posture (personal vs. work) is picked
structurally, by comparing the codespace's workspace repo owner
(`$GITHUB_REPOSITORY`) against this repo's own `git remote get-url origin`
owner - same owner is personal, anything else (including undeterminable)
gets the locked-down work default. **The two postures now install
genuinely differently, not just a different settings file:**

- **Personal posture** installs Nix (the Determinate installer's
  container-safe `--init none` mode, since a running codespace container
  has no init system to hand the daemon to - see the comments in
  `install.sh`), starts `nix-daemon` itself, then applies `flake.nix`'s
  `homeConfigurations."codespace-personal"` - the same `modules/core.nix`
  package set as `personal-mac`/`home-linux`, plus `modules/codespace.nix`.
  Ghostty, fonts, git identity, herdr, and the local-machine Claude
  settings are all structurally absent, simply because Codespaces never
  imports `modules/desktop.nix`/`modules/mac.nix`. Unchanged by the work
  -posture change below.
- **Work posture never installs Nix at all** - the captain opens
  codespaces on employer repositories, and Nix has no place there.
  `install.sh` instead delegates straight to `work/codespace-bootstrap.sh`,
  the same no-Nix approach as the work Mac (`work/bootstrap.sh`) but
  targeting apt instead of Homebrew: every `work/Brewfile` entry is
  translated to the Codespaces universal image's own package manager
  (apt) first, a language package manager already on the image (npm, for
  Claude Code and `prettierd`) second, and a direct download of an
  official release binary only when neither covers a modern-enough
  version (neovim, StyLua, ruff, starship) - see that file's own header
  comment for the full mapping and rationale. Every install step checks
  `command -v`/`dpkg -s` first, so anything the universal image already
  ships is left alone rather than reinstalled. Nothing on this path
  clones a repository, including neovim's own plugin manager: the nvim
  config is symlinked (same as the Mac work host), but its plugins are
  not pre-synced, matching `work/bootstrap.sh`'s existing Mac behavior -
  opening nvim for the first time will have its bundled Lazy.nvim
  bootstrap itself via git the same way it already does on the Mac work
  host today; that's an existing property of the shared nvim config, not
  something either bootstrap script does itself. macOS-only `Brewfile`
  entries (ghostty, docker-desktop, the nerd font cask) have no codespace
  equivalent and are simply not installed. The bootstrap ends with a
  summary of what it installed, what it deliberately skipped, and
  anything that still needs attention (a failed download, an unset git
  identity) - same `*_PENDING`-counter pattern as `work/bootstrap.sh`.

Once posture is known, the Claude settings file and the `cc` alias still
vary by hand, same as before:

- Which Claude settings file `~/.claude/settings.json` links to -
  `codespaces/claude-settings.json` for personal (`home/.claude/settings.json`
  with just the axi-tool hooks stripped, since those tools aren't installed
  in a codespace either way - it does not carry the work host's opus/xhigh
  override) or `work/claude-settings.json` (the same file the work Mac
  uses) for work. Personal posture wires this through `modules/codespace.nix`;
  work posture through `work/codespace-bootstrap.sh` (which reuses
  `work/bootstrap.sh`'s `install_claude_settings` directly).
- The `cc` alias - `claude --dangerously-skip-permissions` for personal,
  matching `personal-mac`/`home-linux`; plain `claude` for work, set in
  the shared `work/zshrc`.

To use this on a new GitHub project: point that project's Codespaces
settings at this dotfiles repo as its dotfiles repository (GitHub Settings
→ Codespaces → "Automatically install dotfiles"), and every codespace
opened for it will clone this repo and run `install.sh` on creation.

## Tests

- `bash run.test.sh` - host selection logic in `run.sh` against a mocked `uname`, its `~/.dotfiles` symlink guards (`validate_dir`, `link_dotfiles`) against a scratch `$HOME`, and that a successful rebuild records the commit it applied where the self-update job reads it.
- `sh work/bootstrap.test.sh` - the work Mac's install/link/configure steps, against mocked `brew`/`defaults`/`killall`/`gh`/`npm`/`go` on a hermetic `$HOME`, plus a `git` that is real for everything except `clone` (so the Fabrica install's clone of a private repository is exercised without ever reaching the network). Covers the clone/pack/`npm install -g` chain, the `go install ...@latest` command and the environment it runs under, the fact that npm is never handed a `github:` spec, and that a refused clone, a failing `npm` or a failing `go` each warn, report themselves in the summary, clean up their temp directory and still leave the bootstrap exiting 0.
- `bash work/codespace-bootstrap.test.sh` - the Codespaces work-posture install steps, against mocked `apt-get`/`dpkg`/`sudo`/`curl`/`npm`/`gh` on a hermetic `$HOME`; also asserts the functions it shares with `work/bootstrap.sh` are the exact same function objects (via `source`), not a hand-kept-in-sync copy.
- `bash home/.local/bin/dotfiles-auto-apply.test.sh` - the self-update job: the `.dotfiles-host` split (`personal-mac` announces and never switches, `home-linux` applies, anything else refuses before it even fetches), one notification per new upstream commit and per blocked occurrence, the sudo guard (any `sudo` the switch reaches runs with `-n`, and a password prompt is called out in the log rather than left raw), plus fast-forward, dirty checkout, divergence, fetch and rebuild failures, the retry record, log trimming and notifier lookup - against a mocked `git`, a mocked `./run.sh`, a mocked `sudo` and mocked notifiers on a hermetic PATH and a scratch `$HOME`. It never reaches a real remote, a real `~/.dotfiles`, or a real switch.
- `bash modules/inkwell-sync.test.sh` - the Inkwell backend's build and agent decisions: already-current costs no build, a stale/unstamped/dirty-tree binary is rebuilt, a rebuild restarts the agent while an unchanged one only gets started if it isn't running, an agent that isn't loaded is bootstrapped, and no network, no clone, no build or a refusing `launchctl` each warn and leave what is installed and running alone - against a mocked `git`/`go`/`launchctl` on a hermetic PATH, with `$HOME`, the Go bin directory and `$TMPDIR` all under one scratch directory. It never clones, compiles, or speaks to a real launchd.
- `bash modules/inkwell-key-file.test.sh` - the one definition of a usable key file for Inkwell's backend, which the `home-linux` service runs before every start and the switch runs once: a 0600 (or 0400) non-empty file is accepted silently, and a missing one, an empty one, a directory, a group- or world-readable one, one owned by another account, or one whose mode could not be read at all is refused by name with the command that fixes it. Mode and owner are read through a symlink, because that is the file systemd's `EnvironmentFile=` will read. It needs nothing but a scratch directory, and never reads a real `~/.inkwell/env`.
- `bash modules/inkwell-linux-sync.test.sh` - the `home-linux` service's half of the Inkwell step: the build is delegated with no launchd label, a rebuilt binary restarts the unit while an unchanged one is only started if it isn't already running, a `failed` unit is started again, no binary means nothing is started, and no `systemctl`, no systemd user session, a failed build, a missing build script or a refused restart each warn and leave what is running alone - against a mocked `systemctl` and a stand-in build script on a hermetic PATH, with `$HOME` and the Go bin directory under one scratch directory. It never speaks to a real systemd.
- `bash modules/inkwell-tailscale-serve.test.sh` - the serve step: an unconfigured node is published, a node already serving that port is left alone, a node serving something else is never overwritten, a port that merely starts with the same digits is not that port, and an unreachable daemon or a refused publish is a warning rather than a failed switch - against a mocked `tailscale` and a `timeout` wrapper that records the bound it was given. It never touches a real tailnet.
- `bash modules/managed-key-file.test.sh` - the one-key-file step: a machine that has never had one gets an empty mode-600 `~/.fabrica/brain.env` and a symlink at the old `~/.inkwell/env`, every switch after that is silent, a key file readable by other accounts is tightened and said out loud, a `0400` one is left read-only, a byte-identical duplicate is removed and a duplicate whose canonical file holds nothing is *moved* in - while two different non-empty key files, a directory in the way, a canonical path that is itself a symlink (which linking to would be a loop), and a link pointing at somebody else's key are each refused with both files left exactly as they were. It needs nothing but a scratch directory, and never reads or writes a real key file.
- `bash install.test.sh` - the Codespaces posture-detection logic, `main`'s personal/work dispatch (including a direct proof that the work branch never calls any Nix function), and legacy-symlink backup logic in `install.sh`, hermetic (no Nix/apt/network).
- `bash install.container-test.sh` - the real Codespaces install inside a disposable `ubuntu:24.04` container: Nix + the `codespace-personal` home-manager profile for personal posture, `work/codespace-bootstrap.sh`'s apt/npm/binary installs for work posture. Runs work posture *before* personal so the "Nix is never installed on this path" proof isn't confounded by Nix's own system-wide profile scripts, which personal's install would otherwise leave behind for every user in the container. Also asserts nothing under the work user's `$HOME` was git-cloned, and that a second work-posture run is idempotent. A section at the tail is not about `install.sh` at all: it does a real `home-manager switch` of the `ci-linux` host as a throwaway container user, the only place the activation steps in `modules/fabrica.nix`, `modules/inspector.nix`, `modules/linux.nix`, `modules/managed-key-file.nix` and `modules/inkwell-linux.nix` actually run - including the linger step, and the key-file step, whose empty mode-600 file and `~/.inkwell/env` symlink are asserted on the real activation rather than only against a scratch directory, which is asserted against what logind reports where logind exists, and against its own skipped-and-why warning where it doesn't. It is also the only place that proves the Fabrica the step installs carries the commit it was built from (which needs a real clone to read it out of) and that the shadowing guard clears a leftover `npm link` symlink seeded in the way, without touching the checkout it points at. Requires Docker; also wired to run in CI on every push/PR touching the Nix config or either install path (`.github/workflows/install-container-test.yml`).

None of these touch this machine's real Homebrew, apt packages, macOS defaults, `~/.claude`, or `~/.dotfiles` - see `AGENTS.md` for why each is written that way and how to verify `work/bootstrap.sh` for real, in a container.

The hermetic suites (everything above except the container test), plus shellcheck, `nixfmt --check`, and an eval-only `nix eval` of each host config, also run on every PR via `.github/workflows/ci-floor.yml`.
