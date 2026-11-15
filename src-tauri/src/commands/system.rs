use std::path::PathBuf;

use tauri::{AppHandle, Manager, State};
use tauri_plugin_opener::OpenerExt;

use crate::engine::EngineStatus;
use crate::error::{AppError, AppResult};
use crate::state::AppState;

/// Engine status (yt-dlp / FFmpeg path and version).
#[tauri::command]
pub fn get_engine_status(state: State<'_, AppState>) -> AppResult<EngineStatus> {
    Ok(state.manager.engine_status())
}

/// Re-detects the engines, so installing yt-dlp doesn't require a restart.
#[tauri::command]
pub async fn refresh_engine_state(state: State<'_, AppState>) -> AppResult<EngineStatus> {
    state.manager.refresh_engines().await;
    Ok(state.manager.engine_status())
}

/// Reveals the third-party license folder in Finder.
///
/// Released builds ship it at `Contents/Resources/LICENSES`; during development
/// it falls back to `licenses/` in the repository root.
#[tauri::command]
pub fn reveal_licenses(app: AppHandle) -> AppResult<()> {
    let dir = licenses_dir(&app)?;
    app.opener().reveal_item_in_dir(&dir).map_err(|err| {
        AppError::Other(format!(
            "Couldn't reveal the licenses folder in Finder: {err}"
        ))
    })
}

fn licenses_dir(app: &AppHandle) -> AppResult<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(resources) = app.path().resource_dir() {
        candidates.push(resources.join("LICENSES"));
    }
    candidates.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../licenses"));

    candidates
        .into_iter()
        .find(|path| path.is_dir())
        .ok_or_else(|| AppError::Other("The third-party licenses folder wasn't found".into()))
}
