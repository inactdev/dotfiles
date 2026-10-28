#!/usr/bin/env bash
#
# inkwell-tailscale-serve - put the local Inkwell backend on this machine's
# tailnet address over HTTPS, once, from home-manager activation.
#
# `tailscale serve --bg <port>` is a one-time act, not a running process:
# the configuration lives in tailscaled and comes back by itself after a
# reboot or a `tailscale down`/`up` (which is exactly what `--bg` buys over
# a foreground serve that dies with the terminal it was typed in). So the
# phone's https://<this-machine>.<tailnet>.ts.net address only needs
# configuring on a machine that has never had it configured - and this step
# is what notices that, on every switch, instead of a human remembering
# after a fresh install.
#
# Three things it never does, each of which is why this is a guarded step
# rather than the one-line command:
#
#   - it never fails a switch. No CLI, no daemon, a node that is not logged
#     in, a tailnet without HTTPS enabled: each warns on stderr and exits 0.
#   - it never overwrites somebody else's serve configuration. Plain
#     `tailscale serve --bg 8080` mounts a proxy at / on port 443, replacing
#     whatever was mounted there - so when this node already serves
#     something, and it is not this port, this step reports that and
#     changes nothing.
#   - it never blocks. A tailnet that has not enabled HTTPS certificates
#     sends the CLI into an interactive enablement flow that, by design,
#     *waits for a human* to finish it in the admin console (tailscale's
#     own `enableFeatureInteractive`), which in an activation with no
#     terminal would hang the switch for as long as it is left alone. Every
#     call here is therefore run under `timeout`.
#
# Run as: inkwell-tailscale-serve <local-port>
# The port comes from modules/inkwell.nix on the Mac and from
# modules/inkwell-linux.nix on home-linux - the same file that tells the
# backend itself which port to listen on, so the two cannot drift apart.
# Both run this with coreutils on PATH from the Nix store, for `timeout`
# and `tr` - macOS ships neither `timeout` nor a GNU `tr`.
set -euo pipefail

port=${1:?usage: inkwell-tailscale-serve <local-port>}

say() { printf 'inkwell-tailscale-serve: %s\n' "$*"; }
warn() { printf 'inkwell-tailscale-serve: %s\n' "$*" >&2; }

# The macOS Tailscale app ships its CLI inside the app bundle, as the same
# binary as the GUI, and it decides which of the two to be by sniffing the
# environment it was started in (SHLVL, TERM, TERM_PROGRAM, PS1). An
# activation step has none of those, so without this the "CLI" call can open
# the GUI app instead and never answer - TAILSCALE_BE_CLI=1 is tailscale's
# own documented way for a script to insist on the CLI, and is harmless for
# every other build of the binary.
export TAILSCALE_BE_CLI=1

# Where a tailscale CLI can be on this machine, in the order it is looked
# for: whatever PATH says (the /usr/local/bin/tailscale launcher the
# standalone app installs from its own settings lands there, and so would
# the open-source CLI), then that launcher by absolute path - an
# activation's PATH is not a login shell's - then /usr/bin/tailscale, which
# is where Tailscale's own Debian/Ubuntu package puts the CLI and therefore
# the one home-linux has, then the app bundle's own
# binary, which is the one personal-mac actually has. The Tailscale GUI
# there comes from the `tailscale-app` cask, and the like-named
# homebrew-core *formula* that would install /opt/homebrew/bin/tailscale
# conflicts with that cask and is deliberately not installed (see
# notes/20261017-tailscale-app-cask.md); it is looked for last all the same,
# so a machine that does have it is not told there is no CLI.
#
# Overridable only so the test suite can point this at a scratch directory
# and get the same answers on a machine that has a real tailscale installed
# as on one that does not.
INKWELL_TS_CLI_CANDIDATES=${INKWELL_TS_CLI_CANDIDATES:-"tailscale /usr/local/bin/tailscale /usr/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale /opt/homebrew/bin/tailscale"}

find_cli() {
  local candidate resolved
  # shellcheck disable=SC2086 # INKWELL_TS_CLI_CANDIDATES is a deliberate word-split list
  for candidate in $INKWELL_TS_CLI_CANDIDATES; do
    if resolved=$(command -v "$candidate" 2>/dev/null); then
      printf '%s\n' "$resolved"
      return 0
    fi
  done
  return 0
}

main() {
  local cli status trimmed proxy_re out

  cli=$(find_cli)
  if [ -z "$cli" ]; then
    warn "no tailscale CLI found on PATH, at /usr/local/bin/tailscale or inside"
    warn "/Applications/Tailscale.app, so nothing was published to the tailnet."
    warn "the backend is still reachable at http://127.0.0.1:$port on this machine."
    return 0
  fi

  # --json rather than the human output: the tree renderer's wording is
  # presentation and changes with it, while the JSON is the serve
  # configuration itself, and `null` for "nothing configured" is simply what
  # encoding an absent configuration produces. Read under timeout because
  # this talks to the daemon over its local API.
  #
  # stderr is dropped rather than folded in, deliberately: everything below
  # reads this as a configuration, and any aside the CLI writes alongside it
  # - an update notice, a warning about something unrelated - would make an
  # unconfigured node look like a configured one and stop this step for the
  # wrong reason. When the read fails, the same question is asked again in
  # its human form and that answer goes straight to stderr, so nothing is
  # lost on the path where the message is what matters.
  if ! status=$(timeout 30 "$cli" serve status --json 2>/dev/null); then
    warn "could not read the current serve configuration, so nothing was changed -"
    warn "this is what a stopped tailscaled or a node that is not logged in looks"
    warn "like. tailscale's own answer, asked again in its human form:"
    timeout 10 "$cli" serve status >&2 || true
    return 0
  fi

  # Any handler that proxies to this port, wherever it sits in the
  # configuration. Matched as text rather than with a JSON parser on
  # purpose: the only question being asked is whether this port is already
  # published, one `jq` fewer has to be on the activation's PATH for it, and
  # the answer survives any re-indentation of the output. The closing quote
  # is part of the pattern, so a different port that merely starts with
  # these digits cannot match.
  proxy_re="\"Proxy\"[[:space:]]*:[[:space:]]*\"[^\"]+:$port(/[^\"]*)?\""
  if [[ $status =~ $proxy_re ]]; then
    say "tailscale serve already publishes port $port here, so nothing was changed."
    return 0
  fi

  # Nothing configured at all is `null` - what encoding an absent
  # configuration produces. An empty object is accepted as the same answer
  # so that a future version which prints one instead cannot make an
  # unconfigured node read as "somebody else is using this".
  trimmed=$(printf '%s' "$status" | tr -d '[:space:]')
  if [ "$trimmed" != "null" ] && [ "$trimmed" != "{}" ]; then
    warn "this machine already serves something over tailscale, and it is not port"
    warn "$port, so its configuration was left exactly as it is - publishing this"
    warn "port would replace what is mounted at / today. Run this once by hand if"
    warn "that is what you want:"
    warn "  TAILSCALE_BE_CLI=1 $cli serve --bg $port"
    return 0
  fi

  say "publishing http://127.0.0.1:$port on this machine's tailnet address over https"
  if ! out=$(timeout 60 "$cli" serve --bg "$port" 2>&1); then
    warn "could not publish port $port, so the backend stays local to this machine."
    warn "a tailnet that has not enabled HTTPS certificates is the usual reason, and"
    warn "the CLI waits for that to be done in the admin console - which is why this"
    warn "gives up rather than waits. tailscale said: $out"
    return 0
  fi

  say "done, and it survives a reboot by itself - tailscale said:"
  printf '%s\n' "$out"
  return 0
}

main
