//! ARP 表与 ARP 报文构造/解析（对照 ZerotierFix TunTapAdapter + ARPTable 移植）。
//!
//! ZT 虚拟网络帧的 L3 载荷中 ARP 报文为 28 字节：
//! htype(2)=1 ptype(2)=0x0800 hlen(1)=6 plen(1)=4 op(2) sha(6) spa(4) tha(6) tpa(4)

use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// 以太网类型：IPv4
pub const ETHERTYPE_IPV4: u32 = 0x0800;
/// 以太网类型：ARP
pub const ETHERTYPE_ARP: u32 = 0x0806;
/// 广播 MAC
pub const MAC_BROADCAST: u64 = 0xffff_ffff_ffff;

const ARP_REQUEST: u8 = 1;
const ARP_REPLY: u8 = 2;
/// 表项超时（与 ZerotierFix ARPTable.ENTRY_TIMEOUT 一致）
const ENTRY_TTL: Duration = Duration::from_secs(120);

/// IP → MAC 映射表（惰性过期：lookup 时检查时间戳）
#[derive(Default)]
pub struct ArpTable(Mutex<HashMap<Ipv4Addr, (u64, Instant)>>);

impl ArpTable {
    pub fn learn(&self, ip: Ipv4Addr, mac: u64) {
        if mac == 0 || ip.is_broadcast() || ip.is_multicast() || ip.is_unspecified() {
            return;
        }
        self.0
            .lock()
            .expect("arp 表锁毒化")
            .insert(ip, (mac, Instant::now()));
    }

    pub fn lookup(&self, ip: Ipv4Addr) -> Option<u64> {
        let mut guard = self.0.lock().expect("arp 表锁毒化");
        match guard.get(&ip) {
            Some((mac, t)) if t.elapsed() < ENTRY_TTL => Some(*mac),
            _ => {
                guard.remove(&ip);
                None
            }
        }
    }
}

/// 解析出的 ARP 报文
pub struct ArpPacket {
    pub op: u8,
    pub sha: u64,
    pub spa: Ipv4Addr,
    /// 目标 MAC（解析保留完整性，应答构造使用请求方 src_mac）
    #[allow(dead_code)]
    pub tha: u64,
    pub tpa: Ipv4Addr,
}

/// 解析 28 字节 ARP 报文（不校验以太网头——ZT 帧回调直接给 L3 载荷）
pub fn parse_arp(data: &[u8]) -> Option<ArpPacket> {
    if data.len() < 28 {
        return None;
    }
    if data[0..2] != [0, 1] || data[2..4] != [8, 0] || data[4] != 6 || data[5] != 4 {
        return None;
    }
    Some(ArpPacket {
        op: data[7],
        sha: u64::from_be_bytes([0, 0, data[8], data[9], data[10], data[11], data[12], data[13]]),
        spa: Ipv4Addr::new(data[14], data[15], data[16], data[17]),
        tha: u64::from_be_bytes([
            0, 0, data[18], data[19], data[20], data[21], data[22], data[23],
        ]),
        tpa: Ipv4Addr::new(data[24], data[25], data[26], data[27]),
    })
}

/// 构造 ARP 报文（op=1 请求 / 2 应答）
pub fn build_arp(op: u8, sha: u64, spa: Ipv4Addr, tha: u64, tpa: Ipv4Addr) -> [u8; 28] {
    let mut b = [0u8; 28];
    b[0..2].copy_from_slice(&[0, 1]);
    b[2..4].copy_from_slice(&[8, 0]);
    b[4] = 6;
    b[5] = 4;
    b[6] = 0;
    b[7] = op;
    b[8..14].copy_from_slice(&sha.to_be_bytes()[2..8]);
    b[14..18].copy_from_slice(&spa.octets());
    b[18..24].copy_from_slice(&tha.to_be_bytes()[2..8]);
    b[24..28].copy_from_slice(&tpa.octets());
    b
}

/// 构造 ARP 请求
pub fn build_request(sha: u64, spa: Ipv4Addr, tpa: Ipv4Addr) -> [u8; 28] {
    build_arp(ARP_REQUEST, sha, spa, 0, tpa)
}

/// 构造 ARP 应答
pub fn build_reply(sha: u64, spa: Ipv4Addr, tha: u64, tpa: Ipv4Addr) -> [u8; 28] {
    build_arp(ARP_REPLY, sha, spa, tha, tpa)
}

/// IPv4 组播地址 → MAC（01:00:5e + 低 23 位，见 TunTapAdapter.multicastAddressToMAC）
pub fn ipv4_multicast_mac(ip: Ipv4Addr) -> u64 {
    let o = ip.octets();
    0x0100_5e00_0000 | (u64::from(o[1] & 0x7f) << 16) | (u64::from(o[2]) << 8) | u64::from(o[3])
}
