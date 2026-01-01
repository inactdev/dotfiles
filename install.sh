#!/bin/zsh
echo -e "BEGINNING INSTALL\n"

TMUX_PATH="tmux"
TMUX_CONFIG_PATH="tmux_config"
NEOVIM_PATH="install_neovim"
NEOVIM_CONFIG_PATH="neovim_config"
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

"./$TMUX_PATH"
"./$TMUX_CONFIG_PATH"
"./$NEOVIM_PATH"
"./$NEOVIM_CONFIG_PATH"
"./$FONT_PATH"
"./$GIT_PATH"
"./$ALIAS_PATH"

# Compile and install Ghostty terminfo
sudo tic -x ./xterm-ghostty.ti

echo "SETTING ZSH AS DEFAULT SHELL"

sudo chsh "$(id -un)" --shell "/usr/bin/zsh"

echo "DONE !!"
