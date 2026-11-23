#!/usr/bin/env bash
# omp (oh-my-pi) user config: agent/ here mirrors the config half of ~/.omp/agent
# (config.yml: model roles, per-agent model overrides, theme, status line; skills/).
#
#   ./omp/install.sh          # new machine: install omp if missing, then apply
#   ./omp/install.sh apply    # copy agent/ into ~/.omp/agent
#   ./omp/install.sh pull     # copy the live config back here, then commit
#
# Not tracked, per machine: logins (stored in ~/.omp/agent/agent.db), sessions,
# history, caches, downloaded tools. After apply, run `omp` and `/login` for
# anthropic (OAuth) and minimax-code (API key).
# The terminal-browser skill is linked into ~/.agents/skills by terminal-browser's
# own installer, not from here.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/agent"
dst="$HOME/.omp/agent"

apply() {
    install -d -m 700 "$dst"
    if [[ -f "$dst/config.yml" ]] && ! cmp -s "$src/config.yml" "$dst/config.yml"; then
        cp "$dst/config.yml" "$dst/config.yml.bak-$(date +%Y%m%d%H%M%S)"
    fi
    install -m 600 "$src/config.yml" "$dst/config.yml"
    mkdir -p "$dst/skills"
    cp -r "$src/skills/." "$dst/skills/"
    echo "omp: config and skills applied to $dst; log in with /login inside omp"
}

case "${1:-install}" in
install)
    if ! command -v omp >/dev/null; then
        curl -fsSL https://omp.sh/install | sh
    fi
    apply
    ;;
apply)
    apply
    ;;
pull)
    install -m 644 "$dst/config.yml" "$src/config.yml"
    rm -rf "$src/skills"
    cp -r "$dst/skills" "$src/skills"
    echo "omp: live config copied to $src"
    ;;
*)
    echo "usage: $0 [install|apply|pull]" >&2
    exit 2
    ;;
esac
