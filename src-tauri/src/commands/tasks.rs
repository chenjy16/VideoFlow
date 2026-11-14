use std::path::PathBuf;

use tauri::{AppHandle, State};
use tauri_plugin_opener::OpenerExt;

use crate::domain::{CreateDownloadRequest, DownloadTask};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

const DEFAULT_LIMIT: i64 = 200;

#[tauri::command]
pub fn list_tasks(limit: Option<i64>, state: State<'_, AppState>) -> AppResult<Vec<DownloadTask>> {
    state.manager.list_tasks(limit.unwrap_or(DEFAULT_LIMIT))
}

#[tauri::command]
pub fn get_task(id: String, state: State<'_, AppState>) -> AppResult<DownloadTask> {
    state.manager.get_task(&id)
}

#[tauri::command]
pub fn create_download(
    request: CreateDownloadRequest,
    state: State<'_, AppState>,
) -> AppResult<DownloadTask> {
    state.manager.create(request)
}

#[tauri::command]
pub fn cancel_download(id: String, state: State<'_, AppState>) -> AppResult<DownloadTask> {
    state.manager.cancel(&id)
}

#[tauri::command]
pub fn retry_download(id: String, state: State<'_, AppState>) -> AppResult<DownloadTask> {
    state.manager.retry(&id)
}

#[tauri::command]
pub fn remove_download(id: String, state: State<'_, AppState>) -> AppResult<()> {
    state.manager.remove(&id)
}

#[tauri::command]
pub fn redownload(id: String, state: State<'_, AppState>) -> AppResult<DownloadTask> {
    state.manager.redownload(&id)
}

#[tauri::command]
pub fn list_history(
    query: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
    state: State<'_, AppState>,
) -> AppResult<Vec<DownloadTask>> {
    state.manager.list_history(
        query.as_deref(),
        limit.unwrap_or(DEFAULT_LIMIT),
        offset.unwrap_or(0),
    )
}

#[tauri::command]
pub fn get_task_logs(
    id: String,
    limit: Option<i64>,
    state: State<'_, AppState>,
) -> AppResult<Vec<String>> {
    state.manager.task_logs(&id, limit.unwrap_or(80))
}

/// 打开已下载的文件。
#[tauri::command]
pub fn open_download_file(id: String, app: AppHandle, state: State<'_, AppState>) -> AppResult<()> {
    let path = resolve_output_path(&state, &id)?;
    app.opener()
        .open_path(path.to_string_lossy().to_string(), None::<&str>)
        .map_err(|err| AppError::Other(format!("无法打开文件：{err}")))
}

/// 在 Finder 中显示文件。
#[tauri::command]
pub fn reveal_download_in_finder(
    id: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> AppResult<()> {
    let path = resolve_output_path(&state, &id)?;
    app.opener()
        .reveal_item_in_dir(&path)
        .map_err(|err| AppError::Other(format!("无法在 Finder 中显示：{err}")))
}

fn resolve_output_path(state: &State<'_, AppState>, id: &str) -> AppResult<PathBuf> {
    let task = state.manager.get_task(id)?;
    let raw = task
        .output_path
        .ok_or_else(|| AppError::Other("该任务还没有生成文件".into()))?;
    let path = PathBuf::from(raw);
    if !path.is_file() {
        return Err(AppError::Other("文件已被移动或删除，无法打开".to_string()));
    }
    Ok(path)
}
