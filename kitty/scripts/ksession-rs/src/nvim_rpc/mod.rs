//! Direct msgpack-RPC client for nvim (replaces `nvim --server … --remote-*`
//! shell-outs from `ksession.sh`).
//!
//! Per Plan §5.3, this is the highest-value module of the port: a persistent
//! `UnixStream` connection (one `NvimConn` per nvim) replaces N subprocess
//! invocations and the 15×200ms polling loop around `:mksession!`. The
//! sub-modules split discovery from transport so each can be unit-tested in
//! isolation:
//!
//! - [`socket::socket_for_pid`] — 4-tier socket lookup mirroring
//!   `nvim_socket_for_pid` (`ksession.sh:100-136`).
//! - [`conn::NvimConn`] — owns the open RPC pipe, exposes the two operations
//!   the adapter needs (`mksession`, `dump_modified_buffers`).
//!
//! Errors are local to this module: callers in `adapter/nvim.rs` translate
//! them into `AdapterError` or fold to `Program::Raw { argv: vec!["nvim"] }`
//! per Plan §5.3 "Error degradation".

pub mod conn;
pub mod error;
pub mod socket;

pub use conn::NvimConn;
pub use error::NvimError;
pub use socket::socket_for_pid;
