use std::sync::Arc;

use crate::manager::TaskManager;

/// Tauri 托管状态。
pub struct AppState {
    pub manager: Arc<TaskManager>,
}

impl AppState {
    pub fn new(manager: Arc<TaskManager>) -> Self {
        Self { manager }
    }
}
