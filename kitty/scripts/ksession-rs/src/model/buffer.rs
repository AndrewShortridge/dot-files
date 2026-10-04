use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct BufferDump {
    pub buf_id: i64,
    pub name: String,
    pub modified: bool,
    pub filetype: String,
    pub dump_path: PathBuf,
    pub truncated: bool,
    pub byte_count: u64,
}
