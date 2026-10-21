# Inspector via home-manager activation: what Go hands you for free

`modules/inspector.nix` + `modules/inspector-sync.sh` install Inspector on
`personal-mac`/`home-linux` and keep it level with `origin/main`, running
`go install github.com/inactdev/inspector/cmd/inspector@<tip>` only when
the installed binary disagrees with the tip. It is deliberately the same
shape as the Fabrica pair next to it
(`notes/20261018-fabrica-home-manager-install.md`), but the interesting
half - working out what is installed - is much simpler, and a couple of
things about the Go side are worth writing down.

**Go records the version; npm does not.** The whole reason
`fabrica-sync.sh` needs build-info parsing plus a state file is that npm
keeps no trace of the commit a global git install came from. `go install
<pkg>@<commit>` has no such gap: it resolves the commit to a module
version, bakes it into the binary's build info, and `go version -m`
prints it back on the `mod` line. Verified against the real repository -
`go install …@4f297d8be50e4f5b…` produces a binary reporting
`mod github.com/inactdev/inspector v0.0.0-20261020120900-4f297d8be50e`.
All three pseudo-version forms end in `-<12 hex characters>`, the first 12
of the commit, so the comparison against a 40-character `ls-remote` sha is
a prefix test and needs nothing on disk to remember.

**Exactly 12 hex characters, not 7-40.** A pseudo-version's own timestamp
field (`20261020120900`) is all hex characters too, so a Fabrica-style
`[0-9a-f]{7,40}` test would happily read the timestamp of a
`v0.0.0-20261020120900` as a commit. Pinning the length to 12 is what
keeps "is this a pseudo-version" and "what is its revision" the same
question.

**The one recorded value, and why it is not the Fabrica state file.**
inspector has no tags today (`git ls-remote --tags` is empty), but if one
were ever pushed onto the commit this step installs, `go install
<pkg>@<commit>` would resolve it to that tag (`v1.2.0`) rather than to a
pseudo-version - a version string that matches no sha, so the step would
reinstall on every switch forever. So after each install it records
`<module version> <commit>` under
`$XDG_STATE_HOME/inspector-sync/last-install`, and consults it *only*
when the installed version carries no commit of its own. Recording the
version next to the commit is what keeps the record honest: it vouches
for one exact binary, so an Inspector someone later installs by hand
reads as a different version string, falls through, and gets brought back
to the tip rather than being waved past by a stale record.

**`GOPRIVATE=github.com/inactdev/*` on the install, not GOPROXY
guesswork.** Go's default route is the public module proxy plus the public
checksum database, which `go help private` describes as working "well for
publicly available source code" and names GOPRIVATE as the switch for
modules that are "not available publicly" and "should therefore not use
the proxy or checksum database". That is this case if inspector is ever
private, and the setting costs nothing when it is public: the fetch goes
straight to the repository over TLS, which is the same transport the
commit being installed was just read over, and dependencies - which the
pattern does not match - still go through the proxy and are still
checksum-verified. Verified end-to-end against the real repository: fresh
install, no-op second run, behind-the-tip reinstall, and the
unreachable-remote warning.

**`pipefail` and a binary that is not a Go binary.** `go version -m` exits
non-zero on a file it does not recognise, which is exactly the case that
should read as "nothing usable is installed" - but as the first stage of a
pipeline inside a command substitution, under `set -euo pipefail`, it
takes the script down instead. Found while exercising that scenario; the
read is now its own step with `|| return 0`. `fabrica-sync.sh` guards both
of its equivalents already (`|| found=`), and no other `set -e` +
`pipefail` script in the repository has an unguarded instance.

**Why `~/go/bin` rather than a dedicated directory.** The Fabrica module
has to own `~/.npm-global` because npm's default global prefix on a Nix
host is the read-only `nodejs` store path. Go has no such problem:
`$GOPATH/bin` is writable, is where anything else the captain `go
install`s already lands, and sharing `~/go` keeps one module and build
cache. `GOBIN` is still passed explicitly on the install, so a `go env -w
GOBIN=…` set for some other reason cannot move the binary out from under
the PATH entry the module adds. One consequence to know:
`modules/core.nix` puts `~/.local/bin` *ahead* of `home.sessionPath`'s
entries, so an `inspector` dropped there by hand would shadow the managed
one - `which inspector` answers it.

**Not in the lint or test lists.** Same gap as Fabrica's script, for the
same reason: `check.sh`, `.github/**` and `*.test.sh` are protected paths
here, so adding `modules/inspector-sync.sh` to the shellcheck lists and
committing a suite for it has to come from a captain-side pull request.
The behaviour was exercised from a throwaway harness outside the
repository instead (39 assertions over mocked `git`/`go`: the unreachable,
empty and malformed `ls-remote` cases, fresh install, up-to-date, behind,
unreadable binary, the three tagged-version cases, a failing `go install`,
an unwritable state directory, a missing argument, and `XDG_STATE_HOME`).
