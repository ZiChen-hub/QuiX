//! Wintun L3 TUN 设备封装（数据面）。
//!
//! 收发裸 IP 包（与 Android VpnService 相同形态），ZT 虚拟网络帧本就是 L3 载荷，
//! 无需以太网头转换。创建适配器与配置 IP 需要管理员权限（W4 通过 UAC manifest 保证）。

use std::net::{IpAddr, Ipv4Addr};
use std::path::PathBuf;
use std::sync::Arc;

use wintun::Adapter;

/// 适配器名（netsh 与 TUN 名一致）
pub const ADAPTER_NAME: &str = "QuiX";

pub struct TunDevice {
    /// 配置到适配器上的 IPv4 地址
    pub ip: Ipv4Addr,
    _adapter: Arc<Adapter>,
    session: Arc<wintun::Session>,
}

impl TunDevice {
    /// 创建（或复用）QuiX TUN 适配器并配置地址/MTU
    pub fn create(ip: Ipv4Addr, prefix: u8, mtu: u32) -> anyhow::Result<Self> {
        let wintun = load_wintun_dll()?;
        // 优先复用残留的同名适配器（如上次进程异常退出），否则创建
        let adapter = match Adapter::open(&wintun, ADAPTER_NAME) {
            Ok(a) => a,
            Err(_) => Adapter::create(&wintun, ADAPTER_NAME, "QuiX ZeroTier", None).map_err(|e| {
                anyhow::anyhow!("创建 Wintun 适配器失败（是否以管理员运行？）: {e}")
            })?,
        };

        // 配置 IP/子网掩码（内部调用 netsh，需要管理员权限）
        let mask = prefix_to_mask(prefix);
        adapter
            .set_network_addresses_tuple(IpAddr::V4(ip), IpAddr::V4(mask), None)
            .map_err(|e| anyhow::anyhow!("配置 TUN 地址 {ip}/{prefix} 失败: {e}"))?;
        adapter
            .set_mtu(mtu as usize)
            .map_err(|e| anyhow::anyhow!("设置 TUN MTU {mtu} 失败: {e}"))?;

        let session: Arc<wintun::Session> = adapter
            .start_session(wintun::MAX_RING_CAPACITY)
            .map_err(|e| anyhow::anyhow!("启动 Wintun 会话失败: {e}"))?
            .into();
        tracing::info!("Wintun TUN 已就绪: {ADAPTER_NAME} {ip}/{prefix} mtu={mtu}");
        Ok(Self {
            ip,
            _adapter: adapter,
            session,
        })
    }

    /// 向 TUN 写入一个裸 IP 包（交给 Windows 协议栈）
    pub fn send_ip_packet(&self, data: &[u8]) {
        if data.is_empty() || data.len() > u16::MAX as usize {
            return;
        }
        if let Ok(mut pkt) = self.session.allocate_send_packet(data.len() as u16) {
            pkt.bytes_mut().copy_from_slice(data);
            self.session.send_packet(pkt);
        }
    }

    /// 非阻塞读取一个 IP 包；None 表示当前无数据
    pub fn try_receive(&self) -> Result<Option<Vec<u8>>, wintun::Error> {
        Ok(self
            .session
            .try_receive()?
            .map(|p| p.bytes().to_vec()))
    }
}

/// 按优先级加载 wintun.dll：exe 同目录（Flutter bundle）→ exe 上级目录（cargo
/// profile，examples 场景）→ 当前目录 → PATH 搜索
fn load_wintun_dll() -> anyhow::Result<wintun::Wintun> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("wintun.dll"));
            candidates.push(dir.join("../wintun.dll"));
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd.join("wintun.dll"));
    }
    let mut last_err = None;
    for cand in &candidates {
        if cand.exists() {
            match unsafe { wintun::load_from_path(cand) } {
                Ok(w) => return Ok(w),
                Err(e) => {
                    last_err = Some(format!("加载 {} 失败: {e}", cand.display()));
                    tracing::warn!("{last_err:?}");
                }
            }
        }
    }
    // 回退：按标准 DLL 搜索顺序（PATH）查找
    match unsafe { wintun::load() } {
        Ok(w) => Ok(w),
        Err(e) => Err(anyhow::anyhow!(
            "加载 wintun.dll 失败（已尝试 {} 个候选路径）: {e}; {last_err:?}",
            candidates.len()
        )),
    }
}

/// 前缀长度 → IPv4 子网掩码（如 /24 → 255.255.255.0）
fn prefix_to_mask(prefix: u8) -> Ipv4Addr {
    let p = prefix.min(32);
    let mask = if p == 0 {
        0
    } else {
        u32::MAX << (32 - p)
    };
    Ipv4Addr::from(mask)
}
