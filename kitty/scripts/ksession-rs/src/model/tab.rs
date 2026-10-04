use serde::{Deserialize, Serialize};

use super::window::Window;

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Tab {
    pub title: Option<String>,
    pub layout: String,
    pub active_window_idx: usize,
    pub windows: Vec<Window>,
}
