#!/bin/bash

NEOVIM_PATH="neovim"
GIT_PATH="git"
ALIAS_PATH="aliases"

set_homebrew_env_vars() {
  PROFILE_FILE="~/.zprofile"
  COMMAND="/opt/homebrew/bin/brew shellenv"

  if [ ! -z $(grep "$COMMAND" "$PROFILE_FILE") ]; then
    echo "Homebrew env vars command found. Skipping."
  else
    echo 'eval "$COMMAND"' >> $PROFILE_FILE
  fi
    
  eval "$COMMAND"
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
"./$GIT_PATH"
"./$ALIAS_PATH"
