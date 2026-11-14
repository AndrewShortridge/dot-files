//! Local error type for `nvim_rpc`.
//!
//! Mirrors the `AdapterError` shape (Plan §5.8) but stays scoped to RPC so
//! the discovery / transport / buffer-dump layers can be unit-tested without
//! pulling in `AdapterError`'s full enum. `adapter::nvim` maps these to the
//! degradation path (`Program::Raw { argv: vec!["nvim"] }`).

use thiserror::Error;

#[derive(Error, Debug)]
pub enum NvimError {
    #[error("nvim socket unreachable: {0}")]
    Socket(String),
    #[error("nvim mksession produced no output at {0}")]
    MksessionDidNothing(std::path::PathBuf),
    #[error("nvim RPC error: {0}")]
    Rpc(String),
    #[error("buffer dump I/O: {0}")]
    Io(#[from] std::io::Error),
}
