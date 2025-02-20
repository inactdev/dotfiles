#!/bin/bash
echo -e "BEGINNING INSTALL\n"

NEOVIM_PATH="install_neovim"
FONT_PATH="font"
GIT_PATH="git"
ALIAS_PATH="aliases"

set_homebrew_env_vars() {
  # TODO: Try to make it so that this will detect if the line exists already
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
  eval "$(/opt/homebrew/bin/brew shellenv)"
}

if [[ "$(uname -s)" == "Linux" ]]; then
  # APT for Linux
  sudo apt-get update
else
  #Homebrew for Apple
  curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | bash

  # For Apple Silicon
  if [[ $(uname -m) == 'arm64' ]]; then
    set_homebrew_env_vars
  fi
fi

"./$NEOVIM_PATH"
"./$FONT_PATH"
"./$GIT_PATH"
"./$ALIAS_PATH"

# Run zsh
zsh
source ~/.zshrc
