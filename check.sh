#!/bin/sh
# The one command that must pass for work on this project to be green.
# Written by `fabrica register`. Inspector runs this file, and so does
# a worker's own box when no Inspector is installed - edit it here, in
# the repository, rather than anywhere in Fabrica.
set -e
shellcheck run.sh run.test.sh install.sh install.test.sh install.container-test.sh work/*.sh home/.local/bin/* && HOME="$(mktemp -d)" bash run.test.sh && HOME="$(mktemp -d)" bash install.test.sh && HOME="$(mktemp -d)" bash work/codespace-bootstrap.test.sh && HOME="$(mktemp -d)" bash home/.local/bin/dotfiles-auto-apply.test.sh
