# Running Inkwell's backend as a launchd user agent on personal-mac

`modules/inkwell.nix` + `modules/inkwell-sync.sh` +
`modules/inkwell-tailscale-serve.sh`. What is worth keeping from building it,
in rough order of how much time each fact saves the next person.

## `go install` cannot install inkwell's backend, at all

The backend declares `module inkwell/backend`. A module path whose first
element has no dot in it is not a remote module path, and Go refuses it
outright:

```
go: inkwell/backend@<commit>: malformed module path "inkwell/backend":
missing dot in first path element
```

So the Inspector/Fabrica shape (`go install <pkg>@<commit>`, see
`modules/inspector-sync.sh`) is unavailable here no matter how the
repository is published, and that is not a preference to revisit - it is a
property of the module path. Changing it would mean renaming the module in
the inkwell repository to `github.com/inactdev/inkwell/backend`, which is
that repository's call, not this one's.

What replaces it: a throwaway `git clone --depth 1 --branch main` into
`mktemp -d`, `go build` inside it, and a rename into `~/go/bin`. Nothing is
lost - the module is standard-library only, so the build fetches no
dependencies.

**And the provenance survives, without a state file.** `go build` stamps
the checkout's VCS data into the binary (`-buildvcs`, `auto` by default;
asked for explicitly so a build that cannot read it fails loudly instead of
producing an unidentifiable binary that gets rebuilt on every switch
forever). `go version -m <bin>` prints it back:

```
build	vcs.revision=e0957234b08fd417f139ba36066869ec3005a036
build	vcs.modified=false
```

That is a full 40-character commit, so the comparison against `git
ls-remote` is exact - better than Inspector's pseudo-version prefix match,
and with no `last-install` fallback needed. Two details that were verified
rather than assumed: the stamp works for a module in a *subdirectory* of
the repository (the module root need not be the VCS root), and it works in
a `--depth 1` clone. `vcs.modified` is read too, because a binary built
from somebody's dirty worktree reports the commit it sat on, which is not
the same as being that commit.

One thing left at Go's default on purpose: `GOTOOLCHAIN`. `backend/go.mod`
names a `go` line (`go 1.26.5` when this was written), and when the store's
`pkgs.go` is older than that line, the default `GOTOOLCHAIN=auto` downloads
the newer toolchain rather than failing - so the backend keeps building
across a nixpkgs pin that lags the inkwell repository. The cost is that such
a build needs the module proxy, and a machine that cannot reach it gets the
step's ordinary "not updated" warning and keeps the binary it has.
`GOTOOLCHAIN=local` would trade a working backend for a faster failure,
which is the wrong way round here.

## home-manager does not restart an agent whose plist did not change

`home-manager/modules/launchd/default.nix` skips any agent whose plist is
byte-identical to the installed one (`cmp -s`, then `return 0`). Both halves
of that matter here:

- the plist must name a **fixed** path (`~/go/bin/inkwell-backend`), never a
  store path, or every generation would boot the backend out and back in -
  the same rule `notes/20261021-dotfiles-auto-apply.md` established for the
  self-apply job, for a different reason;
- therefore a *rebuilt binary behind an unchanged plist restarts nothing*.
  Whatever rebuilds has to restart it. `modules/inkwell-sync.sh` ends by
  doing exactly that, on every path through it:
  `launchctl kickstart -k gui/<uid>/<label>` after a build, a plain
  `kickstart` when the job is loaded but has no pid in `launchctl print`,
  and `launchctl bootstrap gui/<uid> <plist>` when it is not loaded at all.

**`setupLaunchAgents` is `entryAfter [ "writeBoundary" ]`, not after
`linkGeneration`.** The two are siblings, so their relative order is
unspecified - an activation step that touches an agent must therefore name
`setupLaunchAgents` in its own `entryAfter` or it may run before the plist
exists. Related and useful: **a name in `entryAfter` that no entry matches
is harmless.** home-manager's DAG sorts with `lib.toposort` over
`before a b = elem a.name b.after`, so an unmatched dependency simply never
constrains anything - there is no error, which is what makes naming a
Darwin-only entry safe in a module that might one day be composed elsewhere.

**Why `gui/$(id -u)` is the right domain from an activation step.**
`darwin-rebuild switch` runs as root, but home-manager's nix-darwin module
runs each user's activation as
`launchctl asuser "$(id -u <user>)" sudo -u <user> --set-home ...` - so the
step is already inside that user's GUI bootstrap context, with their `HOME`,
and `id -u` is theirs rather than root's. That is also why home-manager's
own agent handling can simply say `gui/$UID`.

**First switch on a fresh machine:** the agent is bootstrapped before the
binary exists, so launchd fails to spawn it and retries on its 10-second
throttle until the sync step (ordered after) builds the binary and starts
it. That is the designed path, not a failure.

## The macOS Tailscale CLI is the GUI binary, and guesses which it is

`/Applications/Tailscale.app/Contents/MacOS/Tailscale` is one binary that
decides whether to be the app or the CLI by sniffing `SHLVL`, `TERM`,
`TERM_PROGRAM` and `PS1`. An activation step has none of those, so the call
can **open the GUI** and never answer. `TAILSCALE_BE_CLI=1` is Tailscale's
own documented way for a script to insist on the CLI, and is harmless for
the standalone `/usr/local/bin/tailscale` launcher and the open-source
binary. Set it in anything non-interactive that shells out to tailscale on a
Mac. (This repo has no `tailscale` formula and will not get one - see
`notes/20261017-tailscale-app-cask.md` - so the app bundle's binary is the
CLI on `personal-mac`.)

## `tailscale serve` facts the step depends on

- `tailscale serve --bg <port>` is **not a daemon**. It writes a proxy into
  tailscaled's serve configuration and returns; tailscaled restores it after
  a reboot or a `tailscale down`/`up`. There is nothing to keep running, and
  nothing to re-run after a reboot. A *foreground* serve is the opposite: it
  lives only as long as the process, and appears in the configuration under
  `Foreground`.
- `tailscale serve status --json` prints the serve configuration, or
  literally `null` when there is none. The text form prints
  `No serve config`. The JSON shape is documented as subject to change,
  which is why the step only asks it one question - does any `"Proxy"` value
  end in this port - as text, and needs no `jq` on the activation PATH.
- **`tailscale serve` can block forever.** With HTTPS certificates not yet
  enabled for the tailnet, the CLI enters `enableFeatureInteractive`, prints
  a URL, and then *waits for a human* to finish in the admin console
  (`ShouldWait`). In an activation with no terminal that hangs the switch
  indefinitely. Every call from this repo therefore runs under `timeout`.
- `tailscale serve --bg 8080` with no type flags means HTTPS on 443, and the
  port shorthand expands to `http://127.0.0.1:8080` - so it mounts a proxy
  at `/` and **replaces** whatever was mounted there. That is the reason the
  step refuses to act when the node already serves something else, rather
  than treating the command as idempotent.

## The backend needs `git` at runtime

It shells out to the system `git` binary for every write (`git init`, `git
add`, `git commit` in its storage directory - `backend/store.go`). A launchd
agent inherits almost nothing, so the plist carries an explicit `PATH`; an
agent without a git on it would start, accept a request, and fail it.
`--storage-dir` is created and `git init`ed by the backend itself, so
nothing in this repository pre-creates `~/inkwell-notes`.

## Sharp edge in the test suites, worth copying

A suite that points `TMPDIR` at a scratch directory must `unset TMPDIR`
before the *next* test's `mktemp -d`: the previous test's teardown has
removed that directory, `mktemp` honours `TMPDIR` anyway, and the failure
mode is a cascade of unrelated-looking errors from an empty `$TMP`.
