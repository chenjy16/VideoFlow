use rusqlite::{params, OptionalExtension};

use crate::domain::{AppSettings, SettingsPatch};
use crate::error::AppResult;
use crate::storage::database::{now_iso, Database};

const SETTINGS_KEY: &str = "app";

/// 读取设置；不存在或解析失败时回退到默认值。
pub fn load(db: &Database, default_dir: &str) -> AppResult<AppSettings> {
    let raw: Option<String> = db.with_conn(|conn| {
        conn.query_row(
            "SELECT value FROM settings WHERE key = ?1",
            params![SETTINGS_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()
    })?;

    match raw {
        Some(value) => match serde_json::from_str::<AppSettings>(&value) {
            Ok(settings) => Ok(settings),
            Err(err) => {
                log::warn!("Settings payload is corrupted, falling back to defaults: {err}");
                Ok(AppSettings::defaults(default_dir.to_string()))
            }
        },
        None => Ok(AppSettings::defaults(default_dir.to_string())),
    }
}

pub fn save(db: &Database, settings: &AppSettings) -> AppResult<()> {
    let payload = serde_json::to_string(settings)?;
    let now = now_iso();
    db.with_conn(|conn| {
        conn.execute(
            "INSERT INTO settings (key, value, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            params![SETTINGS_KEY, payload, now],
        )
    })?;
    Ok(())
}

/// 应用补丁并持久化。
pub fn update(
    db: &Database,
    patch: SettingsPatch,
    current: &mut AppSettings,
) -> AppResult<AppSettings> {
    let mut next = current.clone();
    next.apply_patch(patch)?;
    save(db, &next)?;
    *current = next.clone();
    Ok(next)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_returns_defaults_when_empty() {
        let db = Database::open_in_memory().expect("db");
        let settings = load(&db, "/tmp/VideoFlow").expect("load");
        assert_eq!(settings.download_dir, "/tmp/VideoFlow");
        assert_eq!(settings.max_concurrent, 2);
    }

    #[test]
    fn save_and_reload() {
        let db = Database::open_in_memory().expect("db");
        let mut settings = AppSettings::defaults("/tmp/VideoFlow".into());
        update(
            &db,
            SettingsPatch {
                max_concurrent: Some(3),
                default_quality: Some("720p".into()),
                ..Default::default()
            },
            &mut settings,
        )
        .expect("update");

        let reloaded = load(&db, "/tmp/VideoFlow").expect("reload");
        assert_eq!(reloaded.max_concurrent, 3);
        assert_eq!(reloaded.default_quality, "720p");
    }

    #[test]
    fn rejects_invalid_patch() {
        let db = Database::open_in_memory().expect("db");
        let mut settings = AppSettings::defaults("/tmp/VideoFlow".into());
        let result = update(
            &db,
            SettingsPatch {
                download_dir: Some("relative/path".into()),
                ..Default::default()
            },
            &mut settings,
        );
        assert!(result.is_err());
        assert_eq!(settings.download_dir, "/tmp/VideoFlow");
    }
}
