# Transcript-aware JSONL viewing, gated on the format version

JSONL files get a generic record preview, but nearly every JSONL file on this machine is an agent session transcript, where a generic view cannot say which of thousands of records are the user's or show message text as text. We decided the config may know the harness's session format: one reader module understands version 3, and it is used only when a version 3 session header is found in a file's first two records. Any other file, and any other version, gets the generic record preview, so a format change degrades to the generic view instead of rendering wrongly.

## Considered options

- **Generic only.** Never breaks when the harness changes, but leaves both problems unsolved: in a 2,260-record transcript the user's 45 messages are indistinguishable from the rest at the left edge of the file, and message text is one escaped line per message.
- **Transcript-aware, generic fallback (chosen).** Couples this config to a format it does not control. The coupling is confined to one reader behind a version check.

## Consequences

- The format knowledge must stay in the reader. Nothing that draws the view may read a record field.
- A new format version needs a new reader, not a change to the view.
