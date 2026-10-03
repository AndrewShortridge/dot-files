#!/usr/bin/env bash
# Install keyd (Pop!_OS 24.04 has no package; use the upstream PPA) and apply
# ~/.config/kitty/keyd/default.conf as /etc/keyd/default.conf.
#
#   ./keyd/install.sh          # first time: adds PPA, installs, enables, applies
#   ./keyd/install.sh apply    # later: just copy the config and reload
#
# Needs sudo. Panic exit if the keyboard wedges: backspace+esc+enter.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/default.conf"
dst=/etc/keyd/default.conf

if [[ "${1:-}" != "apply" ]] && ! command -v keyd >/dev/null; then
    sudo apt-get update
    sudo apt-get install -y software-properties-common
    sudo add-apt-repository -y ppa:keyd-team/ppa
    sudo apt-get update
    sudo apt-get install -y keyd
fi

sudo install -d -m 755 /etc/keyd
if [[ -f "$dst" ]] && ! sudo cmp -s "$src" "$dst"; then
    sudo cp "$dst" "$dst.bak-$(date +%Y%m%d%H%M%S)"
fi
sudo install -m 644 "$src" "$dst"

sudo systemctl enable --now keyd
sudo keyd reload
sleep 0.3
# keyd logs config parse errors to the journal; surface them here.
journalctl -u keyd --no-pager -n 20 -o cat | sed -n '/ERROR\|error\|Loaded/p' || true
echo "keyd: $(systemctl is-active keyd); config applied from $src"
