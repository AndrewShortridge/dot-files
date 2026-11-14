# Schema versioning policy: frozen pre-ship, bump-on-break post-ship

`SessionFile::CURRENT_SCHEMA: u32` exists so older manifests can be
rejected with `KError::SchemaMismatch` when a load couldn't possibly
succeed. The question is *when* we bump it.

**Pre-v1.0**: `CURRENT_SCHEMA` is pinned at `1`. Additive field changes
land with `#[serde(default)]` to absorb manifests written by older dev
builds. We do not bump for additive changes; the project has a single
user (the maintainer), and forcing voluntary re-saves on every field
addition is friction with no payoff.

**At v1.0**: the schema as it stands is declared `1`. From that point
forward we only bump on *genuinely breaking* changes — field renames,
type changes, dropped fields, changed semantics. Additive fields with
serde defaults still don't bump; serde defaults are backwards-compatible
by the library's contract.

`SchemaMismatch` is reserved for "this manifest is structurally
unreadable by this binary." Anything serde can absorb via defaults stays
at the current schema number.
