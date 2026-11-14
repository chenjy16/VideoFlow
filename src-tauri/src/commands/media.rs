use tauri::State;

use crate::domain::MediaInfo;
use crate::error::AppResult;
use crate::state::AppState;

/// 解析链接，返回真实可用的格式与动态生成的下载选项。
#[tauri::command]
pub async fn inspect_url(url: String, state: State<'_, AppState>) -> AppResult<MediaInfo> {
    let engines = state.manager.engines_snapshot();
    crate::engine::inspect_url(&engines, &url).await
}
