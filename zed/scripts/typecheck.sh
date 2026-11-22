#!/usr/bin/env bash
# The type checkers behind Zed's <leader>a tasks (tasks.json). Commands and
# flags are those of nvim's lua/andrew/plugins/type-checker.lua; `auto` picks
# the checker by file extension, as :TypeCheck picks it by filetype there.
# mpiifx (<leader>ai, <leader>at) is not here: it exists on the cluster only.
#
# usage: typecheck.sh <auto|ruff|ty|tsc|cargo|lua|fortran|cpp> <file> <project root>
set -euo pipefail

checker=$1
file=$2
root=$3

# Print the first of the given commands that is installed.
first_installed() {
  local candidate
  for candidate in "$@"; do
    if command -v "$candidate"; then
      return
    fi
  done
  echo "not installed: $*" >&2
  exit 127
}

if [[ $checker == auto ]]; then
  case "${file##*.}" in
    py) checker=ruff ;;
    ts | tsx | js | jsx) checker=tsc ;;
    rs) checker=cargo ;;
    lua) checker=lua ;;
    f | F | f90 | F90 | f95 | F95 | f03 | F03 | f08 | F08 | for | FOR) checker=fortran ;;
    c | cc | cpp | cxx) checker=cpp ;;
    *)
      echo "No type checker configured for: $file" >&2
      exit 2
      ;;
  esac
fi

cd "$root"

case $checker in
  ruff) exec ruff check --no-cache "$file" ;;
  ty) exec ty check "$file" ;;
  tsc)
    if command -v tsc >/dev/null; then
      exec tsc --noEmit
    fi
    exec node node_modules/.bin/tsc --noEmit
    ;;
  cargo) exec cargo check ;;
  lua)
    lua_language_server=$(first_installed lua-language-server "$HOME/miniconda3/bin/lua-language-server")
    exec "$lua_language_server" --check="$root"
    ;;
  fortran)
    compiler=$(first_installed mpif90 mpifort gfortran)
    include_dir=$root
    if [[ -d $root/code ]]; then
      include_dir=$root/code
    fi
    exec "$compiler" -c -fsyntax-only -Wall -Wextra -Wconversion -Wconversion-extra \
      -Wimplicit-interface -Wimplicit-procedure -Winteger-division \
      -Wcharacter-truncation -Warray-bounds -Wuninitialized -fimplicit-none \
      "-I$include_dir" "$file"
    ;;
  cpp)
    compiler=$(first_installed g++ clang++)
    exec "$compiler" -fsyntax-only -Wall -Wextra -Wpedantic "$file"
    ;;
  *)
    echo "unknown checker: $checker" >&2
    exit 2
    ;;
esac
