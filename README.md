# pythonpackagemanager.sh

# In ~/.zshrc
source ~/.config/zsh/python-manager.sh
setpy 3.12 >/dev/null 2>&1
export CLOUDSDK_PYTHON=$(which python3)


set it permanently in .zshrc for example
setpy 3.12 is the key line
