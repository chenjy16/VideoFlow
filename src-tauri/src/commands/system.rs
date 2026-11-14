use tauri::State;

use crate::engine::EngineStatus;
use crate::error::AppResult;
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
