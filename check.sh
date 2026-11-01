#!/bin/sh
# The one command that must pass for work on this project to be green.
# Written by `fabrica register`. Inspector runs this file, and so does
# a worker's own box when no Inspector is installed - edit it here, in
# the repository, rather than anywhere in Fabrica.
set -e

# nixfmt is required, not optional. Pull request #38 passed Inspector and
# then failed CI twice on `nixfmt --check` because this file ran
# shellcheck and the bash suites but no formatter (issue #43), and
# skipping when the formatter is absent would leave exactly that hole
# open on any box missing it - a skip reads as "covered" and is how the
# miss got through in the first place. So a missing nixfmt is red here.
# Inspector's image carries it (see Dockerfile.inspector), and every
# Nix-managed host already has it via modules/core.nix.
if ! command -v nixfmt >/dev/null 2>&1; then
  echo "check.sh: nixfmt is not on PATH, so the formatting check cannot run." >&2
  echo "check.sh: Inspector's image carries it (see Dockerfile.inspector); elsewhere, 'nix shell nixpkgs#nixfmt' puts it on PATH." >&2
  exit 1
fi

# Every tracked .nix file, enumerated exactly the way the nixfmt step in
# .github/workflows/ci-floor.yml does, so the two cannot disagree about
# what is in scope: `git ls-files` rather than a shell glob, so untracked
# scratch files are left alone and no directory has to be listed by hand,
# and -z/-0 so a path containing whitespace still arrives as one argument.
# It is `nixfmt` straight off PATH rather than CI's `nix shell
# nixpkgs#nixfmt --command nixfmt` because Inspector runs the container
# with --network none, so nothing can be fetched at check time.
git ls-files -z '*.nix' | xargs -0 nixfmt --check

shellcheck run.sh run.test.sh install.sh install.test.sh install.container-test.sh work/*.sh home/.local/bin/* && HOME="$(mktemp -d)" bash run.test.sh && HOME="$(mktemp -d)" bash install.test.sh && HOME="$(mktemp -d)" bash work/codespace-bootstrap.test.sh && HOME="$(mktemp -d)" bash home/.local/bin/dotfiles-auto-apply.test.sh && HOME="$(mktemp -d)" bash modules/inkwell-sync.test.sh && HOME="$(mktemp -d)" bash modules/inkwell-tailscale-serve.test.sh && HOME="$(mktemp -d)" bash modules/inkwell-key-file.test.sh && HOME="$(mktemp -d)" bash modules/inkwell-linux-sync.test.sh && HOME="$(mktemp -d)" bash modules/managed-key-file.test.sh
