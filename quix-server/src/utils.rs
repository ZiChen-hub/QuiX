//! 辅助函数：获取 IP、主机名、格式化字节数

/// 获取本机局域网 IP 地址
/// 优先枚举物理网卡（跳过 ZeroTier/Wintun 等持久化虚拟网卡，避免对端连到
/// 无节点服务的虚拟地址而超时）；失败时回退到首个非环回地址
pub fn get_local_ip() -> Option<String> {
    crate::localip::local_physical_ipv4()
        .or_else(|| local_ip_address::local_ip().ok().map(|ip| ip.to_string()))
}

/// 获取本机主机名
pub fn get_hostname() -> String {
    hostname::get()
        .map(|h| h.to_string_lossy().to_string())
        .unwrap_or_else(|_| "unknown".to_string())
}

/// 将字节数格式化为人类可读字符串
pub fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    if bytes < 1024 {
        return format!("{} {}", bytes, UNITS[0]);
    }
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    format!("{:.1} {}", value, UNITS[unit])
}

/// 生成 8 位字母数字连接码（去掉易混淆的 0/O/1/I/l，基于时间种子 + xorshift）
pub fn generate_connection_code() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    // 32 个字符，去掉了 0、O、1、I、l 等易混淆字符
    const CHARSET: &[u8] = b"23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let mut x = seed | 1;
    let mut out = String::with_capacity(8);
    for _ in 0..8 {
        // 简单 xorshift 伪随机
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        out.push(CHARSET[(x % CHARSET.len() as u64) as usize] as char);
    }
    out
}
