# The transcript view is read from the file in parallel and built in order

A session transcript can be 25 MB with single records of 3.9 MB, and a live one keeps growing. The transcript view is therefore built from the file on disk, not from the buffer Neovim loaded: worker threads each read and decode a slice of the file, and the main thread assembles their results strictly in file order, appending finished turns to the bottom of the view as they arrive. Newly appended bytes of a live transcript are one more slice through the same path.

Measured on the largest transcripts: decoding everything on the main thread froze the editor for about 270 ms; slicing that work on the main loop still stalled 41 ms on one record that cannot be split; reading in worker threads finished in 106-154 ms with 10-19 ms of main-thread work in total.

## Considered options

- **Build everything, then show it.** One code path and a view that is always complete, but a freeze that grows with the file, and a second path would still be needed for following.
- **Fill tool results into a view already on screen.** No freeze, but lines are inserted above the reader's cursor.
- **Stream in file order, append-only (chosen).** Nothing above the newest turn ever moves.

## Consequences

- The reader is one self-contained Lua file with no editor calls: a worker thread has its own Lua state and loads it by path.
- A finished turn never changes; only the last turn can still grow. Everything that reads the conversation must accept that more turns may arrive.
- Every build carries a generation number, and results from an older generation are dropped. There are no locks: only the main thread touches a buffer, and a worker shares no memory with it.
- A slice that fails is reported in the view, never skipped silently.
- Unsaved edits to the transcript's buffer are not in the view.
