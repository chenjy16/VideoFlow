use std::path::Path;
use std::sync::Mutex;

use rusqlite::Connection;

use crate::error::{AppError, AppResult};

/// 轻量 SQLite 封装。
///
/// 整个应用共享一个连接（由 Mutex 保护），所有 SQL 只能通过 Repository 层访问，
/// 业务逻辑不直接拼接或执行 SQL。
pub struct Database {
    conn: Mutex<Connection>,
}

impl Database {
    pub fn open(path: &Path) -> AppResult<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|err| {
                AppError::Database(rusqlite::Error::InvalidPath(err.to_string().into()))
            })?;
        }

        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;

        let db = Self {
            conn: Mutex::new(conn),
        };
        db.migrate()?;
        Ok(db)
    }

    /// 内存数据库，仅用于单元测试。
    #[cfg(test)]
    pub fn open_in_memory() -> AppResult<Self> {
        let conn = Connection::open_in_memory()?;
        let db = Self {
            conn: Mutex::new(conn),
        };
        db.migrate()?;
        Ok(db)
    }

    fn migrate(&self) -> AppResult<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|_| AppError::Other("数据库锁被污染".into()))?;
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS downloads (
                id                TEXT PRIMARY KEY,
                url               TEXT NOT NULL,
                title             TEXT NOT NULL,
                thumbnail         TEXT,
                site              TEXT,
                status            TEXT NOT NULL,
                kind              TEXT NOT NULL DEFAULT 'video',
                selector          TEXT,
                format_label      TEXT,
                container         TEXT,
                audio_format      TEXT,
                output_dir        TEXT,
                output_path       TEXT,
                total_bytes       INTEGER,
                downloaded_bytes  INTEGER NOT NULL DEFAULT 0,
                speed             REAL,
                eta               INTEGER,
                created_at        TEXT NOT NULL,
                started_at        TEXT,
                completed_at      TEXT,
                error_message     TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_downloads_created_at
                ON downloads(created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_downloads_status
                ON downloads(status);

            CREATE TABLE IF NOT EXISTS settings (
                key        TEXT PRIMARY KEY,
                value      TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS download_logs (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                download_id TEXT NOT NULL,
                level       TEXT NOT NULL,
                message     TEXT NOT NULL,
                created_at  TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_download_logs_download_id
                ON download_logs(download_id);
            "#,
        )?;

        // 早期开发版本把 UI 选项 id 存在 format_id 列，语义已改为 yt-dlp 的 -f 表达式
        let mut legacy =
            conn.prepare("SELECT 1 FROM pragma_table_info('downloads') WHERE name = 'format_id'")?;
        if legacy.exists([])? {
            conn.execute(
                "ALTER TABLE downloads RENAME COLUMN format_id TO selector",
                [],
            )?;
        }
        Ok(())
    }

    /// 在连接上执行闭包。
    ///
    /// 注意：闭包内不要执行耗时 IO，锁是全局共享的。
    pub fn with_conn<T, F>(&self, f: F) -> AppResult<T>
    where
        F: FnOnce(&Connection) -> rusqlite::Result<T>,
    {
        let conn = self
            .conn
            .lock()
            .map_err(|_| AppError::Other("数据库锁被污染".into()))?;
        Ok(f(&conn)?)
    }
}

/// 生成 ISO-8601 UTC 时间戳。
pub fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrate_creates_schema() {
        let db = Database::open_in_memory().expect("open");
        let tables: Vec<String> = db
            .with_conn(|conn| {
                let mut stmt = conn
                    .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")?;
                let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
                rows.collect()
            })
            .expect("tables");
        assert!(tables.contains(&"downloads".to_string()));
        assert!(tables.contains(&"settings".to_string()));
        assert!(tables.contains(&"download_logs".to_string()));
    }
}
