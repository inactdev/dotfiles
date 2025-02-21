#!/bin/bash
echo -e "INSTALLING Tmux\n"

# Installs Tmux
if [[ "$(uname -s)" == "Linux" ]]; then
  apt-get install -y bash bc coreutils gawk git jq playerctl
  sudo apt install -y tmux
else
  brew install tmux
fi

git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
