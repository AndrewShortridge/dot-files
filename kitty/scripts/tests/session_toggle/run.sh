#!/usr/bin/env bash
# Fixture-based test runner for the MRU ranker (scripts/lib/mru-rank.jq).
# Pipes each *.json fixture through the ranker and diffs against the
# matching *.expected.txt. Exits non-zero on any mismatch.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RANKER="${HERE}/../../lib/mru-rank.jq"
FIXTURES_DIR="${HERE}/fixtures"

if [[ ! -f "$RANKER" ]]; then
  echo "ranker script not found at $RANKER" >&2
  exit 2
fi

pass=0
fail=0
failed_names=()

shopt -s nullglob
for fixture in "$FIXTURES_DIR"/*.json; do
  name="$(basename "$fixture" .json)"
  expected="${FIXTURES_DIR}/${name}.expected.txt"

  if [[ ! -f "$expected" ]]; then
    echo "MISSING expected file for fixture: $name" >&2
    fail=$((fail + 1))
    failed_names+=("$name")
    continue
  fi

  # The ranker expects a JSON array via `jq -s`. The fixture is already an
  # array, so feed it through jq's identity stream so `-s` re-slurps it
  # into the documented shape.
  actual="$(jq -c '.[]' "$fixture" | jq -rs -f "$RANKER")"
  expected_content="$(cat "$expected")"

  # Strip trailing newlines from both sides for a tolerant compare.
  if [[ "$actual" == "$expected_content" ]]; then
    echo "ok   $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    echo "--- expected ---"
    printf '%s\n' "$expected_content"
    echo "--- actual ---"
    printf '%s\n' "$actual"
    echo "--- diff ---"
    diff <(printf '%s\n' "$expected_content") <(printf '%s\n' "$actual") || true
    fail=$((fail + 1))
    failed_names+=("$name")
  fi
done
shopt -u nullglob

echo
echo "passed: $pass    failed: $fail"
if (( fail > 0 )); then
  echo "failing fixtures: ${failed_names[*]}" >&2
  exit 1
fi
