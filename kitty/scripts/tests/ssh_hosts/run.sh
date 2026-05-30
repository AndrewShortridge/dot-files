#!/usr/bin/env bash
# Golden-test runner for scripts/lib/ssh_hosts.sh.
# Each subdirectory is one fixture: a `config` file (optional) and an
# `expected.txt`. We invoke `ssh_hosts` against the fixture's config
# path and diff the (sort-uniq) output against `expected.txt`.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../../lib/ssh_hosts.sh"

# shellcheck source=/dev/null
source "$lib"

pass=0
fail=0
failed_names=()

shopt -s nullglob
for fixture_dir in "$here"/*/; do
  name="$(basename "$fixture_dir")"
  config="$fixture_dir/config"
  expected="$fixture_dir/expected.txt"

  if [[ ! -f "$expected" ]]; then
    echo "SKIP $name (no expected.txt)"
    continue
  fi

  actual="$(ssh_hosts "$config" 2>&1)"
  expected_content="$(cat "$expected")"

  if [[ "$actual" == "$expected_content" ]]; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    echo "--- expected ---"
    echo "$expected_content"
    echo "--- actual ---"
    echo "$actual"
    echo "--- diff ---"
    diff <(printf '%s\n' "$expected_content") <(printf '%s\n' "$actual") || true
    fail=$((fail + 1))
    failed_names+=("$name")
  fi
done
shopt -u nullglob

echo
echo "Results: $pass passed, $fail failed."
if (( fail > 0 )); then
  printf '  - %s\n' "${failed_names[@]}"
  exit 1
fi
exit 0
