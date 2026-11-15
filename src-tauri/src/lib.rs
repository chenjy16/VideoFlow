mod commands;
mod domain;
mod engine;
mod error;
mod manager;
mod state;
mod storage;

use std::sync::Arc;

use tauri::Manager;

use crate::domain::AppSettings;
use crate::engine::Engines;
use crate::manager::TaskManager;
use crate::state::AppState;
use crate::storage::{settings_repo, Database};

pub fn run() {
    tauri::Builder::default()
        .plugin(
            tauri_plugin_log::Builder::new()
                .level(log::LevelFilter::Info)
                .target(tauri_plugin_log::Target::new(
                    tauri_plugin_log::TargetKind::LogDir {
                        file_name: Some("videoflow".into()),
                    },
                ))
                .target(tauri_plugin_log::Target::new(
                    tauri_plugin_log::TargetKind::Stdout,
                ))
                .build(),
        )
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            let handle = app.handle().clone();

            let app_data_dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&app_data_dir)?;
            let cache_dir = app.path().app_cache_dir()?;
            std::fs::create_dir_all(&cache_dir)?;

            let db = Arc::new(Database::open(&app_data_dir.join("videoflow.db"))?);

            let default_dir = app
                .path()
                .download_dir()
                .unwrap_or_else(|_| app_data_dir.clone())
                .join("VideoFlow");
            let default_dir_str = default_dir.display().to_string();
            let settings = match settings_repo::load(&db, &default_dir_str) {
                Ok(settings) => settings,
                Err(err) => {
                    log::error!("读取设置失败，使用默认值: {err}");
                    AppSettings::defaults(default_dir_str)
                }
            };

            // 引擎探测是异步的（要跑 --version），在主线程同步等待一次即可
            let engines = tauri::async_runtime::block_on(Engines::detect());
            match &engines.yt_dlp {
                Some(path) => log::info!(
                    "yt-dlp: {} ({})",
                    path.display(),
                    engines.yt_dlp_version.as_deref().unwrap_or("unknown")
                ),
                None => log::warn!("未找到 yt-dlp，下载功能不可用"),
            }
            match &engines.ffmpeg {
                Some(path) => log::info!(
                    "ffmpeg: {} ({})",
                    path.display(),
                    engines.ffmpeg_version.as_deref().unwrap_or("unknown")
                ),
                None => log::warn!("未找到 FFmpeg，合并与音频提取不可用"),
            }
            match &engines.ffprobe {
                Some(path) => log::info!(
                    "ffprobe: {} ({})",
                    path.display(),
                    engines.ffprobe_version.as_deref().unwrap_or("unknown")
                ),
                None => log::warn!("未找到 FFprobe，音频格式转换不可用"),
            }

            let manager = TaskManager::new(handle, db, engines, settings, cache_dir);
            if let Err(err) = manager.recover() {
                log::error!("恢复任务状态失败: {err}");
            }

            app.manage(AppState::new(manager));
            Ok(())
        })
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::CloseRequested { .. }) {
                if let Some(state) = window.try_state::<AppState>() {
                    // 退出前取消运行中的任务，避免留下孤儿进程
                    state.manager.shutdown();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::media::inspect_url,
            commands::tasks::list_tasks,
            commands::tasks::get_task,
            commands::tasks::create_download,
            commands::tasks::cancel_download,
            commands::tasks::retry_download,
            commands::tasks::remove_download,
            commands::tasks::redownload,
            commands::tasks::list_history,
            commands::tasks::get_task_logs,
            commands::tasks::open_download_file,
            commands::tasks::reveal_download_in_finder,
            commands::settings::get_settings,
            commands::settings::update_settings,
            commands::system::get_engine_status,
            commands::system::refresh_engine_state,
            commands::system::reveal_licenses,
        ])
        .run(tauri::generate_context!())
        .expect("VideoFlow 启动失败");
}
