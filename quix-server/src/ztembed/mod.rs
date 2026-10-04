//! 内嵌 ZeroTier 核心（Windows）。
//!
//! 职责：创建/持有 ZeroTier 节点（UDP 9994 + 后台线程）、join 网络、
//! 等待 my.zerotier.com 授权后读取分配 IP。W2 仅控制面；TUN 在 W3 接入。

use std::collections::HashSet;
use std::net::{IpAddr, Ipv4Addr};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime};

use arp::{ArpTable, MAC_BROADCAST};
use capi::*;
use tun::TunDevice;

mod arp;
mod capi;
mod datastore;
mod sockaddr;
mod tun;
mod udp;

/// join 结果
pub struct JoinResult {
    /// ZeroTier 分配的 IPv4 地址
    pub ip: String,
    /// 本节点 40 位地址
    pub node_address: u64,
}

/// 可变状态（被 config/event/pathCheck 回调更新）
struct ZtStateData {
    online: bool,
    node_address: u64,
    nwid: u64,
    network_status: i32,
    /// 本节点虚拟 MAC（config 回调更新）
    mac: u64,
    /// ZeroTier 分配地址及前缀
    assigned: Vec<(IpAddr, u8)>,
    assigned_ipv4: Option<String>,
    mtu: u32,
}

/// 节点上下文（Arc 固定，回调通过裸指针访问）
pub(super) struct ZtContext {
    node: *mut ZT_Node,
    home: PathBuf,
    socket: std::net::UdpSocket,
    shutdown: Arc<AtomicBool>,
    state: Mutex<ZtStateData>,
    signal: Condvar,
    threads: Mutex<Vec<Option<JoinHandle<()>>>>,
    /// Wintun 数据面（授权成功后由主线程创建）
    tun: Mutex<Option<Arc<TunDevice>>>,
    /// TUN 创建失败标志（避免重复尝试刷日志）
    tun_failed: AtomicBool,
    /// ARP 表（IPv4 IP → MAC）
    arp: ArpTable,
    /// 已订阅的组播组 (group_mac, adi)
    multicast: Mutex<HashSet<(u64, u64)>>,
    /// 待执行的组播订阅（config 回调内不能调用 ZT_Node_*，延迟到后台线程执行）
    pending_multicast: Mutex<Vec<(u64, u64)>>,
}

// 裸 node 指针仅在受控线程中使用；整体由 Arc + shutdown 协议保证安全
unsafe impl Send for ZtContext {}
unsafe impl Sync for ZtContext {}

/// 当前全局节点
static GLOBAL: Mutex<Option<Arc<ZtContext>>> = Mutex::new(None);

/// join 指定网络并等待授权与 IP（幂等：同网络已在线则直接返回）
pub fn join(network_id_hex: &str, timeout: Duration) -> anyhow::Result<JoinResult> {
    let nwid = u64::from_str_radix(network_id_hex.trim(), 16)
        .map_err(|_| anyhow::anyhow!("ZeroTier 网络 ID 格式无效（应为 16 位十六进制）"))?;

    // 已存在同网络节点：已就绪直接返回，否则先拆除
    {
        let mut guard = GLOBAL.lock().expect("GLOBAL 锁毒化");
        if let Some(existing) = guard.as_ref() {
            let st = existing.state.lock().expect("state 锁毒化");
            if st.nwid == nwid
                && st.network_status == ZT_NETWORK_STATUS_OK
                && st.assigned_ipv4.is_some()
            {
                return Ok(JoinResult {
                    ip: st.assigned_ipv4.clone().unwrap(),
                    node_address: st.node_address,
                });
            }
            drop(st);
            let existing = guard.take().unwrap();
            drop(guard);
            teardown(existing);
        }
    }

    // home 目录：%APPDATA%\QuiX\zerotier
    let appdata = std::env::var("APPDATA")
        .map_err(|_| anyhow::anyhow!("无法获取 APPDATA 目录"))?;
    let home = PathBuf::from(appdata).join("QuiX").join("zerotier");
    std::fs::create_dir_all(&home)?;

    let socket = udp::bind().map_err(|e| anyhow::anyhow!("绑定 ZeroTier UDP 9994 失败: {e}"))?;

    let context = Arc::new(ZtContext {
        node: std::ptr::null_mut(),
        home,
        socket,
        shutdown: Arc::new(AtomicBool::new(false)),
        state: Mutex::new(ZtStateData {
            online: false,
            node_address: 0,
            nwid,
            mac: 0,
            network_status: ZT_NETWORK_STATUS_REQUESTING_CONFIGURATION,
            assigned: Vec::new(),
            assigned_ipv4: None,
            mtu: 0,
        }),
        signal: Condvar::new(),
        threads: Mutex::new(Vec::new()),
        tun: Mutex::new(None),
        tun_failed: AtomicBool::new(false),
        arp: ArpTable::default(),
        multicast: Mutex::new(HashSet::new()),
        pending_multicast: Mutex::new(Vec::new()),
    });

    let ctx_ptr = Arc::as_ptr(&context) as *mut std::ffi::c_void;

    let callbacks = ZT_Node_Callbacks {
        version: 0,
        state_put: datastore::state_put,
        state_get: datastore::state_get,
        wire_packet_send: udp::wire_packet_send,
        virtual_network_frame: frame_cb,
        virtual_network_config: config_cb,
        event: event_cb,
        path_check: path_check_cb,
        path_lookup: path_lookup_stub,
    };
    let node_config = ZT_Node_Config {
        enable_encrypted_hello: 0,
        low_bandwidth_mode: 0,
    };

    // 创建节点（UP 事件可能在此返回前发生）
    let mut node: *mut ZT_Node = std::ptr::null_mut();
    let rc = unsafe {
        ZT_Node_new(
            &mut node,
            &node_config,
            ctx_ptr,
            std::ptr::null_mut(),
            &callbacks,
            now_ms(),
        )
    };
    if rc != ZT_RESULT_OK {
        return Err(anyhow::anyhow!("ZeroTier 节点创建失败，rc={rc}"));
    }
    // 回填 node 指针（Arc 已固定，地址不变）
    unsafe {
        (Arc::as_ptr(&context) as *mut ZtContext).as_mut().unwrap().node = node;
    }
    let node_address = unsafe { ZT_Node_address(node) };
    {
        let mut st = context.state.lock().expect("state 锁毒化");
        st.node_address = node_address;
    }

    // 注册全局并启动工作线程
    *GLOBAL.lock().expect("GLOBAL 锁毒化") = Some(context.clone());
    spawn_threads(&context);

    // join 网络
    let rc = unsafe {
        ZT_Node_join(node, nwid, std::ptr::null_mut(), std::ptr::null_mut())
    };
    if rc != ZT_RESULT_OK && rc != ZT_RESULT_OK_IGNORED {
        // 失败路径：先把全局引用摘除，再 teardown。
        // 否则 GLOBAL 残留该 Arc，下次 join 会再次 teardown（双重释放）
        *GLOBAL.lock().expect("GLOBAL 锁毒化") = None;
        teardown(context);
        return Err(anyhow::anyhow!("加入 ZeroTier 网络失败，rc={rc}"));
    }
    tracing::info!(
        "已加入 ZeroTier 网络 {network_id_hex}，等待 my.zerotier.com 授权（节点地址 {node_address:010x}）"
    );

    // 等待授权 + 分配 IP，成功后建立 TUN 数据面
    let deadline = Instant::now() + timeout;
    let mut st = context.state.lock().expect("state 锁毒化");
    loop {
        let ready = st.network_status == ZT_NETWORK_STATUS_OK && st.assigned_ipv4.is_some();
        if ready {
            drop(st);
            ensure_tun(&context)?;
            return Ok(JoinResult {
                ip: context
                    .state
                    .lock()
                    .expect("state 锁毒化")
                    .assigned_ipv4
                    .clone()
                    .unwrap(),
                node_address,
            });
        }
        let now = Instant::now();
        if now >= deadline {
            drop(st);
            return Err(anyhow::anyhow!(
                "等待 ZeroTier 授权超时：请确认已在 my.zerotier.com 勾选 Auth"
            ));
        }
        let (guard, _) = context
            .signal
            .wait_timeout(st, deadline - now)
            .expect("condvar 毒化");
        st = guard;
    }
}

/// leave 并拆除节点
pub fn leave() {
    let ctx = GLOBAL.lock().expect("GLOBAL 锁毒化").take();
    if let Some(ctx) = ctx {
        let nwid = ctx.state.lock().map(|s| s.nwid).unwrap_or(0);
        unsafe {
            ZT_Node_leave(
                ctx.node,
                nwid,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            );
        }
        teardown(ctx);
    }
}

/// 停止并清理（进程退出/服务停止时调用）
pub fn shutdown() {
    if let Some(ctx) = GLOBAL.lock().expect("GLOBAL 锁毒化").take() {
        teardown(ctx);
    }
}

/// 当前状态快照：(online, node_address, nwid, ip)
pub fn status() -> Option<(bool, u64, u64, Option<String>)> {
    let guard = GLOBAL.lock().expect("GLOBAL 锁毒化");
    let ctx = guard.as_ref()?;
    let st = ctx.state.lock().expect("state 锁毒化");
    Some((st.online, st.node_address, st.nwid, st.assigned_ipv4.clone()))
}

/// 拆除：先停线程再销毁节点（避免 use-after-free）
fn teardown(ctx: Arc<ZtContext>) {
    ctx.shutdown.store(true, Ordering::Relaxed);
    let handles: Vec<Option<JoinHandle<()>>> =
        std::mem::take(&mut *ctx.threads.lock().expect("threads 锁毒化"));
    for h in handles.into_iter().flatten() {
        let _ = h.join();
    }
    // 关闭 TUN（线程已停，无并发访问）
    *ctx.tun.lock().expect("tun 锁毒化") = None;
    // 取出 node 指针并立即置空，保证 teardown 幂等：
    // 即使同一 Arc 被重复 teardown，也不会对同一节点二次 ZT_Node_delete
    let node_cell = unsafe { &mut (*(Arc::as_ptr(&ctx) as *mut ZtContext)).node };
    let node = std::mem::replace(node_cell, std::ptr::null_mut());
    if !node.is_null() {
        unsafe { ZT_Node_delete(node) };
    }
}

fn spawn_threads(ctx: &Arc<ZtContext>) {
    // UDP 接收线程
    let udp_ctx = ctx.clone();
    let udp_handle = thread::Builder::new()
        .name("quix-zt-udp".into())
        .spawn(move || udp_loop(udp_ctx))
        .expect("spawn quix-zt-udp");

    // 后台任务线程
    let bg_ctx = ctx.clone();
    let bg_handle = thread::Builder::new()
        .name("quix-zt-bg".into())
        .spawn(move || background_loop(bg_ctx))
        .expect("spawn quix-zt-bg");

    ctx.threads
        .lock()
        .expect("threads 锁毒化")
        .extend([Some(udp_handle), Some(bg_handle)]);
}

fn udp_loop(ctx: Arc<ZtContext>) {
    use std::io::ErrorKind;
    // 缓冲加大到 64KB：配合下面对 WSAEMSGSIZE 的容错，避免单个大包杀死线程
    let mut buf = [0u8; 65536];
    while !ctx.shutdown.load(Ordering::Relaxed) {
        match ctx.socket.recv_from(&mut buf) {
            Ok((n, addr)) => {
                if n == 0 {
                    continue;
                }
                let ss = sockaddr::socketaddr_to_storage(addr);
                let mut deadline = 0i64;
                let rc = unsafe {
                    ZT_Node_processWirePacket(
                        ctx.node,
                        std::ptr::null_mut(),
                        now_ms(),
                        -1,
                        &ss,
                        buf.as_ptr() as *const std::ffi::c_void,
                        n as u32,
                        &mut deadline,
                    )
                };
                if (100..1000).contains(&rc) {
                    tracing::error!("processWirePacket 致命错误，rc={rc}");
                }
            }
            Err(e) if e.kind() == ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(20));
            }
            Err(e) => {
                // Windows 上到达数据报大于接收缓冲时返回 WSAEMSGSIZE(10040)；
                // 该错误及其他瞬时错误若直接 break，接收线程永久退出、ZT 静默失活。
                // 此处记录并短暂等待后继续，只有 shutdown 才结束循环
                #[cfg(windows)]
                let too_large = e.raw_os_error() == Some(10040);
                #[cfg(not(windows))]
                let too_large = false;
                if !too_large {
                    tracing::warn!("UDP recv 瞬时错误，已忽略: {e}");
                }
                thread::sleep(Duration::from_millis(20));
            }
        }
    }
}

fn background_loop(ctx: Arc<ZtContext>) {
    while !ctx.shutdown.load(Ordering::Relaxed) {
        let mut deadline = 0i64;
        let rc = unsafe {
            ZT_Node_processBackgroundTasks(
                ctx.node,
                std::ptr::null_mut(),
                now_ms(),
                &mut deadline,
            )
        };
        if (100..1000).contains(&rc) {
            tracing::error!("processBackgroundTasks 致命错误，rc={rc}");
        }
        // 执行 config 回调延迟入队的组播订阅（此处非回调上下文，调用安全）
        let pending: Vec<(u64, u64)> = std::mem::take(
            &mut *ctx.pending_multicast.lock().expect("pending_multicast 锁毒化"),
        );
        for (group_mac, adi) in pending {
            if !ctx.node.is_null() {
                let nwid = ctx_nwid(&ctx);
                unsafe {
                    ZT_Node_multicastSubscribe(
                        ctx.node,
                        std::ptr::null_mut(),
                        nwid,
                        group_mac,
                        adi as u32,
                    );
                }
            }
        }
        // 分片睡眠以便快速响应 shutdown
        let now = now_ms();
        let wait_ms = deadline.saturating_sub(now).clamp(10, 500);
        let mut remaining = wait_ms;
        while remaining > 0 && !ctx.shutdown.load(Ordering::Relaxed) {
            let step = remaining.min(100);
            thread::sleep(Duration::from_millis(step as u64));
            remaining -= step;
        }
    }
}

/// virtualNetworkConfig 回调：更新状态并通知等待者
unsafe extern "C" fn config_cb(
    _node: *mut ZT_Node,
    uptr: *mut std::ffi::c_void,
    _tptr: *mut std::ffi::c_void,
    _nwid: u64,
    _network_user_ptr: *mut *mut std::ffi::c_void,
    op: i32,
    config: *const ZT_VirtualNetworkConfig,
) -> i32 {
    let ctx = &*(uptr as *const ZtContext);
    let cfg = &*config;

    // 解析分配地址
    let mut assigned: Vec<(IpAddr, u8)> = Vec::new();
    for i in 0..cfg.assigned_address_count as usize {
        if let Some(ip_prefix) =
            sockaddr::storage_to_ip_and_prefix(&cfg.assigned_addresses[i])
        {
            assigned.push(ip_prefix);
        }
    }
    let assigned_ipv4 = assigned
        .iter()
        .find(|(ip, _)| ip.is_ipv4())
        .map(|(ip, _)| ip.to_string());
    // R6：每个分配的 IPv4 都要作为广播组 ADI 订阅（主机序 32 位数值）
    let broadcast_adis: Vec<u64> = assigned
        .iter()
        .filter_map(|(ip, _)| match ip {
            IpAddr::V4(v) => Some(u32::from(*v) as u64),
            _ => None,
        })
        .collect();

    tracing::info!(
        "ZeroTier 配置更新 op={op} status={} mtu={} 地址={:?}",
        cfg.status,
        cfg.mtu,
        assigned,
    );

    let mut st = ctx.state.lock().expect("state 锁毒化");
    st.nwid = cfg.nwid;
    st.network_status = cfg.status;
    st.mtu = cfg.mtu;
    st.mac = cfg.mac;
    st.assigned = assigned;
    st.assigned_ipv4 = assigned_ipv4;
    drop(st);
    // R6：对每个分配的 IPv4 订阅广播组 (0xffffffffffff, ADI=该 IP 主机序)，
    // 否则其他成员广播的 ARP 请求不会送达本机，外部经 ZT 的主动连接无法解析 MAC。
    // 注意：config_cb 由 ZT 核心在持有内部锁时调用，不能在此调用 ZT_Node_*，
    // 改为入队，由后台任务线程在 processBackgroundTasks 返回后执行
    for adi in broadcast_adis {
        defer_subscribe_multicast(ctx, MAC_BROADCAST, adi);
    }
    ctx.signal.notify_all();
    0
}

/// event 回调
unsafe extern "C" fn event_cb(
    _node: *mut ZT_Node,
    uptr: *mut std::ffi::c_void,
    _tptr: *mut std::ffi::c_void,
    event: i32,
    _payload: *const std::ffi::c_void,
) {
    let ctx = &*(uptr as *const ZtContext);
    match event {
        ZT_EVENT_UP | ZT_EVENT_ONLINE => {
            ctx.state
                .lock()
                .map(|mut s| s.online = true)
                .expect("state 锁毒化");
            tracing::info!("ZeroTier 节点事件: event={event}（在线）");
        }
        ZT_EVENT_OFFLINE => {
            ctx.state
                .lock()
                .map(|mut s| s.online = false)
                .expect("state 锁毒化");
            tracing::warn!("ZeroTier 节点离线");
        }
        ZT_EVENT_FATAL_ERROR_IDENTITY_COLLISION => {
            tracing::error!("ZeroTier 身份地址冲突，需删除 identity 后重启");
        }
        _ => {}
    }
}

/// pathCheck 回调：远端落在本 ZeroTier 地址网段内则拒绝（防环路）
unsafe extern "C" fn path_check_cb(
    _node: *mut ZT_Node,
    uptr: *mut std::ffi::c_void,
    _tptr: *mut std::ffi::c_void,
    _zt_address: u64,
    _local_socket: i64,
    remote_address: *const SOCKADDR_STORAGE,
) -> i32 {
    let ctx = &*(uptr as *const ZtContext);
    let Some(remote) = sockaddr::storage_to_socketaddr(&*remote_address) else {
        return 1;
    };
    let st = ctx.state.lock().expect("state 锁毒化");
    for (network, prefix) in &st.assigned {
        if same_subnet(remote.ip(), network, *prefix) {
            return 0;
        }
    }
    1
}

/// virtualNetworkFrame 回调：ZT 核心发出的虚拟网络帧（L3 载荷），
/// ARP 本地应答/学表，IPv4 写入 TUN
unsafe extern "C" fn frame_cb(
    node: *mut ZT_Node,
    uptr: *mut std::ffi::c_void,
    _tptr: *mut std::ffi::c_void,
    nwid: u64,
    _network_user_ptr: *mut *mut std::ffi::c_void,
    src_mac: u64,
    _dst_mac: u64,
    ether_type: u32,
    _vlan_id: u32,
    data: *const std::ffi::c_void,
    len: u32,
) {
    let ctx = &*(uptr as *const ZtContext);
    let data = std::slice::from_raw_parts(data as *const u8, len as usize);
    match ether_type {
        arp::ETHERTYPE_ARP => handle_arp_frame(ctx, node, nwid, src_mac, data),
        arp::ETHERTYPE_IPV4 => handle_ipv4_frame(ctx, src_mac, data),
        _ => {}
    }
}

/// 收到 ARP 帧：学表；若为请求且目标 IP 是本机则应答
fn handle_arp_frame(
    ctx: &ZtContext,
    node: *mut ZT_Node,
    nwid: u64,
    src_mac: u64,
    data: &[u8],
) {
    let Some(pkt) = arp::parse_arp(data) else {
        return;
    };
    tracing::debug!("收到 ARP 帧 op={} spa={} tpa={}", pkt.op, pkt.spa, pkt.tpa);
    ctx.arp.learn(pkt.spa, pkt.sha);
    if pkt.op != 1 {
        return; // 仅应答 request
    }
    let (my_ip, my_mac) = local_v4_and_mac(ctx);
    if my_ip != Some(pkt.tpa) {
        return;
    }
    let reply = arp::build_reply(my_mac, pkt.tpa, pkt.sha, pkt.spa);
    send_frame_to_zt(ctx, node, nwid, src_mac, arp::ETHERTYPE_ARP, &reply);
}

/// 收到 IPv4 帧：从源 IP 学 ARP 表后写入 TUN
fn handle_ipv4_frame(ctx: &ZtContext, src_mac: u64, data: &[u8]) {
    tracing::debug!("收到 IPv4 帧 len={} src_mac={src_mac:012x}", data.len());
    if data.len() >= 20 && data[0] >> 4 == 4 {
        let src = Ipv4Addr::new(data[12], data[13], data[14], data[15]);
        if !src.is_broadcast() && !src.is_multicast() && !src.is_unspecified() {
            ctx.arp.learn(src, src_mac);
        }
    }
    if let Some(t) = ctx.tun.lock().expect("tun 锁毒化").as_ref() {
        t.send_ip_packet(data);
    }
}

/// TUN 接收线程：Windows 协议栈发出的 IP 包 → 帧化后交给 ZT 核心
fn tun_loop(ctx: Arc<ZtContext>) {
    while !ctx.shutdown.load(Ordering::Relaxed) {
        let tun = ctx.tun.lock().expect("tun 锁毒化").clone();
        let Some(tun) = tun else {
            thread::sleep(Duration::from_millis(100));
            continue;
        };
        match tun.try_receive() {
            Ok(Some(pkt)) => handle_tun_packet(&ctx, &pkt),
            Ok(None) => thread::sleep(Duration::from_millis(5)),
            Err(_) => break, // 会话已关闭
        }
    }
}

/// 处理 TUN 读出的 IP 包
fn handle_tun_packet(ctx: &ZtContext, data: &[u8]) {
    if data.len() < 20 {
        return;
    }
    match data[0] >> 4 {
        4 => {
            let dst = Ipv4Addr::new(data[16], data[17], data[18], data[19]);
            tracing::debug!("TUN 出包 dst={dst} len={}", data.len());
            let nwid = ctx_nwid(ctx);
            if dst.is_broadcast() {
                // 广播帧依赖 ZT 核心对全体成员的隐式广播订阅，无需显式订阅
                send_frame_to_zt(ctx, ctx.node, nwid, MAC_BROADCAST, arp::ETHERTYPE_IPV4, data);
            } else if dst.is_multicast() {
                let mac = arp::ipv4_multicast_mac(dst);
                subscribe_multicast(ctx, mac, 0);
                send_frame_to_zt(ctx, ctx.node, nwid, mac, arp::ETHERTYPE_IPV4, data);
            } else if let Some(mac) = ctx.arp.lookup(dst) {
                send_frame_to_zt(ctx, ctx.node, nwid, mac, arp::ETHERTYPE_IPV4, data);
            } else {
                // MAC 未知：发 ARP 请求，原包丢弃（上层协议会重传）
                send_arp_request(ctx, dst);
            }
        }
        6 => {
            // IPv6 数据面暂不支持（QuiX 传输走 IPv4）
        }
        _ => {}
    }
}

/// 发送 ARP 请求（广播）查询目标 IP 的 MAC
fn send_arp_request(ctx: &ZtContext, tpa: Ipv4Addr) {
    let (my_ip, my_mac) = local_v4_and_mac(ctx);
    let Some(my_ip) = my_ip else { return };
    let req = arp::build_request(my_mac, my_ip, tpa);
    send_frame_to_zt(ctx, ctx.node, ctx_nwid(ctx), MAC_BROADCAST, arp::ETHERTYPE_ARP, &req);
}

/// 把 L3 载荷封装为虚拟网络帧交给 ZT 核心发送
fn send_frame_to_zt(
    ctx: &ZtContext,
    node: *mut ZT_Node,
    nwid: u64,
    dest_mac: u64,
    ether_type: u32,
    data: &[u8],
) {
    if node.is_null() {
        return;
    }
    let (_, my_mac) = local_v4_and_mac(ctx);
    let mut deadline = 0i64;
    let rc = unsafe {
        ZT_Node_processVirtualNetworkFrame(
            node,
            std::ptr::null_mut(),
            now_ms(),
            nwid,
            my_mac,
            dest_mac,
            ether_type,
            0,
            data.as_ptr() as *const std::ffi::c_void,
            data.len() as u32,
            &mut deadline,
        )
    };
    if rc != ZT_RESULT_OK {
        tracing::debug!("processVirtualNetworkFrame rc={rc}");
    }
}

/// 订阅组播组（幂等）。group_mac 为组 MAC（低 48 位），adi 为附加标识。
/// IPv4 ARP 要求对 (0xffffffffffff, ADI=本机IPv4主机序) 订阅。
/// 只能在本方线程调用（TUN 线程等），禁止在 ZT 回调中调用
fn subscribe_multicast(ctx: &ZtContext, group_mac: u64, adi: u64) {
    let mut subscribed = ctx.multicast.lock().expect("multicast 锁毒化");
    if !subscribed.insert((group_mac, adi)) {
        return;
    }
    drop(subscribed);
    let nwid = ctx_nwid(ctx);
    if ctx.node.is_null() {
        return;
    }
    unsafe {
        // FFI 的 multicast ADI 为 u32（IPv4 地址本就是 32 位，as 转换安全）
        ZT_Node_multicastSubscribe(ctx.node, std::ptr::null_mut(), nwid, group_mac, adi as u32);
    }
}

/// 延迟订阅（可在 ZT 回调中调用）：去重后入队，由后台线程真正执行
fn defer_subscribe_multicast(ctx: &ZtContext, group_mac: u64, adi: u64) {
    let mut subscribed = ctx.multicast.lock().expect("multicast 锁毒化");
    if !subscribed.insert((group_mac, adi)) {
        return;
    }
    drop(subscribed);
    ctx.pending_multicast
        .lock()
        .expect("pending_multicast 锁毒化")
        .push((group_mac, adi));
}

/// 读取当前网络 ID
fn ctx_nwid(ctx: &ZtContext) -> u64 {
    ctx.state.lock().expect("state 锁毒化").nwid
}

/// 读取本机 (IPv4, MAC)
fn local_v4_and_mac(ctx: &ZtContext) -> (Option<Ipv4Addr>, u64) {
    let st = ctx.state.lock().expect("state 锁毒化");
    let ip = st.assigned.iter().find_map(|(ip, _)| match ip {
        IpAddr::V4(v) => Some(*v),
        _ => None,
    });
    (ip, st.mac)
}

/// 建立 TUN 数据面（幂等）；失败返回 Err（数据面不可用即 join 失败）
fn ensure_tun(ctx: &Arc<ZtContext>) -> anyhow::Result<()> {
    if ctx.tun_failed.load(Ordering::Relaxed) {
        return Err(anyhow::anyhow!("TUN 创建已失败（需管理员权限）"));
    }
    let (v4, mtu) = {
        let st = ctx.state.lock().expect("state 锁毒化");
        let v4 = st.assigned.iter().find_map(|(ip, prefix)| match ip {
            IpAddr::V4(v) => Some((*v, *prefix)),
            _ => None,
        });
        (v4, st.mtu)
    };
    let Some((ip, prefix)) = v4 else {
        return Err(anyhow::anyhow!("ZeroTier 未分配 IPv4 地址"));
    };

    let mut guard = ctx.tun.lock().expect("tun 锁毒化");
    if let Some(t) = guard.as_ref() {
        if t.ip == ip {
            return Ok(()); // 已就绪
        }
        // IP 变化极罕见（管理员改网段）；提示重启服务
        anyhow::bail!("ZeroTier IP 已变化（{} → {ip}），请重启 QuiX 服务", t.ip);
    }

    match TunDevice::create(ip, prefix, mtu.max(1280)) {
        Ok(t) => {
            *guard = Some(Arc::new(t));
            drop(guard);
            // 启动 TUN 接收线程
            let tun_ctx = ctx.clone();
            let handle = thread::Builder::new()
                .name("quix-zt-tun".into())
                .spawn(move || tun_loop(tun_ctx))
                .expect("spawn quix-zt-tun");
            ctx.threads
                .lock()
                .expect("threads 锁毒化")
                .push(Some(handle));
            Ok(())
        }
        Err(e) => {
            ctx.tun_failed.store(true, Ordering::Relaxed);
            Err(anyhow::anyhow!("{e}"))
        }
    }
}

unsafe extern "C" fn path_lookup_stub(
    _node: *mut ZT_Node,
    _uptr: *mut std::ffi::c_void,
    _tptr: *mut std::ffi::c_void,
    _zt_address: u64,
    _family: i32,
    _result: *mut SOCKADDR_STORAGE,
) -> i32 {
    0
}

/// 判断两个 IP 是否处于同一前缀
fn same_subnet(ip: IpAddr, network: &IpAddr, prefix: u8) -> bool {
    match (ip, network) {
        (IpAddr::V4(a), IpAddr::V4(b)) => {
            let mask = if prefix == 0 {
                0
            } else {
                u32::MAX << (32 - prefix.min(32))
            };
            (u32::from(a) & mask) == (u32::from(*b) & mask)
        }
        (IpAddr::V6(a), IpAddr::V6(b)) => {
            let bits_a = u128::from(a);
            let bits_b = u128::from(*b);
            let mask = if prefix == 0 {
                0
            } else {
                u128::MAX << (128 - prefix.min(128))
            };
            (bits_a & mask) == (bits_b & mask)
        }
        _ => false,
    }
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
