//! 传输会话管理：会话数据结构与位图管理

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncSeekExt, AsyncWriteExt};

/// 单个文件的传输会话
pub struct TransferSession {
    /// 文件唯一标识
    pub file_id: String,
    /// 文件名
    pub file_name: String,
    /// 文件总大小（字节）
    pub file_size: u64,
    /// 分块大小（字节）
    pub chunk_size: u64,
    /// 总块数
    pub total_chunks: u64,
    /// 完整文件的 BLAKE3 哈希
    pub hash: String,
    /// 已接收块位图（true 表示该块已收到）
    pub received_chunks: Arc<Mutex<Vec<bool>>>,
    /// 文件句柄（Mutex 包裹，seek+write_all 实现并发安全随机写入）
    pub file_handle: Option<Arc<tokio::sync::Mutex<tokio::fs::File>>>,
    /// 文件保存路径
    pub file_path: PathBuf,
    /// 完成标志（确保多流并发下校验只执行一次）
    pub completed: AtomicBool,
    /// 会话创建时间
    pub created_at: Instant,
    /// 最近一次有进展（收到块）的时间，用于 TTL 回收未完成会话
    last_progress: Arc<Mutex<Instant>>,
    /// 持久化锁（避免多流并发写 sidecar 文件冲突）
    persist_lock: tokio::sync::Mutex<()>,
}

impl TransferSession {
    /// 创建新的传输会话
    pub fn new(
        file_id: String,
        file_name: String,
        file_size: u64,
        chunk_size: u64,
        hash: String,
        file_handle: Option<Arc<tokio::sync::Mutex<tokio::fs::File>>>,
        file_path: PathBuf,
    ) -> Self {
        // 总块数按向上取整计算
        let total_chunks = if file_size == 0 {
            0
        } else {
            (file_size + chunk_size - 1) / chunk_size
        };
        Self {
            file_id,
            file_name,
            file_size,
            chunk_size,
            total_chunks,
            hash,
            received_chunks: Arc::new(Mutex::new(vec![false; total_chunks as usize])),
            file_handle,
            file_path,
            completed: AtomicBool::new(false),
            created_at: Instant::now(),
            last_progress: Arc::new(Mutex::new(Instant::now())),
            persist_lock: tokio::sync::Mutex::new(()),
        }
    }

    /// 更新最近进展时间（收到数据块时调用）
    pub fn touch(&self) {
        if let Ok(mut t) = self.last_progress.lock() {
            *t = Instant::now();
        }
    }

    /// 最近进展时间
    pub fn last_progress(&self) -> Instant {
        self.last_progress
            .lock()
            .map(|t| *t)
            .unwrap_or_else(|_| Instant::now())
    }

    /// 标记某块为已接收
    pub fn mark_received(&self, chunk_index: u64) {
        if let Ok(mut bitmap) = self.received_chunks.lock() {
            if let Some(flag) = bitmap.get_mut(chunk_index as usize) {
                *flag = true;
            }
        }
    }

    /// 获取已接收位图快照（0/1 数组，用于 JSON 序列化）
    pub fn bitmap_snapshot(&self) -> Vec<u8> {
        self.received_chunks
            .lock()
            .map(|b| b.iter().map(|&x| x as u8).collect())
            .unwrap_or_default()
    }

    /// 已接收块数量
    pub fn received_count(&self) -> u64 {
        self.received_chunks
            .lock()
            .map(|b| b.iter().filter(|&&x| x).count() as u64)
            .unwrap_or(0)
    }

    /// 是否所有块都已接收
    pub fn is_complete(&self) -> bool {
        self.received_chunks
            .lock()
            .map(|b| b.iter().all(|&x| x))
            .unwrap_or(false)
    }

    /// 尝试标记为已完成，返回 true 表示本次是首次标记（用于确保校验只执行一次）
    pub fn try_mark_completed(&self) -> bool {
        self.completed
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
    }

    /// 随机写入数据块并标记已接收（Mutex + seek + write_all 并发安全写入）
    pub async fn write_chunk(&self, chunk_index: u64, data: &[u8]) -> Result<()> {
        let handle = self.file_handle.as_ref().context("文件句柄未初始化")?;
        let offset = chunk_index * self.chunk_size;
        // 加锁后定位偏移并写入
        let mut file = handle.lock().await;
        file.seek(std::io::SeekFrom::Start(offset))
            .await
            .context("定位写入偏移失败")?;
        file.write_all(data).await.context("写入数据块失败")?;
        drop(file);
        self.mark_received(chunk_index);
        self.touch();
        Ok(())
    }

    /// 会话对应的 sidecar 持久化文件路径
    pub fn sidecar_path(&self) -> PathBuf {
        PathBuf::from(format!("{}.quix.session", self.file_path.display()))
    }

    /// 序列化为可持久化的状态
    pub fn to_state(&self) -> SessionState {
        SessionState {
            file_id: self.file_id.clone(),
            file_name: self.file_name.clone(),
            file_size: self.file_size,
            chunk_size: self.chunk_size,
            total_chunks: self.total_chunks,
            hash: self.hash.clone(),
            file_path: self.file_path.display().to_string(),
            received: self.bitmap_snapshot(),
        }
    }

    /// 从持久化状态重建会话（重新挂接文件句柄）
    pub fn from_state(state: SessionState, file_handle: Arc<tokio::sync::Mutex<tokio::fs::File>>) -> Self {
        let received: Vec<bool> = state.received.iter().map(|&x| x != 0).collect();
        Self {
            file_id: state.file_id,
            file_name: state.file_name,
            file_size: state.file_size,
            chunk_size: state.chunk_size,
            total_chunks: state.total_chunks,
            hash: state.hash,
            received_chunks: Arc::new(Mutex::new(received)),
            file_handle: Some(file_handle),
            file_path: PathBuf::from(state.file_path),
            completed: AtomicBool::new(false),
            created_at: Instant::now(),
            last_progress: Arc::new(Mutex::new(Instant::now())),
            persist_lock: tokio::sync::Mutex::new(()),
        }
    }

    /// 持久化会话状态到 sidecar 文件（加锁避免多流并发写冲突）
    pub async fn persist(&self) -> Result<()> {
        let _guard = self.persist_lock.lock().await;
        let json = serde_json::to_vec(&self.to_state()).context("序列化会话状态失败")?;
        tokio::fs::write(self.sidecar_path(), json)
            .await
            .context("写入会话状态失败")?;
        Ok(())
    }

    /// 删除 sidecar 文件（传输完成或失败时清理）
    pub async fn delete_sidecar(&self) -> Result<()> {
        let path = self.sidecar_path();
        if path.exists() {
            tokio::fs::remove_file(path).await.context("删除会话状态失败")?;
        }
        Ok(())
    }
}

/// 会话持久化状态（与 sidecar 文件 JSON 对应）
#[derive(Debug, Serialize, Deserialize)]
pub struct SessionState {
    pub file_id: String,
    pub file_name: String,
    pub file_size: u64,
    pub chunk_size: u64,
    pub total_chunks: u64,
    pub hash: String,
    pub file_path: String,
    /// 已接收块位图（0/1）
    pub received: Vec<u8>,
}

/// 已完成接收的文件记录（供服务端统计与接收记录展示）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReceivedFileRecord {
    /// 文件名
    pub file_name: String,
    /// 文件大小（字节）
    pub file_size: u64,
    /// 接收完成时间（Unix 毫秒）
    pub received_at_ms: u64,
    /// 传输耗时（毫秒）
    pub duration_ms: u64,
    /// 来源设备标识（如「手机 192.168.1.105」）
    pub source: String,
}

/// 收到的剪贴板文本条目（供文本历史展示与持久化）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReceivedText {
    /// 文本内容
    pub text: String,
    /// 接收时间（Unix 毫秒）
    pub received_at_ms: u64,
}

/// 全局会话管理器：维护 file_id -> TransferSession 映射
pub struct SessionManager {
    sessions: Arc<Mutex<HashMap<String, Arc<TransferSession>>>>,
    /// 已完成接收的文件记录（追加，供统计/记录展示）
    received_files: Arc<Mutex<Vec<ReceivedFileRecord>>>,
    /// 接收记录持久化文件路径（None 表示不持久化，仅内存态）
    records_path: Option<PathBuf>,
    /// 剪贴板文本历史（新在前）
    text_history: Arc<Mutex<Vec<ReceivedText>>>,
    /// 文本历史持久化文件路径（None 表示不持久化）
    text_history_path: Option<PathBuf>,
    /// 文本历史持久化锁（串行化对 text_history.json 的写入，避免多个 spawn 并发写导致乱序/覆盖）
    text_persist_lock: Arc<tokio::sync::Mutex<()>>,
}

impl SessionManager {
    /// 创建空的会话管理器（内存态，不持久化）
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            received_files: Arc::new(Mutex::new(Vec::new())),
            records_path: None,
            text_history: Arc::new(Mutex::new(Vec::new())),
            text_history_path: None,
            text_persist_lock: Arc::new(tokio::sync::Mutex::new(())),
        }
    }

    /// 从记录文件加载历史接收记录（文件不存在则返回空列表）
    pub async fn load(records_path: &std::path::Path) -> Self {
        let records = if records_path.exists() {
            tokio::fs::read(records_path)
                .await
                .ok()
                .and_then(|b| serde_json::from_slice::<Vec<ReceivedFileRecord>>(&b).ok())
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        // 文本历史持久化在同目录下的 text_history.json
        let text_history_path = records_path
            .parent()
            .map(|p| p.join("text_history.json"));
        let texts = match &text_history_path {
            Some(p) if p.exists() => tokio::fs::read(p)
                .await
                .ok()
                .and_then(|b| serde_json::from_slice::<Vec<ReceivedText>>(&b).ok())
                .unwrap_or_default(),
            _ => Vec::new(),
        };
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            received_files: Arc::new(Mutex::new(records)),
            records_path: Some(records_path.to_path_buf()),
            text_history: Arc::new(Mutex::new(texts)),
            text_history_path,
            text_persist_lock: Arc::new(tokio::sync::Mutex::new(())),
        }
    }

    /// 插入新会话
    pub fn insert(&self, session: Arc<TransferSession>) {
        if let Ok(mut map) = self.sessions.lock() {
            map.insert(session.file_id.clone(), session);
        }
    }

    /// 获取会话（返回共享引用）
    pub fn get(&self, file_id: &str) -> Option<Arc<TransferSession>> {
        self.sessions.lock().ok()?.get(file_id).cloned()
    }

    /// 移除并返回会话
    pub fn remove(&self, file_id: &str) -> Option<Arc<TransferSession>> {
        self.sessions.lock().ok()?.remove(file_id)
    }

    /// 活跃（未完成）会话数量上限，防止只发元数据不断累积耗尽内存/磁盘
    pub const MAX_ACTIVE_SESSIONS: usize = 1000;

    /// 是否还能接受新会话（未达数量上限）
    pub fn can_accept_new(&self) -> bool {
        self.sessions
            .lock()
            .map(|m| m.len() < Self::MAX_ACTIVE_SESSIONS)
            .unwrap_or(false)
    }

    /// 清理空闲超过 ttl 的未完成会话：删除数据文件、sidecar 与映射。
    /// 锁内仅做判断与收集，删除在锁外进行，避免持锁跨 await
    pub async fn purge_stale(&self, ttl: Duration) {
        let stale: Vec<Arc<TransferSession>> = {
            let map = match self.sessions.lock() {
                Ok(g) => g,
                Err(_) => return,
            };
            map.values()
                .filter(|s| {
                    !s.completed.load(Ordering::SeqCst) && s.last_progress().elapsed() > ttl
                })
                .cloned()
                .collect()
        };
        for s in stale {
            // 删除前再次确认未完成（收集后可能刚好完成）
            if s.completed.load(Ordering::SeqCst) {
                continue;
            }
            let _ = tokio::fs::remove_file(&s.file_path).await;
            let _ = s.delete_sidecar().await;
            self.remove(&s.file_id);
        }
    }

    /// 记录一条已完成的接收文件（追加到内存并尽力持久化）
    pub async fn record_completed(
        &self,
        file_name: String,
        file_size: u64,
        duration: Duration,
        source: String,
    ) {
        let received_at_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        if let Ok(mut list) = self.received_files.lock() {
            list.push(ReceivedFileRecord {
                file_name,
                file_size,
                received_at_ms,
                duration_ms: duration.as_millis() as u64,
                source,
            });
        }

        // 尽力持久化（失败不影响传输主流程）
        if let Some(path) = &self.records_path {
            let snapshot = self
                .received_files
                .lock()
                .map(|l| l.clone())
                .unwrap_or_default();
            if let Ok(json) = serde_json::to_vec(&snapshot) {
                let _ = tokio::fs::write(path, json).await;
            }
        }
    }

    /// 已完成接收的文件记录快照（按时间倒序，最新的在前）
    pub fn received_files(&self) -> Vec<ReceivedFileRecord> {
        let mut list = self
            .received_files
            .lock()
            .map(|l| l.clone())
            .unwrap_or_default();
        list.reverse();
        list
    }

    /// 接收统计：(文件数, 总大小字节, 总用时毫秒)
    pub fn stats(&self) -> (u64, u64, u64) {
        let list = self
            .received_files
            .lock()
            .map(|l| l.clone())
            .unwrap_or_default();
        let count = list.len() as u64;
        let total_size = list.iter().map(|r| r.file_size).sum();
        let total_duration = list.iter().map(|r| r.duration_ms).sum();
        (count, total_size, total_duration)
    }

    /// 记录收到的剪贴板文本（追加到历史头部，最多保留 200 条，并尽力持久化）
    pub fn record_text(&self, text: String) {
        let ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        let entry = ReceivedText {
            text,
            received_at_ms: ms,
        };
        if let Ok(mut list) = self.text_history.lock() {
            list.insert(0, entry);
            if list.len() > 200 {
                list.truncate(200);
            }
        }
        // 异步持久化（fire-and-forget，失败不影响主流程）
        // 加锁后读取「最新」快照再写入，避免多个 spawn 并发写同一文件导致乱序/覆盖
        if let Some(path) = &self.text_history_path {
            let path = path.clone();
            let history = self.text_history.clone();
            let lock = self.text_persist_lock.clone();
            tokio::spawn(async move {
                let _guard = lock.lock().await;
                let snapshot = history.lock().map(|l| l.clone()).unwrap_or_default();
                if let Ok(json) = serde_json::to_vec(&snapshot) {
                    let _ = tokio::fs::write(path, json).await;
                }
            });
        }
    }

    /// 剪贴板文本历史快照（新在前）
    pub fn text_history(&self) -> Vec<ReceivedText> {
        self.text_history
            .lock()
            .map(|l| l.clone())
            .unwrap_or_default()
    }

    /// 清空接收记录与文本历史（内存 + 持久化文件）
    pub async fn clear_records(&self) -> Result<()> {
        if let Ok(mut list) = self.received_files.lock() {
            list.clear();
        }
        if let Ok(mut list) = self.text_history.lock() {
            list.clear();
        }
        if let Some(path) = &self.records_path {
            if path.exists() {
                let _ = tokio::fs::remove_file(path).await;
            }
        }
        if let Some(path) = &self.text_history_path {
            if path.exists() {
                let _ = tokio::fs::remove_file(path).await;
            }
        }
        Ok(())
    }
}

impl Default for SessionManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// record_text 应把新文本追加到历史头部（新在前）
    #[test]
    fn record_text_inserts_at_head() {
        let mgr = SessionManager::new();
        mgr.record_text("first".to_string());
        std::thread::sleep(Duration::from_millis(5)); // 确保时间戳可区分
        mgr.record_text("second".to_string());

        let history = mgr.text_history();
        assert_eq!(history.len(), 2);
        assert_eq!(history[0].text, "second");
        assert_eq!(history[1].text, "first");
        // 新在前，时间戳应单调不增（首条不早于次条）
        assert!(history[0].received_at_ms >= history[1].received_at_ms);
    }

    /// 超过 200 条时截断到最新 200 条
    #[test]
    fn record_text_truncates_at_200() {
        let mgr = SessionManager::new();
        for i in 0..201 {
            mgr.record_text(format!("msg-{i}"));
        }
        let history = mgr.text_history();
        assert_eq!(history.len(), 200);
        assert_eq!(history[0].text, "msg-200"); // 最新一条
        assert_eq!(history[199].text, "msg-1"); // 最旧一条 msg-0 被丢弃
    }

    /// ReceivedText 序列化/反序列化往返
    #[test]
    fn received_text_serialization_roundtrip() {
        let entry = ReceivedText {
            text: "你好，剪贴板".to_string(),
            received_at_ms: 1_700_000_000_000,
        };
        let json = serde_json::to_string(&entry).unwrap();
        let back: ReceivedText = serde_json::from_str(&json).unwrap();
        assert_eq!(back.text, entry.text);
        assert_eq!(back.received_at_ms, entry.received_at_ms);
    }

    /// 文本历史持久化：record_text 写入 text_history.json，重启后 load 可恢复
    #[tokio::test]
    async fn text_history_persists_and_reloads() {
        let dir = std::env::temp_dir().join(format!(
            "quix_text_history_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let records_path = dir.join("received_records.json");

        // 第一次加载：记录两条文本
        let mgr = SessionManager::load(&records_path).await;
        mgr.record_text("持久化文本 A".to_string());
        mgr.record_text("持久化文本 B".to_string());
        // 等待 fire-and-forget 异步持久化完成
        tokio::time::sleep(Duration::from_millis(100)).await;

        let text_path = dir.join("text_history.json");
        assert!(text_path.exists(), "text_history.json 应被写入");

        // 第二次加载：验证文本历史被恢复（新在前）
        let reloaded = SessionManager::load(&records_path).await;
        let history = reloaded.text_history();
        assert_eq!(history.len(), 2);
        assert_eq!(history[0].text, "持久化文本 B");
        assert_eq!(history[1].text, "持久化文本 A");

        // 清理临时目录
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 空历史（无 text_history.json）时 load 应返回空列表
    #[tokio::test]
    async fn load_without_text_file_yields_empty() {
        let dir = std::env::temp_dir().join(format!(
            "quix_text_history_empty_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let records_path = dir.join("received_records.json");

        let mgr = SessionManager::load(&records_path).await;
        assert!(mgr.text_history().is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
