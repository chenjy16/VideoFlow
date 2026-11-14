use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::domain::{DownloadTask, TaskKind, TaskStatus};
use crate::storage::database::now_iso;

const COLUMNS: &str = "id, url, title, thumbnail, site, status, kind, selector, format_label, \
     container, audio_format, output_dir, output_path, total_bytes, downloaded_bytes, speed, eta, \
     created_at, started_at, completed_at, error_message";

fn map_row(row: &Row<'_>) -> rusqlite::Result<DownloadTask> {
    Ok(DownloadTask {
        id: row.get("id")?,
        url: row.get("url")?,
        title: row.get("title")?,
        thumbnail: row.get("thumbnail")?,
        site: row.get("site")?,
        status: TaskStatus::parse(&row.get::<_, String>("status")?),
        kind: TaskKind::parse(&row.get::<_, String>("kind")?),
        selector: row.get("selector")?,
        format_label: row.get("format_label")?,
        container: row.get("container")?,
        audio_format: row.get("audio_format")?,
        output_dir: row.get("output_dir")?,
        output_path: row.get("output_path")?,
        total_bytes: row.get("total_bytes")?,
        downloaded_bytes: row.get("downloaded_bytes")?,
        speed: row.get("speed")?,
        eta: row.get("eta")?,
        created_at: row.get("created_at")?,
        started_at: row.get("started_at")?,
        completed_at: row.get("completed_at")?,
        error_message: row.get("error_message")?,
    })
}

pub fn insert(conn: &Connection, task: &DownloadTask) -> rusqlite::Result<()> {
    conn.execute(
        &format!(
            "INSERT INTO downloads ({COLUMNS}) VALUES \
             (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)"
        ),
        params![
            task.id,
            task.url,
            task.title,
            task.thumbnail,
            task.site,
            task.status.as_str(),
            task.kind.as_str(),
            task.selector,
            task.format_label,
            task.container,
            task.audio_format,
            task.output_dir,
            task.output_path,
            task.total_bytes,
            task.downloaded_bytes,
            task.speed,
            task.eta,
            task.created_at,
            task.started_at,
            task.completed_at,
            task.error_message,
        ],
    )?;
    Ok(())
}

/// 重试前重置任务：回到等待队列并清空上一轮结果。
pub fn reset_for_retry(conn: &Connection, id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE downloads SET status = 'waiting', error_message = NULL,
            downloaded_bytes = 0, speed = NULL, eta = NULL, completed_at = NULL,
            output_path = NULL WHERE id = ?1",
        params![id],
    )?;
    Ok(())
}

/// 标记为已取消（用户在运行中取消，或等待中被取消）。
pub fn mark_cancelled(conn: &Connection, id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE downloads SET status = 'cancelled', speed = NULL, eta = NULL,
            completed_at = ?1 WHERE id = ?2",
        params![now_iso(), id],
    )?;
    Ok(())
}

/// 标记为完成，并记录真实输出文件大小。
pub fn mark_completed(
    conn: &Connection,
    id: &str,
    output_path: &str,
    file_size: Option<i64>,
) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE downloads SET status = 'completed', output_path = ?1,
            total_bytes = COALESCE(?2, total_bytes),
            downloaded_bytes = COALESCE(?2, downloaded_bytes),
            speed = NULL, eta = NULL, completed_at = ?3, error_message = NULL
         WHERE id = ?4",
        params![output_path, file_size, now_iso(), id],
    )?;
    Ok(())
}

/// 标记为失败并保留可诊断错误。
pub fn mark_failed(conn: &Connection, id: &str, message: &str) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE downloads SET status = 'failed', speed = NULL, eta = NULL,
            error_message = ?1, completed_at = ?2 WHERE id = ?3",
        params![message, now_iso(), id],
    )?;
    Ok(())
}

/// 只更新进度字段，避免高频写入携带整行数据。
pub fn update_progress(
    conn: &Connection,
    id: &str,
    downloaded_bytes: i64,
    total_bytes: Option<i64>,
    speed: Option<f64>,
    eta: Option<i64>,
) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE downloads SET downloaded_bytes = ?1, total_bytes = ?2, speed = ?3, eta = ?4
         WHERE id = ?5",
        params![downloaded_bytes, total_bytes, speed, eta, id],
    )?;
    Ok(())
}

pub fn set_status(
    conn: &Connection,
    id: &str,
    status: TaskStatus,
    error_message: Option<&str>,
) -> rusqlite::Result<()> {
    let completed_at = if matches!(status, TaskStatus::Completed) {
        Some(now_iso())
    } else {
        None
    };
    conn.execute(
        "UPDATE downloads SET status = ?1, error_message = ?2,
            completed_at = COALESCE(?3, completed_at) WHERE id = ?4",
        params![status.as_str(), error_message, completed_at, id],
    )?;
    Ok(())
}

pub fn mark_started(conn: &Connection, id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE downloads SET status = ?1, started_at = ?2, error_message = NULL,
            speed = NULL, eta = NULL WHERE id = ?3",
        params![TaskStatus::Extracting.as_str(), now_iso(), id],
    )?;
    Ok(())
}

pub fn get(conn: &Connection, id: &str) -> rusqlite::Result<Option<DownloadTask>> {
    conn.query_row(
        &format!("SELECT {COLUMNS} FROM downloads WHERE id = ?1"),
        params![id],
        map_row,
    )
    .optional()
}

/// 任务中心列表：活跃任务在前，其余按创建时间倒序。
pub fn list_tasks(conn: &Connection, limit: i64) -> rusqlite::Result<Vec<DownloadTask>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {COLUMNS} FROM downloads
         ORDER BY CASE WHEN status IN ('waiting','extracting','downloading','merging') THEN 0 ELSE 1 END,
                  datetime(created_at) DESC
         LIMIT ?1"
    ))?;
    let rows = stmt.query_map(params![limit], map_row)?;
    rows.collect()
}

/// 历史记录：仅终态任务，支持标题 / 链接搜索。
pub fn list_history(
    conn: &Connection,
    query: Option<&str>,
    limit: i64,
    offset: i64,
) -> rusqlite::Result<Vec<DownloadTask>> {
    let like = query
        .map(|q| q.trim())
        .filter(|q| !q.is_empty())
        .map(|q| format!("%{q}%"));

    let sql = format!(
        "SELECT {COLUMNS} FROM downloads
         WHERE status NOT IN ('waiting','extracting','downloading','merging')
           AND (?1 IS NULL OR title LIKE ?1 OR url LIKE ?1)
         ORDER BY datetime(COALESCE(completed_at, created_at)) DESC
         LIMIT ?2 OFFSET ?3"
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params![like, limit, offset], map_row)?;
    rows.collect()
}

/// 下一个待执行任务（按创建时间先进先出）。
pub fn next_waiting(conn: &Connection) -> rusqlite::Result<Option<DownloadTask>> {
    conn.query_row(
        &format!(
            "SELECT {COLUMNS} FROM downloads WHERE status = 'waiting'
             ORDER BY datetime(created_at) ASC LIMIT 1"
        ),
        [],
        map_row,
    )
    .optional()
}

/// 应用启动时把未完成任务标记为 interrupted：不假装任务仍在后台运行。
pub fn mark_active_as_interrupted(conn: &Connection) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT id FROM downloads
         WHERE status IN ('waiting','extracting','downloading','merging')",
    )?;
    let ids: Vec<String> = stmt
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<rusqlite::Result<_>>()?;
    drop(stmt);

    if !ids.is_empty() {
        conn.execute(
            "UPDATE downloads SET status = 'interrupted', speed = NULL, eta = NULL
             WHERE status IN ('waiting','extracting','downloading','merging')",
            [],
        )?;
    }
    Ok(ids)
}

pub fn delete(conn: &Connection, id: &str) -> rusqlite::Result<usize> {
    let removed = conn.execute("DELETE FROM downloads WHERE id = ?1", params![id])?;
    conn.execute(
        "DELETE FROM download_logs WHERE download_id = ?1",
        params![id],
    )?;
    Ok(removed)
}

pub fn append_log(
    conn: &Connection,
    download_id: &str,
    level: &str,
    message: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO download_logs (download_id, level, message, created_at)
         VALUES (?1, ?2, ?3, ?4)",
        params![download_id, level, message, now_iso()],
    )?;
    Ok(())
}

pub fn list_logs(
    conn: &Connection,
    download_id: &str,
    limit: i64,
) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT message FROM download_logs WHERE download_id = ?1
         ORDER BY id DESC LIMIT ?2",
    )?;
    let mut rows: Vec<String> = stmt
        .query_map(params![download_id, limit], |row| row.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    rows.reverse();
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::Database;

    fn sample_task(id: &str, status: TaskStatus) -> DownloadTask {
        DownloadTask {
            id: id.to_string(),
            url: "https://example.com/v/1".to_string(),
            title: format!("示例视频 {id}"),
            thumbnail: None,
            site: Some("Example".to_string()),
            status,
            kind: TaskKind::Video,
            selector: Some("137+140".to_string()),
            format_label: Some("1080p MP4".to_string()),
            container: Some("mp4".to_string()),
            audio_format: None,
            output_dir: Some("/tmp/VideoFlow".to_string()),
            output_path: None,
            total_bytes: Some(1024),
            downloaded_bytes: 0,
            speed: None,
            eta: None,
            created_at: now_iso(),
            started_at: None,
            completed_at: None,
            error_message: None,
        }
    }

    #[test]
    fn insert_and_get_task() {
        let db = Database::open_in_memory().expect("db");
        let task = sample_task("t1", TaskStatus::Waiting);
        db.with_conn(|conn| insert(conn, &task)).expect("insert");

        let loaded = db
            .with_conn(|conn| get(conn, "t1"))
            .expect("get")
            .expect("found");
        assert_eq!(loaded.title, task.title);
        assert_eq!(loaded.status, TaskStatus::Waiting);
        assert_eq!(loaded.kind, TaskKind::Video);
    }

    #[test]
    fn active_tasks_become_interrupted_on_restart() {
        let db = Database::open_in_memory().expect("db");
        db.with_conn(|conn| {
            insert(conn, &sample_task("a", TaskStatus::Downloading))?;
            insert(conn, &sample_task("b", TaskStatus::Completed))?;
            insert(conn, &sample_task("c", TaskStatus::Waiting))
        })
        .expect("seed");

        let ids = db
            .with_conn(mark_active_as_interrupted)
            .expect("mark interrupted");
        assert_eq!(ids.len(), 2);

        let a = db.with_conn(|conn| get(conn, "a")).unwrap().unwrap();
        assert_eq!(a.status, TaskStatus::Interrupted);
        let b = db.with_conn(|conn| get(conn, "b")).unwrap().unwrap();
        assert_eq!(b.status, TaskStatus::Completed);
    }

    #[test]
    fn history_search_filters_by_title() {
        let db = Database::open_in_memory().expect("db");
        db.with_conn(|conn| {
            let mut done = sample_task("h1", TaskStatus::Completed);
            done.title = "旅行 Vlog".to_string();
            insert(conn, &done)?;
            let mut failed = sample_task("h2", TaskStatus::Failed);
            failed.title = "编程教程".to_string();
            insert(conn, &failed)
        })
        .expect("seed");

        let found = db
            .with_conn(|conn| list_history(conn, Some("旅行"), 20, 0))
            .expect("history");
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].id, "h1");

        let all = db
            .with_conn(|conn| list_history(conn, None, 20, 0))
            .expect("history all");
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn delete_task_removes_row() {
        let db = Database::open_in_memory().expect("db");
        db.with_conn(|conn| insert(conn, &sample_task("d1", TaskStatus::Completed)))
            .expect("insert");
        let removed = db.with_conn(|conn| delete(conn, "d1")).expect("delete");
        assert_eq!(removed, 1);
        assert!(db.with_conn(|conn| get(conn, "d1")).unwrap().is_none());
    }
}
