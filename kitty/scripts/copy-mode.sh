#!/usr/bin/env bash
# copy-mode - tmux-style copy mode for a kitty window, in Neovim. Bound from
# kitty.conf (ctrl+shift+f3) and the leader spec (ctrl+space > [).
#
# kitty runs this in an overlay over the window, with that window's scrollback
# and screen on stdin:
#   launch --type=overlay --stdin-source=@screen_scrollback
#          --stdin-add-formatting --stdin-add-line-wrap-markers copy-mode.sh
# and $KITTY_PIPE_DATA (scroll offset, cursor, size) in the environment.
#
# Neovim needs the terminal on stdin, so the snapshot moves to fd 3 and stdin
# is reopened on the overlay's tty (stdout). copy-mode.lua reads fd 3 and does
# the rest; the user's Neovim config loads as usual.

set -euo pipefail

# Kitty launches this directly (not via an interactive shell), so .bashrc
# isn't sourced and local paths (nvim, the clipboard tool) may be missing.
export PATH="$PATH:/usr/local/bin:/usr/bin:/home/andrew/.local/bin"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec nvim -S "$here/copy-mode.lua" 3<&0 0<&1
