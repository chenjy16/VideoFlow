use tauri::State;

use crate::domain::{AppSettings, SettingsPatch};
use crate::error::AppResult;
use crate::state::AppState;

#[tauri::command]
pub fn get_settings(state: State<'_, AppState>) -> AppResult<AppSettings> {
    Ok(state.manager.settings())
}

#[tauri::command]
pub fn update_settings(patch: SettingsPatch, state: State<'_, AppState>) -> AppResult<AppSettings> {
    state.manager.update_settings(patch)
}
