#!/usr/bin/env bash
# Fixture-table runner for scripts/lib/modal_fsm.sh.
#
# `transitions.tsv` is a 4-column tab-separated table:
#   <in_mode>\t<key>\t<expected_next_mode>\t<expected_side_effect>
#
# Each row drives one call to `picker_transition` and asserts both
# output lines match. Designed to be greppable: one PASS/FAIL line per
# row, summary at the bottom.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../../lib/modal_fsm.sh"
table="$here/transitions.tsv"

# shellcheck source=/dev/null
source "$lib"

pass=0
fail=0
failed_rows=()
row_num=0

while IFS=$'\t' read -r in_mode key want_mode want_effect; do
  row_num=$((row_num + 1))
  # Skip comments and blank lines.
  [[ -z "${in_mode:-}" || "$in_mode" == \#* ]] && continue

  out=$(picker_transition "$in_mode" "$key")
  got_mode=$(printf '%s' "$out" | sed -n '1p')
  got_effect=$(printf '%s' "$out" | sed -n '2p')

  label="(${in_mode}, ${key}) -> (${want_mode}, ${want_effect})"
  if [[ "$got_mode" == "$want_mode" && "$got_effect" == "$want_effect" ]]; then
    echo "PASS $label"
    pass=$((pass + 1))
  else
    echo "FAIL $label"
    echo "       got: (${got_mode}, ${got_effect})"
    fail=$((fail + 1))
    failed_rows+=("row $row_num: $label")
  fi
done < "$table"

echo
echo "Results: $pass passed, $fail failed."
if (( fail > 0 )); then
  printf '  - %s\n' "${failed_rows[@]}"
  exit 1
fi
exit 0
