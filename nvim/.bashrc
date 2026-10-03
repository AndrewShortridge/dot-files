# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

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
alias l='ls -CF'

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


#alias v="~/miniconda3/bin/nvim"
#alias nvim="/home/andrew-cmmg/miniconda3/bin/nvim"




# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
#__conda_setup="$('/home/ans18010/miniconda3/bin/conda' 'shell.bash' 'hook' 2> /dev/null)"
#if [ $? -eq 0 ]; then
#    eval "$__conda_setup"
#else
#    if [ -f "/home/ans18010/miniconda3/etc/profile.d/conda.sh" ]; then
#        . "/home/ans18010/miniconda3/etc/profile.d/conda.sh"
#    else
#        export PATH="/home/ans18010/miniconda3/bin:$PATH"
#    fi
#fi
#unset __conda_setup
# <<< conda initialize <<<

# Activating what I am calling the base conda implementaiton
#conda activate base


#alias v="$HOME/miniconda3/bin/nvim"
#alias vi="$HOME/miniconda3/bin/nvim"
#alias nvim="$HOME/miniconda3/bin/nvim"

#alias eslint="$HOME/miniconda3/bin/eslint"
#alias prettier="$HOME/miniconda3/bin/prettier"
#alias pls="$HOME/miniconda3/bin/prisma-language-server"

#alias yz="yazi"
#alias ya="$HOME/miniconda3/bin/ya"
#alias yazi="$HOME/miniconda3/bin/ya"

#alias l="eza --no-time --no-permissions --no-user --long --color=always --icons=always"                                                                                                 
#alias ll="eza --all --long --no-time --no-permissions --no-user --color=always --icons=always"                                                                                          
#alias ls="eza --color=always --icons=always"

#alias shared-home="cd /gpfs/sharedfs1/dongare/Andrew/"

#alias load-cmmg-code="module load intel-oneapi/2026.1.0 && module load openmpi/5.0.10 && module load gcc/15.3.0"

#alias lg="lazygit"

alias interactive-job="srun -N 1 -n 40 -p general --pty bash"


set -o vi

# =============================================================================
# Containerised Neovim (see ~/.config/nvim/container/README.md)
# =============================================================================
# $HOME here is WekaFS mounted `noexec` (check: findmnt -no OPTIONS -T $HOME),
# so nothing in it can be executed no matter what the permission bits say:
#
#   $ ls -l ~/bin/nvim          -> -rwxr-xr-x   (looks fine)
#   $ ~/bin/nvim --version      -> Permission denied
#   $ hash -r; type -a vi       -> /usr/bin/vi  (PATH silently skipped it)
#
# PATH lookup skips entries it cannot exec and reports nothing, which is why
# `export PATH="$HOME/bin:$PATH"` appeared to do nothing at all. Functions are
# used instead: `bash <script>` only needs READ permission, never exec.
#
# The .sif itself is fine where it is -- apptainer only reads it.
#
# If a filesystem you can write to ever allows exec, the simpler PATH form
# works there and also covers non-bash callers:
#   export PATH="/that/dir/bin:$PATH"
NVIM_WRAPPER="$HOME/bin/nvim"
if [ -r "$NVIM_WRAPPER" ]; then
    export NVIM_SIF="$HOME/bin/nvim.sif"

    nvim() { bash "$HOME/bin/nvim" "$@"; }
    vi()   { bash "$HOME/bin/nvim" "$@"; }
    vim()  { bash "$HOME/bin/nvim" "$@"; }
    view() { bash "$HOME/bin/nvim" -R "$@"; }
    export -f nvim vi vim view

    # A command string, not a bare name: git/crontab/sbatch run $EDITOR through
    # `sh -c`, where the exported bash functions above are not visible.
    export EDITOR="bash $HOME/bin/nvim"
    export VISUAL="$EDITOR"
fi
unset NVIM_WRAPPER
