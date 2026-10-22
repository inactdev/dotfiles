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
  them: move them aside once, or pass `-b hm-backup` to the switch.
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
- `modules/mac.nix` - the herdr config symlink, and the launchd agent that
  drives the self-apply job below. `personal-mac` only (herdr is a
  Homebrew cask, and launchd doesn't exist elsewhere).
- `modules/linux.nix` - the systemd user timer that drives the same
  self-apply job. `home-linux` only; Codespaces does not import it (a
  container is applied once at creation and then thrown away).
- `modules/codespace.nix` - the Codespaces-only delta (Claude Code itself,
  since there's no Homebrew cask to lean on; which Claude settings file;
  the `cc` alias) - see the Codespaces section below.

`flake.nix` defines `darwinConfigurations.personal-mac` and
`homeConfigurations.home-linux`/`.codespace-personal`/`.codespace-work` by
composing these module files per host (`personal-mac` =
core+desktop+fabrica+inspector+mac, `home-linux` =
core+desktop+fabrica+inspector+linux, each codespace posture =
core+codespace).
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

The install itself is `npm pack github:inactdev/fabrica` followed by
`npm install -g` of the tarball that produced, rather than one
`npm install -g github:inactdev/fabrica`. The one-step form cannot work:
npm installs a git spec globally by symlinking the prefix at its own
temporary clone and then deleting the clone, so Fabrica's build step is
left running in a directory that no longer exists. Packing first runs
that build step where it is safe to, and the tarball installs like any
other package.

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

Like everything else in these two steps it never fails a switch - every
outcome is a message and an exit 0. `fabrica doctor` is the hard stop that
refuses to start work when the wrong Inspector would win.

### Applying itself

`personal-mac` and `home-linux` keep themselves applied without anyone
running anything. Every 30 minutes, and once at login, the OS's own
scheduler runs `home/.local/bin/dotfiles-auto-apply`, which fetches
`~/.dotfiles`' origin and - when `origin/master` has moved ahead of a
clean `master` checkout - fast-forwards to it and applies the result with
`./run.sh rebuild`. A launchd user agent does the scheduling on the Mac
(`modules/mac.nix`), a systemd user timer on Linux
(`modules/linux.nix`), so a cloud Linux box set up as `home-linux` gets
this from its bootstrap with nothing extra to install.

Nothing has to be run by hand, but it is also just
`dotfiles-auto-apply` on PATH if you want a run now.

What it will not do:

- **It never touches a dirty checkout.** Any staged or unstaged change,
  and any untracked file git doesn't ignore, stops the run before the
  fast-forward - nothing merged, nothing applied, and the log says what is
  in the way. A `~/.dotfiles` parked on a branch other than `master`, or
  on a detached HEAD, is left alone the same way.
- **It only ever fast-forwards.** A `master` that has genuinely diverged
  from `origin/master` is never merged, rebased or reset; that one
  notifies and exits non-zero, because only you can resolve it. Local
  commits you haven't pushed yet are an ordinary state and stay quiet.
- **It never leaves the machine quietly behind.** The commit of the last
  successful rebuild is recorded, so a rebuild that failed is retried on
  the next run rather than forgotten once the checkout has caught up. That
  record, not the fetch, is what decides a rebuild is due - so a commit
  made straight on local `master`, or a `git pull` nobody applied, gets
  applied on the next tick too.

Where to look when you want to know what it did:

- `~/.local/state/dotfiles-auto/apply.log` - every run, trimmed to its
  last 2000 lines, including the output of each `./run.sh rebuild`.
- The scheduler's own copy of the same lines:
  `~/Library/Logs/dotfiles-auto-apply.log` on the Mac,
  `journalctl --user -u dotfiles-auto-apply` on Linux.
- A desktop notification, for the two outcomes that need you: a failed
  rebuild, and a real divergence. The notifier is looked up at runtime
  (`osascript`, then `notify-send`), so a headless box simply logs -
  nothing fails for want of a notification daemon.

Two things it needs from the machine itself, which Nix can't declare:

- **On `personal-mac`, passwordless sudo for `darwin-rebuild`.**
  `./run.sh rebuild` ends in `sudo darwin-rebuild switch` there, and a
  launchd user agent has no terminal for sudo to prompt at. Until a
  `/etc/sudoers.d` rule lets that one command run without a password,
  every run that finds new commits will fast-forward, fail the rebuild,
  and notify - visibly, and retried, but not applied. `home-linux` needs
  nothing: its rebuild is a plain user-level `home-manager switch`.
- **On a headless Linux box, `loginctl enable-linger <user>` once, as
  root.** A systemd *user* timer only runs while that user's systemd
  instance is up; with linger it comes up at boot, without it only while
  someone is logged in.

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
  `./run.sh rebuild` once `work` is the remembered/chosen host.
  Everything in it except the Homebrew/`brew bundle` install step and the
  macOS `defaults` is plain shell with nothing macOS-specific about it,
  and is sourced (not copied) by `work/codespace-bootstrap.sh` below - see
  that file's own header comment for exactly which functions are shared.
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

Deliberately excluded from the work host, by captain decision:
wezterm, herdr, opensuperwhisper, ollama, cloudflared, arp-scan,
imagemagick, graphviz, tree-sitter, cmake, make, watchman, fzf, nixfmt.

The bootstrap ends with a short summary of anything it couldn't finish
(GitHub login, MDM-locked macOS settings, a still-unset git identity).

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

- `bash run.test.sh` - host selection logic in `run.sh` against a mocked `uname`, plus its `~/.dotfiles` symlink guards (`validate_dir`, `link_dotfiles`) against a scratch `$HOME`.
- `sh work/bootstrap.test.sh` - the work Mac's install/link/configure steps, against mocked `brew`/`defaults`/`killall`/`gh` on a hermetic `$HOME`.
- `bash work/codespace-bootstrap.test.sh` - the Codespaces work-posture install steps, against mocked `apt-get`/`dpkg`/`sudo`/`curl`/`npm`/`gh` on a hermetic `$HOME`; also asserts the functions it shares with `work/bootstrap.sh` are the exact same function objects (via `source`), not a hand-kept-in-sync copy.
- `bash home/.local/bin/dotfiles-auto-apply.test.sh` - the self-apply job (fast-forward, dirty checkout, divergence, fetch and rebuild failures, the retry record, log trimming, notifier lookup), against a mocked `git`, a mocked `./run.sh` and mocked notifiers on a hermetic PATH and a scratch `$HOME` - it never reaches a real remote, a real `~/.dotfiles`, or a real switch.
- `bash install.test.sh` - the Codespaces posture-detection logic, `main`'s personal/work dispatch (including a direct proof that the work branch never calls any Nix function), and legacy-symlink backup logic in `install.sh`, hermetic (no Nix/apt/network).
- `bash install.container-test.sh` - the real Codespaces install inside a disposable `ubuntu:24.04` container: Nix + the `codespace-personal` home-manager profile for personal posture, `work/codespace-bootstrap.sh`'s apt/npm/binary installs for work posture. Runs work posture *before* personal so the "Nix is never installed on this path" proof isn't confounded by Nix's own system-wide profile scripts, which personal's install would otherwise leave behind for every user in the container. Also asserts nothing under the work user's `$HOME` was git-cloned, and that a second work-posture run is idempotent. Requires Docker; also wired to run in CI on every push/PR touching the Nix config or either install path (`.github/workflows/install-container-test.yml`).

None of these touch this machine's real Homebrew, apt packages, macOS defaults, `~/.claude`, or `~/.dotfiles` - see `AGENTS.md` for why each is written that way and how to verify `work/bootstrap.sh` for real, in a container.

The five hermetic suites (everything above except the container test), plus shellcheck, `nixfmt --check`, and an eval-only `nix eval` of each host config, also run on every PR via `.github/workflows/ci-floor.yml`.
