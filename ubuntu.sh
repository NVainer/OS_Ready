#!/bin/bash

read -p "Full install (recommended)? (y/n): " full_choice
if [[ "${full_choice,,}" == "y" ]]; then
  FULL_INSTALL=true
else
  FULL_INSTALL=false
fi

# increase terminal
printf '\e[8;28;105t'  # Set rows=40, cols=110

# Get current profile
PROFILE_ID=$(gsettings get org.gnome.Terminal.ProfilesList default | tr -d \')
PROFILE_PATH="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:$PROFILE_ID/"

# Save original colors
ORIGINAL_BG=$(gsettings get "$PROFILE_PATH" background-color)
ORIGINAL_FG=$(gsettings get "$PROFILE_PATH" foreground-color)

# Set dark hacker theme
gsettings set "$PROFILE_PATH" use-theme-colors false
gsettings set "$PROFILE_PATH" background-color '#000000'
gsettings set "$PROFILE_PATH" foreground-color '#3CFF2D'
gsettings set "$PROFILE_PATH" font 'Monospace 16'
gsettings set "$PROFILE_PATH" use-system-font false


GREEN='\033[0;32m'
NC='\033[0m'

banner_lines=(
"██████╗ ██╗██╗  ██╗ ██████╗██╗  ██╗        ██████╗ ██╗   ██╗███████╗███████╗ ██╗ █████╗ ███╗   ██╗"
"██╔══██╗██║██║  ██║██╔════╝██║ ██╔╝        ██╔══██╗██║   ██║██╔════╝██╔════╝███║██╔══██╗████╗  ██║"
"██████╔╝██║███████║██║     █████╔╝         ██████╔╝██║   ██║███████╗███████╗╚██║███████║██╔██╗ ██║"
"██╔══██╗██║╚════██║██║     ██╔═██╗         ██╔══██╗██║   ██║╚════██║╚════██║ ██║██╔══██║██║╚██╗██║"
"██████╔╝███████╗██║╚██████╗██║  ██╗███████╗██║  ██║╚██████╔╝███████║███████║ ██║██║  ██║██║ ╚████║"
"╚═════╝ ╚══════╝╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚══════╝ ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝"
" "
" "
" "
" "
" "
" "
" "
" "
" "
" "
" "
" "
" "
" "
" "
" "
" "
" "
" "
)

echo -e "${GREEN}"
for line in "${banner_lines[@]}"; do
  echo "$line"
  sleep 0.07
done
echo -e "${NC}"


#Pre-accepting EULA...
sudo apt install debconf-utils -y
echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | sudo debconf-set-selections

echo "Installing essentials..."
sudo apt-get update && sudo apt install -y git curl flatpak figlet ubuntu-restricted-extras gnome-tweaks gnome-shell-extensions ffmpeg

if $FULL_INSTALL || { read -p "Install Dev stuff? (y/n): " dev_choice && [[ "$dev_choice" == "y" ]]; }; then
  echo "Installing dev tools..."
    #install docker
  # Add Docker's official GPG key:
  sudo apt-get update
  sudo apt-get install ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  sleep 1
  # Add the repository to Apt sources:
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
  sudo usermod -aG docker $USER # (to run docker without sudo)
  sleep 1
  sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager swtpm wl-clipboard -y
  sudo usermod -aG docker $USER
  sudo usermod -aG libvirt $(whoami)
  sudo usermod -aG kvm $(whoami)
fi

if $FULL_INSTALL || { read -p "Do you care about security/backup? (y/n): " sec_choice && [[ "$sec_choice" == "y" ]]; }; then
  echo "Installing security/backup tools..."
  sudo apt install -y timeshift gufw fail2ban apparmor apparmor-utils keepassxc
  sudo systemctl enable fail2ban apparmor
  sudo ufw enable
  
  #disable Apache
  systemctl list-unit-files | grep -q "^apache2.service" && sudo systemctl disable apache2
fi


# remove Firefox
sudo snap remove firefox
sudo apt purge firefox -y
sudo apt-get upgrade -y
if $FULL_INSTALL || { read -p 'Install Brave browser? ¯\_( ͡° ͜ʖ ͡°)_/¯ (y/y): ' brave_choice && [[ "$brave_choice" == "y" ]]; }; then
  echo "Installing Brave browser..."
  if ! sudo curl -fsS https://dl.brave.com/install.sh | sudo bash; then
    echo "Brave install failed."
  fi
fi
# pin brave to dock
brave_desktop="brave-browser.desktop"
# Ensure it exists
if [[ -f /usr/share/applications/$brave_desktop ]]; then
  gsettings set org.gnome.shell favorite-apps "$(gsettings get org.gnome.shell favorite-apps | sed "s/]$/, '${brave_desktop}']/")"
fi


if $FULL_INSTALL || { read -p 'improve style? ♣ (y/n): ' beautify && [[ "$beautify" == "y" ]]; }; then
  echo "boom..."
  # enable dark mode
  gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
  gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-purple-dark' 

  # hide home folder
  gsettings set org.gnome.shell.extensions.ding show-home false

  # Move Dock to Bottom
  gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM'

  # auto hide dock
  gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed false

  # disable dock "panel mode"
  gsettings set org.gnome.shell.extensions.dash-to-dock extend-height false

  # change icon size to 60
  gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 60

  # unpin Help from dock
  gsettings set org.gnome.shell favorite-apps "$(gsettings get org.gnome.shell favorite-apps | sed "s/, 'yelp.desktop'//; s/'yelp.desktop', //; s/'yelp.desktop'//")"

  # add ALT + SHIFT for layout change
  gsettings set org.gnome.desktop.input-sources xkb-options "['grp:alt_shift_toggle', 'lv3:ralt_switch']"

  # add Hebrew as a secondery lang
  gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('xkb', 'il')]"

  # set default "last modified" in file explorer
  gsettings set org.gnome.nautilus.preferences default-sort-order 'mtime'
  gsettings set org.gnome.nautilus.preferences default-sort-in-reverse-order true


fi

if $FULL_INSTALL || { read -p 'install ZSH (better shell)? (y/n): ' better_shell && [[ "$better_shell" == "y" ]]; }; then
  echo "install zsh..."
  sudo apt install zsh-common zsh-doc zsh
  # making zsh default
  sudo chsh -s $(which zsh) "$USER"
  RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

  # installing fonts
  mkdir -p ~/.local/share/fonts 
  cd ~/.local/share/fonts 
  wget https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip 
  unzip FiraCode.zip 
  rm FiraCode.zip 
  fc-cache -fv 
  cd ~

  # install powerlevel10k theme
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k 
  sed -i 's/^ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$HOME/.zshrc"
  git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
  git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting 
  sed -i 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' "$HOME/.zshrc"
  

  # pull my p10k script from my github my_p10k 
  curl -fsSL https://raw.githubusercontent.com/NVainer/fast_ubuntu/refs/heads/main/my_p10k.zsh -o ~/.p10k.zsh
  echo 'POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true' >> ~/.zshrc
  echo '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh' >> ~/.zshrc
  {
  echo '### BEGIN ZSH COMPLETION BLOCK ###'
  echo 'autoload -Uz compinit'
  echo 'compinit'
  echo "bindkey '^I' expand-or-complete"
  echo 'setopt AUTO_MENU LIST_PACKED'
  echo "zstyle ':completion:*' completer _complete"
  echo "zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'"
  echo '### END ZSH COMPLETION BLOCK ###'
  } >> ~/.zshrc
fi



if $FULL_INSTALL || { read -p "Want to create system backup with Timeshift now? (y/n): " backup_choice && [[ "$backup_choice" == "y" ]]; }; then
  sudo timeshift --create --comments "stable system"
fi

gsettings set "$PROFILE_PATH" background-color "$ORIGINAL_BG"
gsettings set "$PROFILE_PATH" foreground-color "$ORIGINAL_FG"
gsettings set "$PROFILE_PATH" font "$ORIGINAL_FONT"
gsettings set "$PROFILE_PATH" use-system-font true
gsettings set "$PROFILE_PATH" use-theme-colors true
gsettings set "$PROFILE_PATH" use-theme-colors false
gsettings set "$PROFILE_PATH" background-color '#150F1A'
gsettings set "$PROFILE_PATH" foreground-color '#D3D3D3'
printf '\e[8;28;125t'  # Set rows=40, cols=115

read -p "Disable SSH? (y/n): " disable_ssh
if [[ "${disable_ssh,,}" == "y" ]]; then
  echo "Disabling SSH service..."
  sudo systemctl disable ssh
  sudo systemctl stop ssh
fi



clear
echo -e "\e[1;32m"
figlet "All done!"
echo " "
echo " "
echo "It's time to logout/login ☺"
echo -e "\e[0m"
echo " "
echo " "
echo " "

read -p "Logout now? (y/n): " logout_now
if [[ "${logout_now,,}" == "y" ]]; then
  gnome-session-quit --logout --no-prompt
fi
