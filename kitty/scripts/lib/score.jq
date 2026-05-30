# Frecency scoring filter (zoxide-style).
#
# Input: an "entries" object, shape:
#   { "<key>": { "count": <int>, "last_used_ms": <int> }, ... }
#
# Args:
#   --argjson now <ms_since_epoch>
#
# Output: one line per entry, TSV: `<key>\t<score>`, sorted by score
# descending; ties broken by key ascending. Scores are floats.
#
# Decay buckets (Δ = now - last_used_ms, in ms):
#   Δ <  1h        → × 4
#   Δ <  1d        → × 2
#   Δ <  1w        → × 0.5
#   otherwise      → × 0.25

def decay(delta_ms):
  if   delta_ms <         3600000 then 4.0
  elif delta_ms <        86400000 then 2.0
  elif delta_ms <       604800000 then 0.5
  else                                  0.25
  end
;

def score_of(entry; now):
  (entry.count // 0) * decay(now - (entry.last_used_ms // 0))
;

[ to_entries[]
  | { key: .key, score: score_of(.value; $now) }
]
| sort_by([ -.score, .key ])
| .[]
| [ .key, (.score | tostring) ]
| @tsv
