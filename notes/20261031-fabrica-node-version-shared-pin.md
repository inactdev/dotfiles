# One Node pin for Fabrica, read by the work host and the Nix hosts alike

`./fabrica-node-version` at the repository root is the single declaration of
the Node version Fabrica runs on - one line, no comments, no syntax, so a
shell can `tr -d '[:space:]' <` it and Nix can `builtins.readFile` it with
no parser on either side. Both readers are load-time, not run-time:
`work/bootstrap.sh` reads it in its top-level assignments, and
`modules/fabrica.nix` reads it in its `let` and interpolates the value into
the activation command line it hands `modules/fabrica-sync.sh`.

That Nix side is deliberate rather than incidental. Had the sync script read
the file itself, the pinned version would not appear anywhere in the
generation's derivation, so bumping the file would produce a byte-identical
activation script and a switch would have nothing to notice. Reading it in
Nix makes a bump change the derivation, which is what makes "bump the file,
then switch" a complete instruction.

One consequence of reading the pin at load time: `work/bootstrap.sh` now
`exit 1`s when the file is absent, and `work/codespace-bootstrap.sh`
*sources* that file, so a checkout without the pin fails the whole
codespace-work install rather than quietly installing an unpinned Fabrica.
That is the right trade, but it sharpens `install.container-test.sh`'s own
caveat: it seeds the container with `git bundle create ... HEAD`, so a new
or edited pin that has not been committed is not in the container, and the
work-posture section fails at the point it sources the bootstrap - not
somewhere in the Nix section where you would go looking for a pin problem.

## Why `fnm exec --using` on the Nix hosts too, rather than a store `node`

The obvious Nix answer - point the launcher at a `nodejs` derivation from
nixpkgs - was rejected, and not on taste:

- nixpkgs' pinned Node is whatever `flake.lock` happens to carry, which is
  not 24.18.0 and would move on every lock update. The whole point of the
  pin is that all hosts run the *identical* Node, and a Nix-side version
  that drifts independently defeats it while looking like it does not.
- it would make the two hosts' launchers differ in mechanism, so a bug
  found and fixed in one would still be standing in the other.

`fnm` is already in `modules/core.nix`'s package set on every Nix host, and
`fnm exec --using=<version>` is the command `work/bootstrap.sh` has already
proved out, so both hosts now end in the same line. `modules/fabrica.nix`
adds `pkgs.fnm` to the activation PATH for it. Neither side sets `FNM_DIR`,
which is what makes the activation's `fnm install` and a login shell's
`fnm env` agree about where the download went.

`fnm exec` has **no** `--install-if-missing` - that flag is on `fnm use`
only (fnm `docs/commands.md`) - so an explicit `fnm install` step is
required, gated on `fnm exec --using=<v> node --version` as the probe. The
probe is that command rather than a grep of `fnm list` so what is checked is
exactly the command line the launcher ends in.

## The two things the Nix side needs that a bootstrap does not

**The launcher has to be re-derivable with no npm shim to ask.**
`work/bootstrap.sh` installs Fabrica on every run, so npm's freshly linked
shim - the authority on where the installed package put its entry point - is
always there to resolve. `modules/fabrica-sync.sh` installs only when the
commit moved, so most activations have no shim, and the one that bumps
`./fabrica-node-version` while Fabrica's own commit has not moved has none
either. Hence the generated launcher carries its CLI path on its own
`FABRICA_CLI="..."` line, and `cli_entry` reads it back out of the launcher
when the bin entry is a regular file instead of a symlink. That is the whole
reason for that line's existence; collapsing it into the `exec` line breaks
version bumps specifically, and nothing else, which is the kind of breakage
that surfaces months later.

**npm will not link over the launcher.** `bin-links`' `check-bin` rejects a
global, top-level install with `EEXIST: file already exists` unless what
occupies the path is a symlink resolving into the package being installed.
The launcher is a real file, so `install_from_pack` moves a non-symlink bin
entry aside before `npm install -g` and moves it back if the install fails -
the same shape as `work/bootstrap.sh`'s `install_fabrica`, and the reason
`--force` is not used is that it would switch off every other check npm has
to buy that one exemption. A *symlink* there is left alone: that is npm's
own shim and npm is entitled to replace it.

## One deliberate divergence from the work host

`work/bootstrap.sh` writes its launcher whether or not the `fnm install`
succeeded, and reports the missing download as a pending item in its closing
summary. `pin_fabrica_to_node` writes the launcher only once the version is
provably selectable, because a launcher naming a version fnm has not got
turns a working `fabrica` into one that cannot start at all. The difference
is who is watching: a bootstrap is a command someone ran on purpose and is
reading the output of; an activation runs from a timer on a machine nobody
is looking at, where the governing rule for every path through the sync
scripts is "never leave this worse than you found it".

## The symlink walk now exists three times

`cli_entry` here, `resolve_link` in `work/bootstrap.sh`, and `mbg_resolve`
in `modules/managed-bin-guard.sh` all follow a symlink chain by hand rather
than calling `readlink -f`/`realpath`, because neither is dependable on a
stock macOS. They are not shared, and cannot easily be: Nix gives every file
under `modules/` its own store path, so a sync script cannot source a
sibling it was not handed as an argument, and the one library it *is* handed
is sourced at the very end of the file on purpose, so its absence costs a
warning rather than the pin. Worth knowing before anyone "fixes" the
duplication by moving the sourcing earlier.
