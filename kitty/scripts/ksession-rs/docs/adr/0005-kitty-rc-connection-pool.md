# Kitty RC parallelism via connection pool, not in-socket multiplexing

The Phase 1 `kitty/rpc.rs` client holds a single Unix-socket connection
behind a `Mutex<KittyTransport>`. Under `buffer_unordered(12)` fan-out
this serialises every kitty RPC across all 12 concurrent capture
futures — a 12-window save pays ~12 × 15 ms ≈ 180 ms of cumulative RPC
wall time on what should be a parallel workload. PRD-3 attacks this.

The obvious fix would be to multiplex multiple in-flight requests on a
single socket via correlation IDs (the way HTTP/2, msgpack-RPC, and
most modern RPC protocols work). Kitty does not support this. The wire
format has no correlation-id field; the server-side `async_id`
([remote_control.py:466-478](https://github.com/kovidgoyal/kitty/blob/master/kitty/remote_control.py))
is bookkeeping only and gets stripped before the response is sent, so
the client has nothing to demultiplex by. The kitty maintainer
confirms this is by design in
[Discussion #4624](https://github.com/kovidgoyal/kitty/discussions/4624).
The `async` field documented at https://sw.kovidgoyal.net/kitty/rc_protocol/
exists for deferred-completion of a single request, not for pipelining.

PRD-3 therefore implements an N-way connection pool (default 8 sockets
to the path in `listen_on`). Each connection handles one outstanding
RPC; `buffer_unordered` workers check out a connection from the pool,
issue their RPC, and return it. Connection setup cost is sub-ms on the
local Unix socket, and kitty's `password_authorizer` LRU cache (size
256) absorbs the per-connection auth check. A future reader who looks
at the connection-pool code and wonders "why not pipeline on one
socket?" should find this ADR and the cited protocol references.
