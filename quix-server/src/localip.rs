//! 本机物理局域网 IPv4 发现：枚举网卡时跳过虚拟网卡。
//!
//! 背景：Wintun 适配器在系统中持久存在，服务停止（leave）后「QuiX」虚拟网卡
//! 仍保留上一次配置的 IP（如 10.61.x.x）。若 `get_local_ip` 误选该虚拟网卡，
//! 对端在局域网连接该地址时实际没有任何节点提供服务，会一直超时。
//! 因此需要显式枚举物理网卡（以太网/Wi-Fi），排除 ZeroTier/VPN/虚拟机等虚拟网卡。

pub fn local_physical_ipv4() -> Option<String> {
    #[cfg(windows)]
    {
        windows::local_ipv4()
    }
    #[cfg(not(windows))]
    {
        unix::local_ipv4()
    }
}

/// 判断网卡名称/描述是否属于已知虚拟网卡（ASCII 小写子串匹配）
fn is_virtual_name(lowercase_name: &str) -> bool {
    const VIRTUAL_KEYWORDS: [&str; 16] = [
        "quix",
        "zerotier",
        "wintun",
        "virtualbox",
        "vmware",
        "hyper-v",
        "vethernet",
        "wsl",
        "tap-windows",
        "openvpn",
        "vpn",
        "loopback",
        "bluetooth",
        "docker",
        "tailscale",
        "wireguard",
    ];
    VIRTUAL_KEYWORDS
        .iter()
        .any(|k| lowercase_name.contains(k))
}

// ==================== Windows 实现 ====================

#[cfg(windows)]
mod windows {
    use super::is_virtual_name;
    use std::net::Ipv4Addr;
    use windows_sys::Win32::NetworkManagement::IpHelper as iphelper;
    use windows_sys::Win32::Networking::WinSock as sock;

    /// IfOperStatusUp 的数值（OperStatus 字段为 i32）
    const IF_OPER_STATUS_UP: i32 = 1;
    const ERROR_SUCCESS: u32 = 0;
    const ERROR_BUFFER_OVERFLOW: u32 = 111;

    pub fn local_ipv4() -> Option<String> {
        unsafe {
            let flags = iphelper::GAA_FLAG_SKIP_ANYCAST
                | iphelper::GAA_FLAG_SKIP_MULTICAST
                | iphelper::GAA_FLAG_SKIP_DNS_SERVER;

            // 自适应缓冲：首次 16KB，溢出时按系统返回长度重试（最多 8 次）
            let mut buf_len: u32 = 16 * 1024;
            let mut buffer: Vec<u8> = Vec::new();
            let mut success = false;
            for _ in 0..8 {
                buffer = vec![0u8; buf_len as usize];
                let ret = iphelper::GetAdaptersAddresses(
                    sock::AF_INET as u32,
                    flags,
                    std::ptr::null(),
                    buffer.as_mut_ptr() as *mut _,
                    &mut buf_len,
                );
                if ret == ERROR_SUCCESS {
                    success = true;
                    break;
                }
                if ret != ERROR_BUFFER_OVERFLOW {
                    // 其他错误（无网卡等）直接放弃
                    return None;
                }
            }
            if !success {
                return None;
            }

            let head = buffer.as_mut_ptr() as *mut iphelper::IP_ADAPTER_ADDRESSES_LH;
            let mut fallback: Option<String> = None;
            let mut adapter = head;
            while !adapter.is_null() {
                let a = &*adapter;
                if a.OperStatus == IF_OPER_STATUS_UP {
                    let desc = pwstr_to_string(a.Description).to_lowercase();
                    let fname = pwstr_to_string(a.FriendlyName).to_lowercase();
                    let virtual_by_name =
                        is_virtual_name(&desc) || is_virtual_name(&fname);
                    // 以太网(6)/Wi-Fi(71) 为物理网卡；回环(24)/隧道(131) 排除
                    let physical_type = a.IfType == iphelper::IF_TYPE_ETHERNET_CSMACD
                        || a.IfType == iphelper::IF_TYPE_IEEE80211;
                    let excluded = virtual_by_name
                        || a.IfType == iphelper::IF_TYPE_SOFTWARE_LOOPBACK
                        || a.IfType == iphelper::IF_TYPE_TUNNEL;
                    if !excluded {
                        if let Some(ip) = first_ipv4_unicast(a) {
                            if physical_type {
                                // 物理网卡是最佳候选，立即返回
                                return Some(ip.to_string());
                            }
                            // 其他接口类型仅作兜底
                            fallback.get_or_insert(ip.to_string());
                        }
                    }
                }
                adapter = a.Next;
            }
            fallback
        }
    }

    /// 读取网卡首个 IPv4 单播地址
    unsafe fn first_ipv4_unicast(
        a: &iphelper::IP_ADAPTER_ADDRESSES_LH,
    ) -> Option<Ipv4Addr> {
        let mut ua = a.FirstUnicastAddress;
        while !ua.is_null() {
            let u = &*ua;
            let sa_ptr = u.Address.lpSockaddr;
            let min_len = std::mem::size_of::<sock::SOCKADDR_IN>();
            if !sa_ptr.is_null() && (u.Address.iSockaddrLength as usize) >= min_len {
                let sa = &*(sa_ptr as *const sock::SOCKADDR);
                if sa.sa_family == sock::AF_INET {
                    let sin = &*(sa_ptr as *const sock::SOCKADDR_IN);
                    // S_addr 以网络字节序存储，to_be 还原为 (a,b,c,d)
                    let ip = Ipv4Addr::from((*sin).sin_addr.S_un.S_addr.to_be());
                    return Some(ip);
                }
            }
            ua = u.Next;
        }
        None
    }

    /// PWSTR（UTF-16，null 结尾）转为 String
    unsafe fn pwstr_to_string(ptr: windows_sys::core::PWSTR) -> String {
        if ptr.is_null() {
            return String::new();
        }
        let mut len = 0usize;
        while *ptr.add(len) != 0 {
            len += 1;
        }
        String::from_utf16_lossy(std::slice::from_raw_parts(ptr, len))
    }
}

// ==================== Unix/Linux/Android/macOS 实现 ====================

#[cfg(not(windows))]
mod unix {
    use super::is_virtual_name;

    pub fn local_ipv4() -> Option<String> {
        let list = local_ip_address::list_afinet_netifas().ok()?;
        let mut fallback: Option<String> = None;
        for (name, ip) in list {
            let std::net::IpAddr::V4(v4) = ip else { continue };
            if v4.is_loopback() || v4.is_link_local() || v4.is_unspecified() {
                continue;
            }
            let n = name.to_lowercase();
            if is_virtual_name(&n)
                || n.starts_with("zt")
                || n.starts_with("tun")
                || n.starts_with("tap")
                || n.starts_with("veth")
                || n.starts_with("wg")
            {
                continue;
            }
            // 物理网卡命名：Linux wlan*/eth*/ens*/enp*，macOS en*，Android wlan*
            let physical = n.starts_with("wlan")
                || n.starts_with("eth")
                || n.starts_with("en");
            if physical {
                return Some(v4.to_string());
            }
            fallback.get_or_insert(v4.to_string());
        }
        fallback
    }
}
