#!/bin/bash

NEOVIM_PATH="neovim"
ALIAS_PATH="aliases"

if [[ "$(uname -s)" == "Linux" ]]
then
  # APT for Linux
  sudo apt-get update
else
  #Homebrew for Apple
  curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | bash

  # For Apple Silicon
  if [[ $(uname -m) == 'arm64' ]]; then
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
fi

echo $NEOVIM_PATH
"./$NEOVIM_PATH"
"./$ALIAS_PATH"

# Git autocomplete
curl https://raw.githubusercontent.com/git/git/master/contrib/completion/git-completion.bash -o ~/.git-completion.bash
