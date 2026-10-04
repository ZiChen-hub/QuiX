//! 跨网络自动组网：IPv6 直连 → UPnP 端口映射 → ZeroTier 组网
//! 说明：igd-next 与 local-ip-address 的精确 API 以实际版本为准。

#[cfg(not(windows))]
use crate::zerotier_manager::ZeroTierManager;
use anyhow::Result;
use std::time::Duration;
use tracing::{info, warn};

/// UPnP 端口映射租约时长（秒）：不使用 0（永久），避免在路由器上遗留垃圾映射
const UPNP_LEASE_SECONDS: u32 = 3600;
/// 租约续期间隔（秒）：在租约到期前刷新
const UPNP_RENEW_INTERVAL_SECS: u64 = 1800;

/// 已建立的 UPnP 端口映射（网关句柄 + 端口 + 续租任务），供服务停止时清理
type TokioGateway = igd_next::aio::Gateway<igd_next::aio::tokio::Tokio>;
static UPNP_MAPPING: std::sync::Mutex<Option<(std::sync::Arc<TokioGateway>, u16, tokio::task::JoinHandle<()>)>> =
    std::sync::Mutex::new(None);

/// 检测本机全局 IPv6 地址（过滤回环与链路本地 fe80::/10）
pub fn get_global_ipv6() -> Option<String> {
    use std::net::IpAddr;
    let ip = match local_ip_address::local_ipv6().ok()? {
        IpAddr::V6(v6) => v6,
        IpAddr::V4(_) => return None,
    };
    if ip.is_loopback() || (ip.segments()[0] & 0xffc0) == 0xfe80 {
        return None;
    }
    Some(ip.to_string())
}

/// 尝试 UPnP 端口映射，返回公网 IP（成功映射则返回 Some，否则 None）
pub async fn try_upnp_mapping(port: u16) -> Result<Option<String>> {
    // 搜索网关（无网关则返回 None）
    let gateway = match igd_next::aio::tokio::search_gateway(Default::default()).await {
        Ok(g) => g,
        Err(_) => return Ok(None),
    };

    // 获取公网 IP
    let external_ip = match gateway.get_external_ip().await {
        Ok(ip) => ip.to_string(),
        Err(_) => return Ok(None),
    };

    // 使用本机局域网 IP 作为内部地址，尝试添加 UDP 端口映射（QUIC 使用 UDP）
    let local_ip = crate::utils::get_local_ip().unwrap_or_else(|| "127.0.0.1".to_string());
    let local_addr: std::net::SocketAddr = format!("{}:{}", local_ip, port).parse()?;
    let gateway = std::sync::Arc::new(gateway);
    if gateway
        .add_port(
            igd_next::PortMappingProtocol::UDP,
            port,
            local_addr,
            UPNP_LEASE_SECONDS,
            "quix",
        )
        .await
        .is_err()
    {
        warn!("UPnP 端口映射添加失败，回退");
        return Ok(None);
    }

    // 续租任务：周期性用相同参数刷新租约，防止 1 小时后映射被路由器自动删除
    let renew_gw = gateway.clone();
    let renew_handle = tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(UPNP_RENEW_INTERVAL_SECS)).await;
            if renew_gw
                .add_port(
                    igd_next::PortMappingProtocol::UDP,
                    port,
                    local_addr,
                    UPNP_LEASE_SECONDS,
                    "quix",
                )
                .await
                .is_err()
            {
                warn!("UPnP 租约续租失败");
            }
        }
    });

    // 保存映射，供停止服务时清理（abort 续租 + 删除映射）
    if let Ok(mut slot) = UPNP_MAPPING.lock() {
        *slot = Some((gateway, port, renew_handle));
    }

    Ok(Some(external_ip))
}

/// 清理已建立的 UPnP 端口映射（服务停止时调用）
pub async fn cleanup_upnp() {
    let mapping = UPNP_MAPPING
        .lock()
        .ok()
        .and_then(|mut slot| slot.take());
    if let Some((gateway, port, renew_handle)) = mapping {
        renew_handle.abort();
        match gateway
            .remove_port(igd_next::PortMappingProtocol::UDP, port)
            .await
        {
            Ok(()) => info!("已删除 UPnP 端口映射: {}", port),
            Err(_) => warn!("UPnP 端口映射删除失败: {}", port),
        }
    }
}

/// 建立跨网络通道（IPv6 → UPnP → ZeroTier），返回可达地址
pub async fn establish_cross_network(
    port: u16,
    zerotier_network_id: &str,
) -> Result<Option<String>> {
    // 1. IPv6 直连
    if let Some(ipv6) = get_global_ipv6() {
        info!("检测到全局 IPv6 地址: {}", ipv6);
        return Ok(Some(ipv6));
    }

    // 2. UPnP 端口映射
    if let Some(public_ip) = try_upnp_mapping(port).await? {
        info!("UPnP 端口映射成功，公网 IP: {}", public_ip);
        return Ok(Some(public_ip));
    }

    // 3. ZeroTier 组网兜底
    if zerotier_network_id.is_empty() {
        warn!("未配置 zerotier_network_id，跳过 ZeroTier 组网");
        return Ok(None);
    }
    info!("正在加入 ZeroTier 网络 {} ...", zerotier_network_id);
    let ip = join_zerotier(zerotier_network_id).await?;
    info!("ZeroTier 组网成功，虚拟 IP: {}", ip);
    Ok(Some(ip))
}

/// 加入 ZeroTier 网络并等待分配 IP。
/// Windows：使用内嵌 ZeroTier 核心（无需安装客户端，需管理员权限）；
/// 其他平台：调用 zerotier-cli。
pub async fn join_zerotier(network_id: &str) -> Result<String> {
    #[cfg(windows)]
    {
        let nwid = network_id.to_string();
        // ztembed::join 内部 condvar 阻塞等待授权，放到阻塞线程池执行
        let result = tokio::task::spawn_blocking(move || {
            crate::ztembed::join(&nwid, std::time::Duration::from_secs(180))
        })
        .await
        .map_err(|e| anyhow::anyhow!("ZeroTier 组网任务失败: {e}"))?;
        match result {
            Ok(r) => Ok(r.ip),
            // ztembed 的错误信息已含 my.zerotier.com 授权提示，直接透传
            Err(e) => Err(anyhow::anyhow!("{e:#}")),
        }
    }
    #[cfg(not(windows))]
    {
        let zt = ZeroTierManager::new();
        if !zt.is_installed() {
            info!("正在安装 ZeroTier...");
            zt.install().await?;
        }
        zt.join_and_get_ip(network_id, Duration::from_secs(30))
            .await
    }
}

/// 停止内嵌 ZeroTier（服务停止时调用；Windows 专用）
#[cfg(windows)]
pub fn stop_zerotier_embedded() {
    crate::ztembed::leave();
}
