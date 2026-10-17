# fnm on the Nix hosts: why the zsh block is more than one eval line

`modules/core.nix` gives every Nix host (personal-mac, home-linux, both codespace
postures that use Nix) `fnm` plus `nodejs`. `nodejs` is deliberately kept: it is the
fallback `node` for directories that declare nothing. `fnm env` prepends its own bin
dir to PATH, so whenever a version is active it wins over the nix profile's `node`.
The work host (`work/Brewfile`, `work/codespace-bootstrap.sh`) is untouched - fnm is a
Nix-host tool only, as the brief scoped it.

Two things about the zsh block that the one-liner in fnm's README does not give you,
and that are the reason it is not a one-liner here:

- **Auto-install is not an `fnm env` option.** `--install-if-missing` is a flag on the
  `fnm use` subcommand only; `fnm env --use-on-cd` generates a hook that calls
  `fnm use --silent-if-unchanged` with no such flag, so cd'ing into a project whose
  version has never been downloaded errors instead of installing.
- **`--version-file-strategy=recursive` makes the generated hook unconditional.** With
  the default `local` strategy the generated hook guards on
  `[[ -f .node-version || -f .nvmrc ]]`; the recursive variant drops that guard and
  runs `fnm use` on *every* `cd`, since the upward walk happens inside fnm. In any
  directory with no version file above it that prints
  `Can't find version in dotfiles` unless a `fnm default` alias happens to be set
  (fnm issues #681, #1308) - i.e. an error on most `cd`s on a fresh machine.

Both are handled by redefining `_fnm_autoload_hook` *after* the `eval`, which is the
function name fnm's own generated code registered with `add-zsh-hook chpwd`. Redefining
by name rather than registering a separate hook is the safe direction: if a future fnm
renames or restructures its hook, our definition is simply never called and the host
falls back to stock fnm behavior (switching still works, only auto-install is lost)
instead of running two competing hooks. The accompanying `_fnm_version_file_above`
walk-up is pure shell (no subprocess) so the common case - `cd` into a non-Node
directory - costs nothing and stays silent, which `2>/dev/null` on the `fnm use` call
would also have achieved but only by hiding genuine install failures too.

Verifying this from a Linux dev container: there is no `nix` and no `zsh`, and WebFetch
is blocked for every domain (github.com, raw.githubusercontent.com, docs.rs included),
so `fnm env --use-on-cd --shell zsh` cannot be run to inspect its real output. WebSearch
still returns the generated hook verbatim and the relevant issue threads, and the shell
block itself can be checked by extracting it out of the Nix `''` string (unescaping
`''${` back to `${`) and running `bash -n` over it.

Nix-string gotcha in that block: `''${dir%/*}` needs the `''` escape, because a bare
`${` inside an indented Nix string is interpolation, not shell parameter expansion.
