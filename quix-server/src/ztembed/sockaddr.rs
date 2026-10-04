//! SOCKADDR_STORAGE 与 std::net::SocketAddr 的转换。
//! 按稳定的 ABI 字节布局直接读写（不依赖 windows-sys 内部字段形状）：
//! - 偏移 0：address family（AF_INET=2 / AF_INET6=23）
//! - IPv4：偏移 2 端口（大端），偏移 4 地址 4 字节
//! - IPv6：偏移 2 端口，偏移 4 flowinfo，偏移 8 地址 16 字节，偏移 24 scope_id

use std::net::{IpAddr, SocketAddr};

use windows_sys::Win32::Networking::WinSock::SOCKADDR_STORAGE;

const AF_INET: u16 = 2;
const AF_INET6: u16 = 23;

/// SocketAddr → SOCKADDR_STORAGE
pub fn socketaddr_to_storage(addr: SocketAddr) -> SOCKADDR_STORAGE {
    // SOCKADDR_STORAGE 为 128 字节、全零初始化
    let mut ss: SOCKADDR_STORAGE = unsafe { std::mem::zeroed() };
    let base = &mut ss as *mut SOCKADDR_STORAGE as *mut u8;
    match addr {
        SocketAddr::V4(v4) => unsafe {
            base.cast::<u16>().write_unaligned(AF_INET);
            base.add(2).cast::<u16>().write_unaligned(v4.port().to_be());
            base.add(4)
                .cast::<[u8; 4]>()
                .write_unaligned(v4.ip().octets());
        },
        SocketAddr::V6(v6) => unsafe {
            base.cast::<u16>().write_unaligned(AF_INET6);
            base.add(2).cast::<u16>().write_unaligned(v6.port().to_be());
            base.add(4).cast::<u32>().write_unaligned(v6.flowinfo());
            base.add(8)
                .cast::<[u8; 16]>()
                .write_unaligned(v6.ip().octets());
            base.add(24).cast::<u32>().write_unaligned(v6.scope_id());
        },
    }
    ss
}

/// SOCKADDR_STORAGE → SocketAddr（family 不支持返回 None）
pub fn storage_to_socketaddr(ss: &SOCKADDR_STORAGE) -> Option<SocketAddr> {
    let base = ss as *const SOCKADDR_STORAGE as *const u8;
    unsafe {
        let family = base.cast::<u16>().read_unaligned();
        match family {
            AF_INET => {
                let port = u16::from_be(base.add(2).cast::<u16>().read_unaligned());
                let octets = base.add(4).cast::<[u8; 4]>().read_unaligned();
                Some(SocketAddr::new(IpAddr::from(octets), port))
            }
            AF_INET6 => {
                let port = u16::from_be(base.add(2).cast::<u16>().read_unaligned());
                let flowinfo = base.add(4).cast::<u32>().read_unaligned();
                let octets = base.add(8).cast::<[u8; 16]>().read_unaligned();
                let scope_id = base.add(24).cast::<u32>().read_unaligned();
                Some(SocketAddr::new(
                    IpAddr::from(octets),
                    port,
                ))
                .map(|mut sa| {
                    if let SocketAddr::V6(ref mut v6) = sa {
                        v6.set_flowinfo(flowinfo);
                        v6.set_scope_id(scope_id);
                    }
                    sa
                })
            }
            _ => None,
        }
    }
}

/// 仅读取 storage 的 IP 与掩码位数（用于 ZeroTier assignedAddresses：
/// 端口位置存放的是掩码位数而非端口）
pub fn storage_to_ip_and_prefix(ss: &SOCKADDR_STORAGE) -> Option<(IpAddr, u8)> {
    let base = ss as *const SOCKADDR_STORAGE as *const u8;
    unsafe {
        let family = base.cast::<u16>().read_unaligned();
        match family {
            AF_INET => {
                let prefix = u16::from_be(base.add(2).cast::<u16>().read_unaligned());
                let octets = base.add(4).cast::<[u8; 4]>().read_unaligned();
                Some((IpAddr::from(octets), prefix as u8))
            }
            AF_INET6 => {
                let prefix = u16::from_be(base.add(2).cast::<u16>().read_unaligned());
                let octets = base.add(8).cast::<[u8; 16]>().read_unaligned();
                Some((IpAddr::from(octets), prefix as u8))
            }
            _ => None,
        }
    }
}
