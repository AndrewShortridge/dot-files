# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples
set editing-mode vi
set show-mode-in-prompt on
set vi-cmd-mode-string "\\1\\e[2 q\\2"   # Block cursor in command mode
set vi-ins-mode-string "\\1\\e[5 q\\2"   # Beam cursor in insert mode

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=1000
HISTFILESIZE=2000

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# If set, the pattern "**" used in a pathname expansion context will
# match all files and zero or more directories and subdirectories.
#shopt -s globstar

# make less more friendly for non-text input files, see lesspipe(1)
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

# uncomment for a colored prompt, if the terminal has the capability; turned
# off by default to not distract the user: the focus in a terminal window
# should be on the output of commands, not on the prompt
#force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
	# We have color support; assume it's compliant with Ecma-48
	# (ISO/IEC-6429). (Lack of such support is extremely rare, and such
	# a case would tend to support setf rather than setaf.)
	color_prompt=yes
    else
	color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

# enable color support of ls and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    #alias dir='dir --color=auto'
    #alias vdir='vdir --color=auto'

    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# colored GCC warnings and errors
#export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# some more ls aliases
alias ll='ls -ahlF'
alias la='ls -A'
# alias l='ls -CF'
alias l='ls -aF'

# Add an "alert" alias for long running commands.  Use like so:
#   sleep 10; alert
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

# Alias definitions.
# You may want to put all your additions into a separate file like
# ~/.bash_aliases, instead of adding them here directly.
# See /usr/share/doc/bash-doc/examples in the bash-doc package.

if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

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



#export EMC_ROOT="$HOME/Desktop/software/emc_linux/v9.4.4/"
#export PATH="$HOME/Desktop/software/emc_linux/v9.4.4/bin/:$PATH"
#export PATH="$HOME/Desktop/software/emc_linux/v9.4.4/scripts/:$PATH"
#export EMC_ROOT="$HOME/Software/EMC/v9.4.4/"
export PATH="$HOME/Sofware/EMC/v9.4.4/bin/:$PATH"
export PATH="$HOME/Software/EMC/v9.4.4/scripts/:$PATH"
export PATH=$PATH:$EMC_ROOT/bin:$EMC_ROOT/scripts
export PATH="/bin/pyton3:$PATH"

export TERM=xterm-256color
export COLORTERM=truecolor

redshift -x
redshift -O 2500 -m randr

# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$('/home/andrew/miniconda3/bin/conda' 'shell.bash' 'hook' 2> /dev/null)"
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
eval "$(fzf --bash)"
alias f='fzf'
export FZF_DEFAULT_COMMAND="fd --hidden --strip-cwd-prefix --exclude .git"
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND="fd --type=d --hidden --strip-cwd-prefix --exclude .git"

export FZF_DEFAULT_OPTS="--height 50% --layout=default --border --color=hl:#2dd4bf"

export FZF_CTRL_T_OPTS="--preview 'bat --color=always -n --line-range :500 {}'"
export FZF_ALT_C_OPTS="--preview 'eza --tree --color=always {} | head -200'"

# eza
# alias ls="eza --no-filesize --long --color=always --icons=always --no-user"
# alias ls="eza --long --color=always --icons=always --no-user"
alias ls="eza --color=always --icons=always --no-user"

# Wezterm alias
alias wezterm='wezterm --config-file ~/.config/wezterm/wezterm.lua'

# Needed to run starship, MUST be at the end of the file
eval "$(starship init bash)"
