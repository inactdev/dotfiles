# Tailscale on personal-mac: cask token and the formula conflict

The Homebrew cask for the Tailscale macOS app is `tailscale-app`, not `tailscale`
(`tailscale` is recorded as a *former token* of the cask and still resolves, but only
as a deprecated rename alias that warns and will eventually stop working). It is in
`homebrew.casks` in `configuration.nix`, which only `darwinConfigurations.personal-mac`
imports - the work host's `work/Brewfile` and the Nix-only/Codespaces recipes
deliberately do not carry it.

Sharp edge before adding the Tailscale CLI here: homebrew-core's `tailscale` *formula*
(the `tailscaled` daemon + `tailscale` CLI) declares `conflicts_with cask:
"tailscale-app"`. Because this repo sets `homebrew.onActivation.cleanup = "zap"` and
lists every brew/cask explicitly, listing both the formula and the cask makes Homebrew
activation fail on every `./run.sh rebuild` rather than degrading quietly. If the CLI
is ever wanted on personal-mac, get it from the cask's own bundled binary
(`/Applications/Tailscale.app/Contents/MacOS/Tailscale`) instead of adding the formula.

Verifying a cask token from a Linux dev container: there is no `brew`, and in at least
some sandboxes outbound HTTP (`wget`/`curl`, and the WebFetch tool against
`formulae.brew.sh` / `raw.githubusercontent.com`) is blocked, so `brew info --cask X`
cannot be reproduced locally. WebSearch against `formulae.brew.sh` still surfaces the
same generated-from-`brew info` metadata (token, former tokens, `depends_on macos`,
artifact type) and is the fallback to use rather than guessing a token.
