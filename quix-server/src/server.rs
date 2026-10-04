//! QUIC 服务器：构建端点、监听端口、接受连接

use crate::config::Config;
use crate::session::SessionManager;
use crate::stream_handler;
use anyhow::{Context, Result};
use quinn::{Connection, Endpoint, SendStream, ServerConfig};
use sha2::{Digest, Sha256};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use tracing::{error, info};

/// 客户端条目：连接 + 设备类型 + 控制流发送端槽
struct ClientEntry {
    connection: Connection,
    device_type: Arc<std::sync::Mutex<Option<String>>>,
    /// 控制流发送端（客户端注册控制流后写入），
    /// 供「断开所有连接」时向客户端推送断开通知
    control_send: Arc<Mutex<Option<SendStream>>>,
}

/// 连接注册表：跟踪所有活跃客户端连接
type ConnectionRegistry = Arc<Mutex<Vec<ClientEntry>>>;

/// 生成 QUIC 服务端配置（使用自签名证书，仅用于加密传输，不做身份验证）
/// 返回 (ServerConfig, 证书指纹)，指纹为证书 DER 的 SHA256，供客户端身份校验
fn build_server_config() -> Result<(ServerConfig, String)> {
    // 生成自签名证书（客户端跳过证书校验，故无需真实 CA）
    let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_string()])
        .context("生成自签名证书失败")?;
    let cert_der = cert.serialize_der().context("序列化证书失败")?;
    // 证书指纹 = SHA256(cert_der)，用于客户端 TLS pinning
    let fingerprint = Sha256::digest(&cert_der)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let key_der = cert.serialize_private_key_der();
    let cert = rustls::Certificate(cert_der);
    let key = rustls::PrivateKey(key_der);
    let mut server_config = ServerConfig::with_single_cert(vec![cert], key)
        .context("创建 QUIC 服务端配置失败")?;
    // 禁用空闲超时，避免客户端选文件期间连接被断开
    let mut transport = quinn::TransportConfig::default();
    transport.max_idle_timeout(None);
    server_config.transport_config(Arc::new(transport));
    Ok((server_config, fingerprint))
}

/// 服务端句柄：持有端点、注册表等，供 FFI/CLI 控制
pub struct ServerHandle {
    pub ip: String,
    pub port: u16,
    pub code: String,
    pub cert_fingerprint: String,
    endpoint: Endpoint,
    registry: ConnectionRegistry,
    session_manager: Arc<SessionManager>,
    _task: tokio::task::JoinHandle<()>,
    /// 关闭信号：通知后台会话清扫任务退出
    shutdown: Arc<tokio::sync::Notify>,
}

impl ServerHandle {
    /// 启动服务端：绑定端点、启动 mDNS、后台运行接受循环，立即返回句柄
    pub async fn start(config: Config, code: String, ip: String) -> Result<Self> {
        // 监听所有网卡的指定端口
        let addr: SocketAddr = format!("0.0.0.0:{}", config.port).parse()?;
        let (server_config, cert_fingerprint) = build_server_config()?;
        let endpoint = Endpoint::server(server_config, addr)?;
        info!("QUIC 服务端已启动: {}", endpoint.local_addr()?);

        // mDNS 广播（daemon 需随服务端存活，移入后台任务持有）
        let mdns = crate::discovery::start_mdns(config.enable_mdns, config.port, &code)?;

        // 全局会话管理器（跨连接共享），从接收目录加载历史接收记录（支持持久化）
        let records_path = std::path::Path::new(&config.output_dir).join("received_records.json");
        let session_manager = Arc::new(SessionManager::load(&records_path).await);

        // 连接注册表
        let registry: ConnectionRegistry = Arc::new(Mutex::new(Vec::new()));

        // R5：后台周期性清扫空闲超时的未完成会话（文件+sidecar+映射）；
        // 收到 shutdown 通知时随服务退出，避免遗留孤儿任务
        let shutdown: Arc<tokio::sync::Notify> = Arc::new(tokio::sync::Notify::new());
        let reaper_sm = session_manager.clone();
        let reaper_exit = shutdown.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = tokio::time::sleep(std::time::Duration::from_secs(60)) => {
                        reaper_sm
                            .purge_stale(std::time::Duration::from_secs(3600))
                            .await;
                    }
                    _ = reaper_exit.notified() => break,
                }
            }
        });

        // 后台任务：运行接受连接主循环
        let task = {
            let endpoint = endpoint.clone();
            let config = config.clone();
            let session_manager = session_manager.clone();
            let registry = registry.clone();
            let code = code.clone();
            tokio::spawn(async move {
                let _mdns = mdns;
                accept_loop(endpoint, config, session_manager, registry, code).await;
            })
        };

        Ok(Self {
            ip,
            port: config.port,
            code,
            cert_fingerprint,
            endpoint,
            registry,
            session_manager,
            _task: task,
            shutdown,
        })
    }

    /// 当前已连接设备数
    pub fn connected_count(&self) -> usize {
        self.registry.lock().expect("连接注册表锁被毒化").len()
    }

    /// 已连接设备类型列表（"mobile" / "desktop"）
    pub fn device_types(&self) -> Vec<String> {
        let guard = self.registry.lock().expect("连接注册表锁被毒化");
        guard
            .iter()
            .filter_map(|e| e.device_type.lock().expect("设备类型锁被毒化").clone())
            .collect()
    }

    /// 已完成接收的文件记录快照（最新的在前）
    pub fn received_files(&self) -> Vec<crate::session::ReceivedFileRecord> {
        self.session_manager.received_files()
    }

    /// 接收统计：(文件数, 总大小字节, 总用时毫秒)
    pub fn stats(&self) -> (u64, u64, u64) {
        self.session_manager.stats()
    }

    /// 剪贴板文本历史快照（新在前）
    pub fn text_history(&self) -> Vec<crate::session::ReceivedText> {
        self.session_manager.text_history()
    }

    /// 清空接收记录与文本历史
    pub async fn clear_records(&self) -> anyhow::Result<()> {
        self.session_manager.clear_records().await
    }

    /// 断开所有已连接的客户端（服务保持运行，可继续接受新连接）。
    /// 先通过控制流向客户端推送断开通知（客户端据此区分「对端主动断开」
    /// 与网络故障，不触发自动重连），随后关闭连接。
    pub async fn disconnect_all(&self) {
        // R7：锁内仅克隆需要的控制流槽与连接到 Vec 后立即释放，
        // 避免持有注册表锁跨 await（含 sleep）阻塞 accept 注册/移除
        let targets: Vec<(Arc<Mutex<Option<SendStream>>>, Connection)> = {
            let guard = self.registry.lock().expect("连接注册表锁被毒化");
            guard
                .iter()
                .map(|e| (e.control_send.clone(), e.connection.clone()))
                .collect()
        };
        for (control_send, connection) in targets {
            // 尽力推送断开通知（客户端未注册控制流时跳过）。
            // 此处仅锁单个控制流槽（4 字节写入），不涉及注册表
            if let Ok(mut opt) = control_send.lock() {
                if let Some(send) = opt.as_mut() {
                    let _ = send
                        .write_all(&crate::stream_handler::MessageType::DisconnectNotify
                            .as_u32()
                            .to_be_bytes())
                        .await;
                }
            }
            // 留出通知的传输时间，再关闭连接
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            connection.close(0u32.into(), b"disconnected by server");
        }
    }

    /// 停止服务端
    pub fn stop(&self) {
        self.shutdown.notify_waiters(); // 通知后台清扫任务退出
        self.endpoint.close(0u32.into(), b"server stopped");
        self._task.abort();
    }
}

/// 接受连接主循环（在后台任务中运行）
async fn accept_loop(
    endpoint: Endpoint,
    config: Config,
    session_manager: Arc<SessionManager>,
    registry: ConnectionRegistry,
    code: String,
) {
    while let Some(incoming) = endpoint.accept().await {
        info!("收到新连接: {}", incoming.remote_address());
        let config = config.clone();
        let session_manager = session_manager.clone();
        let code = code.clone();
        let registry = registry.clone();
        // 每个连接在独立任务中处理，互不阻塞
        tokio::spawn(async move {
            match incoming.await {
                Ok(connection) => {
                    let stable_id = connection.stable_id();
                    let device_type: Arc<std::sync::Mutex<Option<String>>> =
                        Arc::new(std::sync::Mutex::new(None));
                    // 控制流发送端槽（注册表与流处理器共享）
                    let control_send: Arc<Mutex<Option<SendStream>>> =
                        Arc::new(Mutex::new(None));
                    // 注册连接
                    {
                        let mut guard = registry.lock().expect("连接注册表锁被毒化");
                        guard.push(ClientEntry {
                            connection: connection.clone(),
                            device_type: device_type.clone(),
                            control_send: control_send.clone(),
                        });
                    }
                    if let Err(e) = stream_handler::handle_connection(
                        connection.clone(),
                        config,
                        session_manager,
                        code,
                        device_type,
                        control_send,
                    )
                    .await
                    {
                        error!("连接处理失败: {:#}", e);
                    }
                    // 连接结束，移除注册
                    if let Ok(mut guard) = registry.lock() {
                        guard.retain(|e| e.connection.stable_id() != stable_id);
                    }
                }
                Err(e) => error!("建立连接失败: {:#}", e),
            }
        });
    }
}
