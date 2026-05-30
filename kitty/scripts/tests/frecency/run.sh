#!/usr/bin/env bash
# Test runner for scripts/lib/frecency.sh and scripts/lib/score.jq.
#
# Two test sections:
#   1. Score-filter fixtures (fixtures/<name>.{entries.json,now,expected.txt}):
#      pipe `entries.json` through `score.jq` with `--argjson now <ts>` and
#      diff stdout against `expected.txt`.
#   2. Library scenarios: missing store, malformed store (not overwritten),
#      concurrent bumps (flock).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../../lib/frecency.sh"
score_jq="$here/../../lib/score.jq"
fixtures_dir="$here/fixtures"

# shellcheck source=/dev/null
source "$lib"

pass=0
fail=0
failed_names=()

mark_pass() { pass=$((pass + 1)); echo "PASS $1"; }
mark_fail() { fail=$((fail + 1)); failed_names+=("$1"); echo "FAIL $1"; }

# ---- section 1: score-filter fixtures ---------------------------------------

shopt -s nullglob
for entries_file in "$fixtures_dir"/*.entries.json; do
  name="$(basename "$entries_file" .entries.json)"
  now_file="$fixtures_dir/$name.now"
  expected_file="$fixtures_dir/$name.expected.txt"

  if [[ ! -f "$now_file" || ! -f "$expected_file" ]]; then
    mark_fail "$name (missing companion .now or .expected.txt)"
    continue
  fi

  now=$(<"$now_file"); now="${now//[[:space:]]/}"
  expected="$(cat "$expected_file")"
  actual="$(jq -r -f "$score_jq" --argjson now "$now" <"$entries_file")"

  if [[ "$actual" == "$expected" ]]; then
    mark_pass "$name"
  else
    mark_fail "$name"
    echo "--- expected ---"
    printf '%s\n' "$expected"
    echo "--- actual ---"
    printf '%s\n' "$actual"
  fi
done
shopt -u nullglob

# ---- section 2: library scenarios -------------------------------------------

# Each scenario gets its own tmpdir so the lib's $FRECENCY_STORE override
# is fully isolated.

run_scenario() {
  local name="$1"; shift
  local tmpdir
  tmpdir="$(mktemp -d -t frecency-test.XXXXXX)"
  export FRECENCY_STORE="$tmpdir/store.json"
  export FRECENCY_LOG="$tmpdir/log.txt"
  if ( "$@" ); then
    mark_pass "$name"
  else
    mark_fail "$name"
    echo "--- log ---"
    cat "$FRECENCY_LOG" 2>/dev/null || true
    echo "--- store ---"
    cat "$FRECENCY_STORE" 2>/dev/null || true
  fi
  rm -rf -- "$tmpdir"
  unset FRECENCY_STORE FRECENCY_LOG
}

# Missing file: frecency_score returns "0", frecency_dump returns empty.
scenario_missing_file() {
  [[ ! -e "$FRECENCY_STORE" ]] || { echo "store unexpectedly exists"; return 1; }
  local s; s=$(frecency_score nonexistent)
  [[ "$s" == "0" ]] || { echo "score want=0 got=$s"; return 1; }
  local d; d=$(frecency_dump)
  [[ -z "$d" ]] || { echo "dump want='' got='$d'"; return 1; }
  return 0
}

# Malformed file: not overwritten by bump or remove; score/dump treat as empty.
scenario_malformed_file() {
  local bad='not valid json {'
  printf '%s' "$bad" >"$FRECENCY_STORE"
  local s; s=$(frecency_score anything)
  [[ "$s" == "0" ]] || { echo "score on malformed: want=0 got=$s"; return 1; }
  local d; d=$(frecency_dump)
  [[ -z "$d" ]] || { echo "dump on malformed: want='' got='$d'"; return 1; }
  frecency_bump anything
  local got; got=$(<"$FRECENCY_STORE")
  [[ "$got" == "$bad" ]] || { echo "malformed file was modified!"; return 1; }
  frecency_remove anything
  got=$(<"$FRECENCY_STORE")
  [[ "$got" == "$bad" ]] || { echo "malformed file was modified by remove!"; return 1; }
  return 0
}

# Concurrent bump: two parallel bumps -> count == 2.
scenario_concurrent_bump() {
  ( frecency_bump foo ) &
  ( frecency_bump foo ) &
  wait
  local c
  c=$(jq -r '.entries.foo.count' "$FRECENCY_STORE")
  [[ "$c" == "2" ]] || { echo "concurrent bump: want count=2 got=$c"; return 1; }
  return 0
}

# Round trip: bump twice, score is positive, dump lists the key.
scenario_round_trip() {
  frecency_bump alpha
  frecency_bump alpha
  frecency_bump beta
  local sa sb
  sa=$(frecency_score alpha)
  sb=$(frecency_score beta)
  # Recency proxy: both just-bumped (within 1h) -> ×4. alpha count=2 -> 8.
  [[ "$sa" == "8" ]] || { echo "alpha score: want=8 got=$sa"; return 1; }
  [[ "$sb" == "4" ]] || { echo "beta score: want=4 got=$sb"; return 1; }
  local lines
  lines=$(frecency_dump | wc -l)
  [[ "$lines" == "2" ]] || { echo "dump line count: want=2 got=$lines"; return 1; }
  # Top line should be alpha (highest score).
  local top; top=$(frecency_dump | head -1 | cut -f1)
  [[ "$top" == "alpha" ]] || { echo "dump top: want=alpha got=$top"; return 1; }
  return 0
}

# Remove: bump then remove -> dump is empty.
scenario_remove() {
  frecency_bump removable
  frecency_remove removable
  local d; d=$(frecency_dump)
  [[ -z "$d" ]] || { echo "after remove, dump='$d'"; return 1; }
  return 0
}

# Prune orphans: seeded store with 4 keys, only `valid-project` has a .conf;
# `running-project` is in the running-keys list; `ssh-foo` and
# `__adhoc_42_7` are preserved by prefix rules; `gone-project` is the only
# true orphan. After prune: 4 keys retained, 1 dropped.
scenario_prune_orphans() {
  local sessions_dir="$(mktemp -d -t frecency-sessions.XXXXXX)"
  # Pre-seed the store with all four kinds of keys + an orphan.
  frecency_bump gone-project
  frecency_bump valid-project
  frecency_bump running-project
  frecency_bump ssh-foo
  frecency_bump __adhoc_42_7

  # Only the valid project has a .conf on disk.
  : >"$sessions_dir/valid-project.conf"

  # running-keys list contains only `running-project`.
  local running="running-project"

  frecency_prune_orphans "$sessions_dir" "$running"

  # Assertions: gone-project must be removed; the other four must remain.
  local s_gone s_valid s_running s_ssh s_adhoc
  s_gone=$(jq -r '.entries["gone-project"] // "absent"' "$FRECENCY_STORE")
  s_valid=$(jq -r '.entries["valid-project"] // "absent"' "$FRECENCY_STORE")
  s_running=$(jq -r '.entries["running-project"] // "absent"' "$FRECENCY_STORE")
  s_ssh=$(jq -r '.entries["ssh-foo"] // "absent"' "$FRECENCY_STORE")
  s_adhoc=$(jq -r '.entries["__adhoc_42_7"] // "absent"' "$FRECENCY_STORE")

  rm -rf -- "$sessions_dir"

  [[ "$s_gone"    == "absent" ]] || { echo "orphan 'gone-project' not removed: $s_gone"; return 1; }
  [[ "$s_valid"   != "absent" ]] || { echo "valid 'valid-project' was wrongly removed"; return 1; }
  [[ "$s_running" != "absent" ]] || { echo "running 'running-project' was wrongly removed"; return 1; }
  [[ "$s_ssh"     != "absent" ]] || { echo "ssh-foo was wrongly removed"; return 1; }
  [[ "$s_adhoc"   != "absent" ]] || { echo "__adhoc_42_7 was wrongly removed"; return 1; }
  return 0
}

run_scenario "missing-file"     scenario_missing_file
run_scenario "malformed-file"   scenario_malformed_file
run_scenario "concurrent-bump"  scenario_concurrent_bump
run_scenario "round-trip"       scenario_round_trip
run_scenario "remove"           scenario_remove
run_scenario "prune-orphans"    scenario_prune_orphans

echo
echo "Results: $pass passed, $fail failed."
if (( fail > 0 )); then
  printf '  - %s\n' "${failed_names[@]}"
  exit 1
fi
exit 0
