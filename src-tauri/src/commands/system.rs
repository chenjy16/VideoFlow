use std::path::PathBuf;

use tauri::{AppHandle, Manager, State};
use tauri_plugin_opener::OpenerExt;

use crate::engine::EngineStatus;
use crate::error::{AppError, AppResult};
use crate::state::AppState;

/// 引擎状态（yt-dlp / FFmpeg 路径与版本）。
#[tauri::command]
pub fn get_engine_status(state: State<'_, AppState>) -> AppResult<EngineStatus> {
    Ok(state.manager.engine_status())
}

/// 重新检测引擎（用户安装 yt-dlp 后无需重启即可刷新）。
#[tauri::command]
pub async fn refresh_engine_state(state: State<'_, AppState>) -> AppResult<EngineStatus> {
    state.manager.refresh_engines().await;
    Ok(state.manager.engine_status())
}

/// 在 Finder 中打开第三方许可证目录。
///
/// 发布版位于 `Contents/Resources/LICENSES`，开发期回落到仓库根的 `licenses/`。
#[tauri::command]
pub fn reveal_licenses(app: AppHandle) -> AppResult<()> {
    let dir = licenses_dir(&app)?;
    app.opener()
        .reveal_item_in_dir(&dir)
        .map_err(|err| AppError::Other(format!("无法在 Finder 中显示许可证目录：{err}")))
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
        .ok_or_else(|| AppError::Other("未找到第三方许可证目录".into()))
}
