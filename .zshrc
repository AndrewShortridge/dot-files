# Needed to run starship, MUST be at the end of the file
eval "$(starship init zsh)"

# Set up the prompt
autoload -Uz promptinit
promptinit
prompt adam1

setopt histignorealldups sharehistory

# Use emacs keybindings even if our EDITOR is set to vi
bindkey -e

# Keep 1000 lines of history within the shell and save it to ~/.zsh_history:
HISTSIZE=1000
SAVEHIST=1000
HISTFILE=~/.zsh_history

# Use modern completion system
autoload -Uz compinit
compinit

zstyle ':completion:*' auto-description 'specify: %d'
zstyle ':completion:*' completer _expand _complete _correct _approximate
zstyle ':completion:*' format 'Completing %d'
zstyle ':completion:*' group-name ''
zstyle ':completion:*' menu select=2
eval "$(dircolors -b)"
zstyle ':completion:*:default' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' list-colors ''
zstyle ':completion:*' list-prompt %SAt %p: Hit TAB for more, or the character to insert%s
zstyle ':completion:*' matcher-list '' 'm:{a-z}={A-Z}' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=* l:|=*'
zstyle ':completion:*' menu select=long
zstyle ':completion:*' select-prompt %SScrolling active: current selection at %p%s
zstyle ':completion:*' use-compctl false
zstyle ':completion:*' verbose true

zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'



# --------------------- Manual configuartion added -------------
set editing-mode vi
set show-mode-in-prompt on
set vi-cmd-mode-string "\\1\\e[2 q\\2"   # Block cursor in command mode
set vi-ins-mode-string "\\1\\e[5 q\\2"   # Beam cursor in insert mode

# Custom alias
alias ll='ls -ahlF'
alias la='ls -A'
# alias l='ls -CF'
alias l='ls -aF'

alias aptup='sudo apt update && sudo apt upgrade -y && sudo apt full-upgrade -y && sudo apt autoremove -y && flatpak update -y'
alias vpn-connect='/opt/cisco/anyconnect/bin/vpnui'
alias ovito='/home/andrew/Software/ovito-basic-3.7.12-x86_64/bin/ovito'
alias python='python3'
alias uconn-login='ssh ans18010@hpc2.storrs.hpc.uconn.edu'
alias uconn-login6='ssh ans18010@login6.storrs.hpc.uconn.edu'
alias uconn-login5='ssh ans18010@login5.storrs.hpc.uconn.edu'
alias uconn-login4='ssh ans18010@login4.storrs.hpc.uconn.edu'
alias cmmg-lab-login='sudo ssh andrew-cmmg@137.99.154.100:~/Desktop'
alias cmmg-lab-mount='sudo sshfs -o allow_other andrew-cmmg@137.99.154.100:/home/andrew-cmmg/Desktop /mnt/CMMG-Lab-Desktop'
alias cmmg-lab-unmount='sudo umount /mnt/CMMG-Lab-Desktop'
#alias cmmg-lab-wakeup='sudo wakeonlan -i 137.99.154.100 -p 3389 2e:a1:24:b5:0b:f4'
#alias cmmg-lab-wakeup='sudo wakeonlan -i 137.99.154.100 -p 3389 c4:5a:b1:dd:dd:81'
alias cmmg-lab-wakeup='sudo wakeonlan -i 137.99.154.100 -p 3389 4c:77:cb:25:71:82'
alias backup-cmmg-phd='rsync -ahzv andrew-cmmg@137.99.154.100:~/Desktop/PhD ~/Documents'
alias backup-cmmg-personal='rsync -ahzv andrew-cmmg@137.99.154.100:~/Desktop/Personal ~/Documents'
alias backup-cmmg-personal-vault='rsync -ahzv andrew-cmmg@137.99.154.100:~/Desktop/Personal\ Vault ~/Documents'
alias backup-dryrun-cmmg-phd='rsync --dry-run -ahzv andrew-cmmg@137.99.154.100:~/Desktop/PhD ~/Documents'
alias backup-dryrun-cmmg-personal='rsync --dry-run -ahzv andrew-cmmg@137.99.154.100:~/Desktop/Personal ~/Documents'
alias backup-dryrun-cmmg-personal-vault='rsync --dry-run -ahzv andrew-cmmg@137.99.154.100:~/Desktop/Personal\ Vault ~/Documents'


alias nv='nvim'
alias neovim='nvim'
alias vim='nvim'
alias v='nvim'

# Set default editor to miniconda neovim (0.11.5)
export EDITOR='/home/andrew/miniconda3/bin/nvim'
export VISUAL='/home/andrew/miniconda3/bin/nvim'


export PATH="$HOME/Sofware/EMC/v9.4.4/bin/:$PATH"
export PATH="$HOME/Software/EMC/v9.4.4/scripts/:$PATH"
export PATH=$PATH:$EMC_ROOT/bin:$EMC_ROOT/scripts
export PATH="/bin/pyton3:$PATH"

# export TERM=xterm-256color
# export COLORTERM=truecolor


# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$('/home/andrew/miniconda3/bin/conda' 'shell.zsh' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "/home/andrew/miniconda3/etc/profile.d/conda.sh" ]; then
        . "/home/andrew/miniconda3/etc/profile.d/conda.sh"
    else
        export PATH="/home/andrew/miniconda3/bin:$PATH"
    fi
fi
unset __conda_setup
# <<< conda initialize <<<


. "$HOME/.cargo/env"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# opencode
export PATH=/home/andrew/.opencode/bin:$PATH
export PATH="$PATH:/opt/nvim-linux-x86_64/bin"
export PATH="/opt/nvim-linux-x86_64/bin:$PATH"


# fzf
eval "$(fzf --zsh)"
alias f='fzf'
export FZF_DEFAULT_COMMAND="fd --hidden --strip-cwd-prefix --exclude .git"
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND="fd --type=d --hidden --strip-cwd-prefix --exclude .git"

export FZF_DEFAULT_OPTS="--height 50% --layout=default --border --color=hl:#2dd4bf"

export FZF_CTRL_T_OPTS="--preview 'bat --color=always -n --line-range :500 {}'"
export FZF_ALT_C_OPTS="--preview 'eza --tree --color=always {} | head -200'"

# eza
alias l="eza --no-time --no-permissions --no-user --long --color=always --icons=always"
alias ll="eza --all --long --no-time --no-permissions --no-user --color=always --icons=always"
alias ls="eza --color=always --icons=always"
# alias ls="eza --long --color=always --icons=always --no-user"
# alias ls="eza --color=always --icons=always --no-user"
# alias ls="eza --color=always --icons=always"

# Wezterm alias
alias wezterm='wezterm --config-file ~/.config/wezterm/wezterm.lua'

# Adding zsh autosuggestions, MUST have this to work
source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh

