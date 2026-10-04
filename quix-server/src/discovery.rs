//! mDNS 局域网设备发现（广播服务，附带连接码 TXT 记录）

use crate::utils;
use anyhow::Result;
use mdns_sd::{ServiceDaemon, ServiceInfo};
use std::collections::HashMap;

/// 启动 mDNS 服务广播。
/// 返回需要保持存活的 ServiceDaemon；TXT 记录中附带连接码与端口，供发现的设备直接连接。
pub fn start_mdns(enabled: bool, port: u16, code: &str) -> Result<Option<ServiceDaemon>> {
    if !enabled {
        return Ok(None);
    }

    let daemon = ServiceDaemon::new()?;
    let hostname = utils::get_hostname();
    let ip = utils::get_local_ip().unwrap_or_else(|| "127.0.0.1".to_string());

    // TXT 记录：附带连接码与端口
    let mut properties = HashMap::new();
    properties.insert("code".to_string(), code.to_string());
    properties.insert("port".to_string(), port.to_string());

    // 广播服务类型 _quix._udp.local.，供局域网内其他 QuiX 设备发现
    let service_info = ServiceInfo::new(
        "_quix._udp.local.",
        "quix",
        &hostname,
        &ip,
        port,
        Some(properties),
    )?;
    daemon.register(service_info)?;

    Ok(Some(daemon))
}
