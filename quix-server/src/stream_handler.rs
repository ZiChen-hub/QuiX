//! 处理 QUIC 连接与双向流：元数据、数据块、双向推送、断点续传

use crate::config::Config;
use crate::file_io;
use crate::session::{SessionManager, SessionState, TransferSession};
use anyhow::{Context, Result};
use quinn::{Connection, RecvStream, SendStream};
use serde::Deserialize;
use std::sync::Arc;
use tokio::io::AsyncReadExt;
use tokio::sync::Semaphore;
use tracing::{info, warn};

/// 字符串（file_id/文件名/连接码/文本等）最大长度，防御未鉴权触发的内存分配 DoS
const MAX_STRING_LEN: usize = 1024 * 1024; // 1MB
/// 元数据 JSON 最大长度
const MAX_METADATA_LEN: usize = 1024 * 1024; // 1MB

/// 分块大小下限（1 KiB）：防止极小块导致位图过大
const MIN_CHUNK_SIZE: u64 = 1024;
/// 分块大小上限（64 MiB）
const MAX_CHUNK_SIZE: u64 = 64 * 1024 * 1024;
/// 单文件总块数上限：防止位图/会话内存无限分配
const MAX_TOTAL_CHUNKS: u64 = 200_000;
/// 单文件大小上限（1 TiB）
const MAX_FILE_SIZE: u64 = 1024 * 1024 * 1024 * 1024;

/// 消息类型定义（与开发案协议完全一致）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum MessageType {
    /// 元数据（首次建立会话）
    Metadata = 1,
    /// 数据块（传输中）
    ChunkData = 2,
    /// 断点续传请求
    ResumeRequest = 5,
    /// 断点续传响应（位图）
    ResumeResponse = 6,
    /// 确认
    Ack = 7,
    /// 客户端→服务端「控制流注册」标记（连接存活监测）
    ControlChannel = 8,
    /// 连接鉴权：客户端连接后立即发送连接码，服务端校验
    Hello = 10,
    /// 剪贴板文本消息（客户端 → 服务端）
    TextMessage = 11,
    /// 主动测速（客户端 → 服务端）：发送端写测试数据，服务端丢弃并回 ACK
    SpeedTest = 12,
    /// 断开通知（双向）：客户端→服务端表示主动退出；服务端→客户端表示主动踢出
    DisconnectNotify = 13,
    /// 完整性校验结果（服务端→客户端，经控制流）：1 字节，1=通过，0=失败
    VerifyResult = 14,
}

impl MessageType {
    /// 从 u32 还原消息类型
    pub fn from_u32(v: u32) -> Option<Self> {
        match v {
            1 => Some(Self::Metadata),
            2 => Some(Self::ChunkData),
            5 => Some(Self::ResumeRequest),
            6 => Some(Self::ResumeResponse),
            7 => Some(Self::Ack),
            8 => Some(Self::ControlChannel),
            10 => Some(Self::Hello),
            11 => Some(Self::TextMessage),
            12 => Some(Self::SpeedTest),
            13 => Some(Self::DisconnectNotify),
            14 => Some(Self::VerifyResult),
            _ => None,
        }
    }

    /// 消息类型转为 u32
    pub fn as_u32(self) -> u32 {
        self as u32
    }
}

/// 元数据消息体（客户端 → 服务端）
#[derive(Debug, Deserialize)]
struct MetadataPayload {
    file_id: String,
    file_name: String,
    file_size: u64,
    chunk_size: u64,
    #[allow(dead_code)]
    total_chunks: u64,
    hash: String,
    /// 6 位连接码（阶段五：用于连接鉴权）
    code: String,
}

/// 元数据响应中「拒绝」的哨兵值（表示连接码错误等拒绝场景）
const REJECT_SENTINEL: u64 = u64::MAX;

/// 处理单个 QUIC 连接：循环接受双向流
/// [control_send_slot] 为控制流发送端的存放槽（由服务端注册表共享，
/// 供「断开所有连接」时向客户端推送断开通知）
pub async fn handle_connection(
    connection: Connection,
    config: Config,
    session_manager: Arc<SessionManager>,
    connection_code: String,
    device_type: Arc<std::sync::Mutex<Option<String>>>,
    control_send_slot: Arc<std::sync::Mutex<Option<SendStream>>>,
) -> Result<()> {
    info!("连接已建立，开始处理数据流");

    // 连接鉴权状态：收到 Hello 并通过校验后才允许后续数据流
    let mut authenticated = false;

    // 每连接的并发流闸门（R10：让 config.max_concurrent_streams 真正生效）。
    // 下限取 1，避免配置为 0 时所有流永久等待
    let limiter = Arc::new(Semaphore::new(config.max_concurrent_streams.max(1) as usize));

    // R8：Hello 看门狗——connection_timeout 秒内未通过鉴权即关闭连接，
    // 防止只完成 QUIC 握手却不发 Hello 的连接永久驻留耗尽资源
    let wd_conn = connection.clone();
    let wd_secs = config.connection_timeout.max(1);
    let auth_watchdog = tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(wd_secs)).await;
        wd_conn.close(0u32.into(), b"auth timeout");
    });

    // 循环接受双向流
    while let Ok((mut send, recv)) = connection.accept_bi().await {
        let mut recv = recv;
        // 先读消息类型，区分控制流与普通数据流
        let msg_type = match read_message_type(&mut recv).await {
            Ok(t) => t,
            Err(e) => {
                warn!("读取消息类型失败: {:#}", e);
                continue;
            }
        };

        match msg_type {
            Some(MessageType::Hello) => {
                // 连接鉴权：校验连接码与设备类型
                match handle_hello(&mut send, &mut recv, &connection_code).await {
                    Ok((true, dt)) => {
                        authenticated = true;
                        auth_watchdog.abort(); // 鉴权通过，取消 Hello 看门狗
                        *device_type.lock().expect("设备类型锁被毒化") = Some(dt);
                        info!("客户端鉴权通过");
                    }
                    Ok((false, _)) => {
                        warn!("连接码校验失败，拒绝连接");
                        let _ = connection.close(0u32.into(), b"invalid code");
                        return Ok(());
                    }
                    Err(e) => {
                        warn!("处理鉴权失败: {:#}", e);
                    }
                }
            }
            Some(MessageType::ControlChannel) => {
                if !authenticated {
                    warn!("未鉴权的连接尝试注册控制流，忽略");
                    continue;
                }
                // 控制流：发送端存入共享槽（供主动断开时推送通知），
                // 任务保持 recv 端读取以感知客户端消息，连接关闭后随任务退出
                *control_send_slot
                    .lock()
                    .expect("控制流槽锁被毒化") = Some(send);
                let conn = connection.clone();
                let slot = control_send_slot.clone();
                tokio::spawn(async move {
                    let mut recv = recv;
                    tokio::select! {
                        _ = conn.closed() => {}
                        _ = recv.read_u8() => {}
                    }
                    // 任务退出（连接关闭/客户端有写入）时清空槽
                    if let Ok(mut guard) = slot.lock() {
                        *guard = None;
                    }
                });
                info!("客户端已注册控制流");
            }
            Some(MessageType::DisconnectNotify) => {
                // 客户端主动断开：立即关闭连接（注册表随之移除，计数同步下降）
                info!("客户端请求断开连接");
                connection.close(0u32.into(), b"client disconnect");
                return Ok(());
            }
            Some(t) => {
                if !authenticated {
                    continue;
                }
                let config = config.clone();
                let session_manager = session_manager.clone();
                let connection_code = connection_code.clone();
                // 来源设备标识：设备类型 + 对端 IP（供接收记录展示）
                let dt = device_type
                    .lock()
                    .expect("设备类型锁被毒化")
                    .clone()
                    .unwrap_or_else(|| "desktop".to_string());
                let label = if dt == "mobile" { "手机" } else { "电脑" };
                let source = format!("{} {}", label, connection.remote_address().ip());
                let limiter = limiter.clone();
                let control_send_slot = control_send_slot.clone();
                tokio::spawn(async move {
                    // 持有并发许可至整条流处理结束（超出 max_concurrent_streams 时排队）
                    let _permit = limiter.acquire_owned().await.expect("信号量已关闭");
                    if let Err(e) = handle_stream_with_type(
                        t,
                        send,
                        recv,
                        config,
                        session_manager,
                        connection_code,
                        source,
                        control_send_slot,
                    )
                    .await
                    {
                        warn!("流处理失败: {:#}", e);
                    }
                });
            }
            None => {
                // 空流，忽略
            }
        }
    }
    Ok(())
}

/// 处理单个双向流：按已读消息类型分发
async fn handle_stream_with_type(
    msg_type: MessageType,
    mut send: SendStream,
    mut recv: RecvStream,
    config: Config,
    session_manager: Arc<SessionManager>,
    connection_code: String,
    source: String,
    control_send_slot: Arc<std::sync::Mutex<Option<SendStream>>>,
) -> Result<()> {
    match msg_type {
        MessageType::Metadata => {
            // 元数据流：处理一次会话建立（含连接码校验）
            handle_metadata(
                &mut send,
                &mut recv,
                &config,
                &session_manager,
                &connection_code,
                &source,
                &control_send_slot,
            )
            .await?;
        }
        MessageType::ResumeRequest => {
            // 断点续传查询：返回已接收位图
            handle_resume_request(&mut send, &mut recv, &session_manager, &connection_code).await?;
        }
        MessageType::ChunkData => {
            // 数据流：先处理首块，再循环处理后续块
            handle_chunk_message(&mut send, &mut recv, &session_manager, &source, &control_send_slot)
                .await?;
            loop {
                match read_message_type(&mut recv).await? {
                    Some(MessageType::ChunkData) => {
                        handle_chunk_message(
                            &mut send,
                            &mut recv,
                            &session_manager,
                            &source,
                            &control_send_slot,
                        )
                        .await?;
                    }
                    Some(other) => {
                        warn!("数据流中出现非数据块消息: {:?}", other);
                        break;
                    }
                    None => break, // 客户端已结束发送
                }
            }
            // 通知客户端：服务端已处理完所有块
            send.finish().await.context("结束数据流失败")?;
        }
        MessageType::TextMessage => {
            // 剪贴板文本：读取文本并记录，回一个 1 字节确认
            handle_text_message(&mut send, &mut recv, &session_manager).await?;
        }
        MessageType::SpeedTest => {
            // 主动测速：读取并丢弃测试数据，回 1 字节确认
            handle_speed_test(&mut send, &mut recv).await?;
        }
        other => {
            warn!("未知消息类型: {:?}", other);
        }
    }
    Ok(())
}

/// 读取 4 字节消息类型，返回 None 表示流已关闭/重置
async fn read_message_type(recv: &mut RecvStream) -> Result<Option<MessageType>> {
    let mut buf = [0u8; 4];
    let mut read = 0usize;
    while read < buf.len() {
        let n = recv.read(&mut buf[read..]).await.context("读取消息类型失败")?;
        match n {
            // Some(0) 为干净 EOF，None 为流被重置
            Some(0) | None => {
                if read == 0 {
                    return Ok(None);
                }
                anyhow::bail!("消息类型不完整");
            }
            Some(n) => read += n,
        }
    }
    Ok(MessageType::from_u32(u32::from_be_bytes(buf)))
}

/// 读取长度前缀字符串（4 字节长度 + 字节）
async fn read_string(recv: &mut RecvStream) -> Result<String> {
    let mut len_buf = [0u8; 4];
    recv.read_exact(&mut len_buf)
        .await
        .context("读取字符串长度失败")?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_STRING_LEN {
        anyhow::bail!("字符串长度超限: {len}");
    }
    let mut buf = vec![0u8; len];
    recv.read_exact(&mut buf).await.context("读取字符串失败")?;
    String::from_utf8(buf).context("字符串编码无效")
}

/// 处理连接鉴权（MessageType 10）：读取连接码与设备类型，返回是否通过
async fn handle_hello(
    send: &mut SendStream,
    recv: &mut RecvStream,
    connection_code: &str,
) -> Result<(bool, String)> {
    let code = read_string(recv).await?;
    // device_type 可选（旧客户端可能不发送，默认 desktop）
    let device_type = read_string(recv)
        .await
        .unwrap_or_else(|_| "desktop".to_string());
    let ok = code == connection_code;
    // 响应 1 字节：1=通过，0=拒绝
    send.write_all(&[ok as u8])
        .await
        .context("写入鉴权响应失败")?;
    Ok((ok, device_type))
}

/// 通过控制流向客户端推送完整性校验结果（MessageType 14 + 1 字节）。
/// 控制流尚未注册或写入失败时静默跳过
async fn send_verify_result(
    slot: &Arc<std::sync::Mutex<Option<SendStream>>>,
    ok: bool,
) {
    // 锁内仅 take 出 SendStream 后立即释放：std MutexGuard 不是 Send，
    // 不能持有跨 await，否则所在 spawn 任务编译失败
    let mut stream = match slot.lock() {
        Ok(mut g) => g.take(),
        Err(_) => return,
    };
    if let Some(send) = stream.as_mut() {
        let failed = send
            .write_all(&MessageType::VerifyResult.as_u32().to_be_bytes())
            .await
            .is_err();
        if !failed {
            let _ = send.write_all(&[ok as u8]).await;
        }
    }
    // 放回槽（若期间槽已被重新占用则以现有为准）
    if let Ok(mut g) = slot.lock() {
        if g.is_none() {
            *g = stream;
        }
    }
}

/// 处理剪贴板文本消息（MessageType 11）：读取文本并记录，回 1 字节确认
async fn handle_text_message(
    send: &mut SendStream,
    recv: &mut RecvStream,
    session_manager: &Arc<SessionManager>,
) -> Result<()> {
    let text = read_string(recv).await?;
    session_manager.record_text(text.clone());
    info!("收到剪贴板文本 ({} 字符)", text.chars().count());
    send.write_all(&[1u8])
        .await
        .context("写入文本确认失败")?;
    send.finish().await.context("结束文本流失败")?;
    Ok(())
}

/// 测速数据量上限（防御恶意/异常值导致的无限读取与内存占用）
const MAX_SPEED_TEST_BYTES: u64 = 256 * 1024 * 1024;

/// 处理主动测速消息（MessageType 12）：读取并丢弃测试数据，回 1 字节确认
async fn handle_speed_test(send: &mut SendStream, recv: &mut RecvStream) -> Result<()> {
    // 测试数据总长度（8 字节）
    let mut len_buf = [0u8; 8];
    recv.read_exact(&mut len_buf)
        .await
        .context("读取测速长度失败")?;
    let total = u64::from_be_bytes(len_buf);
    if total > MAX_SPEED_TEST_BYTES {
        anyhow::bail!("测速数据量异常: {total} 字节（超过上限）");
    }
    let total = total as usize;

    // 循环读取并丢弃
    let mut remaining = total;
    let mut buf = vec![0u8; 1024 * 1024]; // 1MB 缓冲
    while remaining > 0 {
        let want = remaining.min(buf.len());
        let n = recv
            .read(&mut buf[..want])
            .await
            .context("读取测速数据失败")?;
        match n {
            Some(0) | None => break, // 连接关闭
            Some(n) => remaining -= n,
        }
    }
    info!("测速完成，接收 {} 字节", total - remaining);

    send.write_all(&[1u8])
        .await
        .context("写入测速确认失败")?;
    send.finish().await.context("结束测速流失败")?;
    Ok(())
}

/// 从 sidecar 文件加载持久化的会话状态（不存在则返回 None）
async fn load_session_state(sidecar: &std::path::Path) -> Result<Option<SessionState>> {
    if !sidecar.exists() {
        return Ok(None);
    }
    let bytes = tokio::fs::read(sidecar)
        .await
        .context("读取会话状态失败")?;
    let state: SessionState = serde_json::from_slice(&bytes).context("解析会话状态失败")?;
    Ok(Some(state))
}

/// 处理元数据消息：创建会话、预分配文件、返回位图
async fn handle_metadata(
    send: &mut SendStream,
    recv: &mut RecvStream,
    config: &Config,
    session_manager: &Arc<SessionManager>,
    connection_code: &str,
    source: &str,
    control_send_slot: &Arc<std::sync::Mutex<Option<SendStream>>>,
) -> Result<()> {
    // JSON 长度（8 字节）
    let mut len_buf = [0u8; 8];
    recv.read_exact(&mut len_buf)
        .await
        .context("读取元数据长度失败")?;
    let json_len = u64::from_be_bytes(len_buf) as usize;
    if json_len > MAX_METADATA_LEN {
        anyhow::bail!("元数据长度超限: {json_len}");
    }

    // JSON 数据
    let mut json_buf = vec![0u8; json_len];
    recv.read_exact(&mut json_buf)
        .await
        .context("读取元数据失败")?;
    let payload: MetadataPayload =
        serde_json::from_slice(&json_buf).context("解析元数据 JSON 失败")?;

    // 连接码校验（防止未授权连接）
    if payload.code != connection_code {
        warn!("连接码校验失败: 收到 {}，期望 {}", payload.code, connection_code);
        // 返回拒绝哨兵 + 空位图
        send.write_all(&REJECT_SENTINEL.to_be_bytes())
            .await
            .context("写入拒绝响应失败")?;
        let empty: Vec<u8> = vec![];
        send.write_all(&serde_json::to_vec(&empty).context("序列化空位图失败")?)
            .await
            .context("写入空位图失败")?;
        send.finish().await.context("结束元数据流失败")?;
        return Ok(());
    }

    // R1：对数值字段做边界校验（连接码已通过）。
    // 防止 chunk_size=0 除零、极小 chunk 致位图 OOM abort、文件大小溢出
    if payload.chunk_size < MIN_CHUNK_SIZE || payload.chunk_size > MAX_CHUNK_SIZE {
        anyhow::bail!(
            "分块大小超出允许范围 [{}B, {}B]: {}",
            MIN_CHUNK_SIZE,
            MAX_CHUNK_SIZE,
            payload.chunk_size
        );
    }
    if payload.file_size > MAX_FILE_SIZE {
        anyhow::bail!("文件大小超过上限: {} 字节", payload.file_size);
    }
    if payload.file_size > 0 {
        // checked 向上取整：避免 file_size + chunk_size - 1 溢出
        let total = payload
            .file_size
            .checked_add(payload.chunk_size - 1)
            .and_then(|s| s.checked_div(payload.chunk_size))
            .context("计算总块数失败")?;
        if total > MAX_TOTAL_CHUNKS {
            anyhow::bail!("总块数超过上限: {total}");
        }
    }

    // 断点续传：若该文件已有会话，直接返回当前已接收位图，不重建文件
    if let Some(session) = session_manager.get(&payload.file_id) {
        let received_count = session.received_count();
        let bitmap = session.bitmap_snapshot();
        let bitmap_json = serde_json::to_vec(&bitmap).context("序列化位图失败")?;
        send.write_all(&received_count.to_be_bytes())
            .await
            .context("写入已接收块数量失败")?;
        send.write_all(&bitmap_json)
            .await
            .context("写入位图失败")?;
        send.finish().await.context("结束元数据流失败")?;
        info!(
            "续传会话: {} 已收 {}/{} 块",
            payload.file_name, received_count, session.total_chunks
        );
        return Ok(());
    }

    // 确保接收目录存在
    std::fs::create_dir_all(&config.output_dir).context("创建接收目录失败")?;
    // 路径安全：拒绝含 `..` 或绝对路径的文件名，防止逃逸接收目录
    if payload.file_name.split(['/', '\\']).any(|c| c == "..")
        || std::path::Path::new(&payload.file_name).is_absolute()
    {
        anyhow::bail!("非法文件名（含路径逃逸）");
    }
    let file_path = std::path::Path::new(&config.output_dir).join(&payload.file_name);
    // 支持文件夹/子目录传输：确保父目录存在
    if let Some(parent) = file_path.parent() {
        std::fs::create_dir_all(parent).context("创建父目录失败")?;
    }

    // 断点续传：尝试从磁盘恢复会话（跨服务端重启）
    let sidecar = std::path::PathBuf::from(format!("{}.quix.session", file_path.display()));
    if let Some(state) = load_session_state(&sidecar).await? {
        // 重新打开文件（不截断，保留已接收块）
        let file = tokio::fs::OpenOptions::new()
            .write(true)
            .open(&file_path)
            .await
            .context("打开文件失败")?;
        let session = Arc::new(TransferSession::from_state(
            state,
            Arc::new(tokio::sync::Mutex::new(file)),
        ));
        session_manager.insert(session.clone());

        let received_count = session.received_count();
        let bitmap = session.bitmap_snapshot();
        let bitmap_json = serde_json::to_vec(&bitmap).context("序列化位图失败")?;
        send.write_all(&received_count.to_be_bytes()).await?;
        send.write_all(&bitmap_json).await?;
        send.finish().await?;
        info!(
            "从磁盘恢复会话: {} 已收 {}/{} 块",
            payload.file_name, received_count, session.total_chunks
        );
        return Ok(());
    }

    // R5：全新会话前检查活跃会话数量上限（续传/磁盘恢复不受限）
    if !session_manager.can_accept_new() {
        anyhow::bail!("活跃会话已达上限，请等待部分传输完成或稍后重试");
    }

    // 预分配并打开文件
    let file = file_io::create_and_preallocate(&file_path, payload.file_size).await?;

    // 创建会话
    let session = Arc::new(TransferSession::new(
        payload.file_id.clone(),
        payload.file_name.clone(),
        payload.file_size,
        payload.chunk_size,
        payload.hash,
        Some(Arc::new(tokio::sync::Mutex::new(file))),
        file_path,
    ));
    session_manager.insert(session.clone());
    // 持久化会话状态（跨服务端重启续传）
    session.persist().await?;

    info!(
        "已建立传输会话: {} ({} 块)",
        payload.file_name, session.total_chunks
    );

    // 响应：已接收块数量 + 位图 JSON
    let received_count = session.received_count();
    let bitmap = session.bitmap_snapshot();
    let bitmap_json = serde_json::to_vec(&bitmap).context("序列化位图失败")?;

    send.write_all(&received_count.to_be_bytes())
        .await
        .context("写入已接收块数量失败")?;
    send.write_all(&bitmap_json)
        .await
        .context("写入位图失败")?;
    send.finish().await.context("结束元数据流失败")?;

    // 空文件：不会产生任何 ChunkData，需在此完成校验、记录与清理，
    // 否则服务端接收统计缺失、sidecar 残留、会话驻留内存
    if session.total_chunks == 0 {
        let ok = file_io::verify_hash(&session.file_path, &session.hash)
            .await
            .unwrap_or(false);
        info!(
            "空文件 {} 传输完成，BLAKE3 校验: {}",
            session.file_name,
            if ok { "通过" } else { "失败" }
        );
        // R4：经控制流回传校验结果，客户端据此判定成功/失败
        send_verify_result(control_send_slot, ok).await;
        if ok {
            session_manager
                .record_completed(
                    session.file_name.clone(),
                    session.file_size,
                    session.created_at.elapsed(),
                    source.to_string(),
                )
                .await;
            // 校验通过才清理 sidecar 与会话；失败保留以便续传
            session.delete_sidecar().await?;
            session_manager.remove(&payload.file_id);
        }
    }

    Ok(())
}

/// 处理断点续传查询（MessageType 5）并返回位图（MessageType 6）
async fn handle_resume_request(
    send: &mut SendStream,
    recv: &mut RecvStream,
    session_manager: &Arc<SessionManager>,
    connection_code: &str,
) -> Result<()> {
    // 文件 ID 长度（4 字节）
    let mut id_len_buf = [0u8; 4];
    recv.read_exact(&mut id_len_buf)
        .await
        .context("读取文件ID长度失败")?;
    let id_len = u32::from_be_bytes(id_len_buf) as usize;
    if id_len > MAX_STRING_LEN {
        anyhow::bail!("文件ID长度超限: {id_len}");
    }

    // 文件 ID
    let mut id_buf = vec![0u8; id_len];
    recv.read_exact(&mut id_buf)
        .await
        .context("读取文件ID失败")?;
    let file_id = String::from_utf8(id_buf).context("文件ID编码无效")?;

    // 连接码长度 + 连接码（续传请求同样校验连接码）
    let mut code_len_buf = [0u8; 4];
    recv.read_exact(&mut code_len_buf)
        .await
        .context("读取连接码长度失败")?;
    let code_len = u32::from_be_bytes(code_len_buf) as usize;
    if code_len > MAX_STRING_LEN {
        anyhow::bail!("连接码长度超限: {code_len}");
    }
    let mut code_buf = vec![0u8; code_len];
    recv.read_exact(&mut code_buf)
        .await
        .context("读取连接码失败")?;
    let code = String::from_utf8(code_buf).context("连接码编码无效")?;

    // 连接码校验（防止未授权查询续传位图）
    if code != connection_code {
        warn!("续传请求连接码校验失败");
        send.write_all(&MessageType::ResumeResponse.as_u32().to_be_bytes())
            .await?;
        let empty: Vec<u8> = vec![];
        send.write_all(&serde_json::to_vec(&empty).context("序列化空位图失败")?)
            .await?;
        send.finish().await?;
        return Ok(());
    }

    // 查找会话，返回已接收位图（不存在则返回空位图）
    let bitmap = session_manager
        .get(&file_id)
        .map(|s| s.bitmap_snapshot())
        .unwrap_or_default();
    let bitmap_json = serde_json::to_vec(&bitmap).context("序列化位图失败")?;

    // 响应：MessageType 6 + 位图 JSON
    send.write_all(&MessageType::ResumeResponse.as_u32().to_be_bytes())
        .await
        .context("写入续传响应类型失败")?;
    send.write_all(&bitmap_json)
        .await
        .context("写入位图失败")?;
    send.finish().await.context("结束续传响应流失败")?;
    Ok(())
}

/// 处理单个数据块消息（消息类型字节已被消费）
async fn handle_chunk_message(
    send: &mut SendStream,
    recv: &mut RecvStream,
    session_manager: &Arc<SessionManager>,
    source: &str,
    control_send_slot: &Arc<std::sync::Mutex<Option<SendStream>>>,
) -> Result<()> {
    // 文件 ID 长度（4 字节）
    let mut id_len_buf = [0u8; 4];
    recv.read_exact(&mut id_len_buf)
        .await
        .context("读取文件ID长度失败")?;
    let id_len = u32::from_be_bytes(id_len_buf) as usize;
    if id_len > MAX_STRING_LEN {
        anyhow::bail!("文件ID长度超限: {id_len}");
    }

    // 文件 ID
    let mut id_buf = vec![0u8; id_len];
    recv.read_exact(&mut id_buf)
        .await
        .context("读取文件ID失败")?;
    let file_id = String::from_utf8(id_buf).context("文件ID编码无效")?;

    // 块索引（8 字节）
    let mut index_buf = [0u8; 8];
    recv.read_exact(&mut index_buf)
        .await
        .context("读取块索引失败")?;
    let chunk_index = u64::from_be_bytes(index_buf);

    // 数据长度（8 字节）
    let mut data_len_buf = [0u8; 8];
    recv.read_exact(&mut data_len_buf)
        .await
        .context("读取数据长度失败")?;
    let data_len = u64::from_be_bytes(data_len_buf) as usize;

    // 先获取会话并校验块索引/数据长度（防御越界写与内存分配 DoS）
    let session = session_manager.get(&file_id).context("找不到对应会话")?;
    if chunk_index >= session.total_chunks {
        anyhow::bail!("块索引越界: {chunk_index} >= {}", session.total_chunks);
    }
    if data_len > session.chunk_size as usize {
        anyhow::bail!("数据块长度超限: {data_len} > {}", session.chunk_size);
    }
    // R9：校验 偏移+长度 不越过声明的 file_size，防止末块写过 EOF 扩展文件
    let end = (chunk_index as u64)
        .checked_mul(session.chunk_size)
        .and_then(|off| off.checked_add(data_len as u64));
    match end {
        Some(e) if e <= session.file_size => {}
        _ => anyhow::bail!(
            "数据块越界: index={chunk_index}, len={data_len}, file_size={}",
            session.file_size
        ),
    }

    // 数据
    let mut data = vec![0u8; data_len];
    recv.read_exact(&mut data)
        .await
        .context("读取数据块失败")?;

    // 写入文件
    session.write_chunk(chunk_index, &data).await?;
    // 持久化已接收位图（支持跨重启续传）
    session.persist().await?;

    // 发送 ACK：块索引 + 累计已收块数
    let received_count = session.received_count();
    send.write_all(&chunk_index.to_be_bytes())
        .await
        .context("写入ACK块索引失败")?;
    send.write_all(&received_count.to_be_bytes())
        .await
        .context("写入ACK计数失败")?;

    // 全部块接收完成后，进行完整性校验（并发下仅执行一次）
    if session.is_complete() && session.try_mark_completed() {
        let ok = file_io::verify_hash(&session.file_path, &session.hash)
            .await
            .unwrap_or(false);
        info!(
            "文件 {} 传输完成，BLAKE3 校验: {}",
            session.file_name,
            if ok { "通过" } else { "失败" }
        );
        // R4：经控制流回传校验结果，客户端不再仅凭 ACK+finish 误判成功
        send_verify_result(control_send_slot, ok).await;
        if ok {
            // 校验通过：计入接收统计与记录，并清理 sidecar、移除会话
            session_manager
                .record_completed(
                    session.file_name.clone(),
                    session.file_size,
                    session.created_at.elapsed(),
                    source.to_string(),
                )
                .await;
            session.delete_sidecar().await?;
            session_manager.remove(&file_id);
        } else {
            // 校验失败：保留 sidecar 与会话，客户端可断点续传重传缺失/错误块
            warn!("文件 {} 校验失败，已保留会话以便续传", session.file_name);
        }
    }
    Ok(())
}
