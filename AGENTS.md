# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Nix/home-manager entry points: `flake.nix` (hosts), `configuration.nix` (system + Homebrew), `home.nix` (packages, dotfile symlinks, launchd agents). Apply with `./run.sh rebuild` (see `./run.sh help`); `nix eval --impure --expr '(builtins.getFlake (toString ./.)).darwinConfigurations.personal-mac.config...'` lets you check that an option evaluates without building or switching anything.
- Most of `home/**` is symlinked into `$HOME` via `mkOutOfStoreSymlink` in `home.nix` - editing the symlinked path IS editing the repo; nothing needs re-copying.
- Herdr plugins (`herdr plugin ...`) cannot host a long-running/daemon process: startup hooks are one-shot and must exit, and `[[panes]]` are user-facing terminal surfaces, not hidden background workers. Anything that needs to react continuously (e.g. polling `herdr agent explain` for detection-rule changes) belongs in an external script driven by a home-manager `launchd.agents` entry, not a plugin - see `home/.local/bin/herdr-agent-handoff-marker` and its `launchd.agents` block in `home.nix` for the pattern.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
