//! ZeroTier C SDK（include/ZeroTierOne.h）的 Rust 声明：
//! 仅包含本项目所用部分；结构体按头文件逐字段对齐（Windows LLP64：long/i 为 32 位）。
#![allow(non_camel_case_types)]
// 部分常量/函数在后续阶段（W3/W4）才接入使用
#![allow(dead_code)]

use std::ffi::c_void;
// windows-sys 的 SOCKADDR_STORAGE 为 repr(C)，与 C ABI 布局一致（128 字节）
pub use windows_sys::Win32::Networking::WinSock::SOCKADDR_STORAGE;

/// 不透明节点指针
pub type ZT_Node = c_void;

// ===== ZT_ResultCode =====
pub const ZT_RESULT_OK: i32 = 0;
pub const ZT_RESULT_OK_IGNORED: i32 = 1;
pub const ZT_RESULT_FATAL_ERROR_OUT_OF_MEMORY: i32 = 100;
pub const ZT_RESULT_FATAL_ERROR_DATA_STORE_FAILED: i32 = 101;
pub const ZT_RESULT_FATAL_ERROR_INTERNAL: i32 = 102;
pub const ZT_RESULT_ERROR_NETWORK_NOT_FOUND: i32 = 1000;
pub const ZT_RESULT_ERROR_UNSUPPORTED_OPERATION: i32 = 1001;
pub const ZT_RESULT_ERROR_BAD_PARAMETER: i32 = 1002;

// ===== ZT_StateObjectType =====
pub const ZT_STATE_OBJECT_NULL: i32 = 0;
pub const ZT_STATE_OBJECT_IDENTITY_PUBLIC: i32 = 1;
pub const ZT_STATE_OBJECT_IDENTITY_SECRET: i32 = 2;
pub const ZT_STATE_OBJECT_PLANET: i32 = 3;
pub const ZT_STATE_OBJECT_MOON: i32 = 4;
pub const ZT_STATE_OBJECT_PEER: i32 = 5;
pub const ZT_STATE_OBJECT_NETWORK_CONFIG: i32 = 6;

// ===== ZT_Event =====
pub const ZT_EVENT_UP: i32 = 0;
pub const ZT_EVENT_OFFLINE: i32 = 1;
pub const ZT_EVENT_ONLINE: i32 = 2;
pub const ZT_EVENT_DOWN: i32 = 3;
pub const ZT_EVENT_FATAL_ERROR_IDENTITY_COLLISION: i32 = 4;
pub const ZT_EVENT_TRACE: i32 = 5;
pub const ZT_EVENT_USER_MESSAGE: i32 = 6;
pub const ZT_EVENT_REMOTE_TRACE: i32 = 7;

// ===== ZT_VirtualNetworkConfigOperation =====
pub const ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_UP: i32 = 1;
pub const ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_CONFIG_UPDATE: i32 = 2;
pub const ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_DOWN: i32 = 3;
pub const ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_DESTROY: i32 = 4;

// ===== ZT_VirtualNetworkStatus =====
pub const ZT_NETWORK_STATUS_REQUESTING_CONFIGURATION: i32 = 0;
pub const ZT_NETWORK_STATUS_OK: i32 = 1;
pub const ZT_NETWORK_STATUS_ACCESS_DENIED: i32 = 2;
pub const ZT_NETWORK_STATUS_NOT_FOUND: i32 = 3;
pub const ZT_NETWORK_STATUS_PORT_ERROR: i32 = 4;
pub const ZT_NETWORK_STATUS_CLIENT_TOO_OLD: i32 = 5;
pub const ZT_NETWORK_STATUS_AUTHENTICATION_REQUIRED: i32 = 6;

// ===== ZT_VirtualNetworkType =====
pub const ZT_NETWORK_TYPE_PRIVATE: i32 = 0;
pub const ZT_NETWORK_TYPE_PUBLIC: i32 = 1;

// ===== 数组容量常量（ZeroTierOne.h） =====
pub const ZT_MAX_NETWORK_SHORT_NAME_LENGTH: usize = 127;
pub const ZT_MAX_NETWORK_ROUTES: usize = 128;
pub const ZT_MAX_ZT_ASSIGNED_ADDRESSES: usize = 32;
pub const ZT_MAX_MULTICAST_SUBSCRIPTIONS: usize = 1024;
pub const ZT_MAX_DNS_SERVERS: usize = 4;

/// 网络下发的路由（ZT_VirtualNetworkRoute）
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ZT_VirtualNetworkRoute {
    pub target: SOCKADDR_STORAGE,
    pub via: SOCKADDR_STORAGE,
    pub flags: u16,
    pub metric: u16,
}

/// DNS 配置（ZT_VirtualNetworkDNS）
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ZT_VirtualNetworkDNS {
    pub domain: [u8; 128],
    pub server_addr: [SOCKADDR_STORAGE; ZT_MAX_DNS_SERVERS],
}

/// 组播订阅（ZT_VirtualNetworkConfig.multicastSubscriptions 元素）
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ZT_MulticastSubscription {
    /// MAC，低 48 位
    pub mac: u64,
    pub adi: u32,
}

/// 虚拟网络配置（ZT_VirtualNetworkConfig）
#[repr(C)]
pub struct ZT_VirtualNetworkConfig {
    pub nwid: u64,
    pub mac: u64,
    pub name: [u8; ZT_MAX_NETWORK_SHORT_NAME_LENGTH + 1],
    pub status: i32,
    pub network_type: i32,
    pub mtu: u32,
    pub dhcp: i32,
    pub bridge: i32,
    pub broadcast_enabled: i32,
    pub port_error: i32,
    pub netconf_revision: u32,
    pub assigned_address_count: u32,
    pub assigned_addresses: [SOCKADDR_STORAGE; ZT_MAX_ZT_ASSIGNED_ADDRESSES],
    pub route_count: u32,
    pub routes: [ZT_VirtualNetworkRoute; ZT_MAX_NETWORK_ROUTES],
    pub multicast_subscription_count: u32,
    pub multicast_subscriptions: [ZT_MulticastSubscription; ZT_MAX_MULTICAST_SUBSCRIPTIONS],
    pub dns: ZT_VirtualNetworkDNS,
    pub sso_enabled: bool,
    pub sso_version: u64,
    pub authentication_url: [u8; 2048],
    pub authentication_expiry_time: u64,
    pub issuer_url: [u8; 2048],
    pub central_auth_url: [u8; 2048],
    pub sso_nonce: [u8; 128],
    pub sso_state: [u8; 256],
    pub sso_client_id: [u8; 256],
    pub sso_provider: [u8; 64],
}

/// 节点状态（ZT_NodeStatus）
#[repr(C)]
pub struct ZT_NodeStatus {
    pub address: u64,
    pub public_identity: *const std::os::raw::c_char,
    pub secret_identity: *const std::os::raw::c_char,
    pub online: i32,
}

// ===== 回调函数指针类型 =====
pub type ZT_StatePutFunction = unsafe extern "C" fn(
    node: *mut ZT_Node,
    uptr: *mut c_void,
    tptr: *mut c_void,
    obj_type: i32,
    id: *const u64,
    data: *const c_void,
    len: i32,
);

pub type ZT_StateGetFunction = unsafe extern "C" fn(
    node: *mut ZT_Node,
    uptr: *mut c_void,
    tptr: *mut c_void,
    obj_type: i32,
    id: *const u64,
    buf: *mut c_void,
    buf_len: u32,
) -> i32;

pub type ZT_WirePacketSendFunction = unsafe extern "C" fn(
    node: *mut ZT_Node,
    uptr: *mut c_void,
    tptr: *mut c_void,
    local_socket: i64,
    remote_address: *const SOCKADDR_STORAGE,
    data: *const c_void,
    len: u32,
    ttl: u32,
) -> i32;

pub type ZT_VirtualNetworkFrameFunction = unsafe extern "C" fn(
    node: *mut ZT_Node,
    uptr: *mut c_void,
    tptr: *mut c_void,
    nwid: u64,
    network_user_ptr: *mut *mut c_void,
    src_mac: u64,
    dst_mac: u64,
    ether_type: u32,
    vlan_id: u32,
    data: *const c_void,
    len: u32,
);

pub type ZT_VirtualNetworkConfigFunction = unsafe extern "C" fn(
    node: *mut ZT_Node,
    uptr: *mut c_void,
    tptr: *mut c_void,
    nwid: u64,
    network_user_ptr: *mut *mut c_void,
    op: i32,
    config: *const ZT_VirtualNetworkConfig,
) -> i32;

pub type ZT_EventCallback = unsafe extern "C" fn(
    node: *mut ZT_Node,
    uptr: *mut c_void,
    tptr: *mut c_void,
    event: i32,
    payload: *const c_void,
);

pub type ZT_PathCheckFunction = unsafe extern "C" fn(
    node: *mut ZT_Node,
    uptr: *mut c_void,
    tptr: *mut c_void,
    zt_address: u64,
    local_socket: i64,
    remote_address: *const SOCKADDR_STORAGE,
) -> i32;

pub type ZT_PathLookupFunction = unsafe extern "C" fn(
    node: *mut ZT_Node,
    uptr: *mut c_void,
    tptr: *mut c_void,
    zt_address: u64,
    family: i32,
    result: *mut SOCKADDR_STORAGE,
) -> i32;

/// 节点回调集合（ZT_Node_Callbacks；version 为 C long，Windows = i32）
#[repr(C)]
pub struct ZT_Node_Callbacks {
    pub version: i32,
    pub state_put: ZT_StatePutFunction,
    pub state_get: ZT_StateGetFunction,
    pub wire_packet_send: ZT_WirePacketSendFunction,
    pub virtual_network_frame: ZT_VirtualNetworkFrameFunction,
    pub virtual_network_config: ZT_VirtualNetworkConfigFunction,
    pub event: ZT_EventCallback,
    pub path_check: ZT_PathCheckFunction,
    pub path_lookup: ZT_PathLookupFunction,
}

/// 节点配置（ZT_Node_Config）
#[repr(C)]
pub struct ZT_Node_Config {
    pub enable_encrypted_hello: i32,
    pub low_bandwidth_mode: i32,
}

unsafe extern "C" {
    pub fn ZT_Node_new(
        node: *mut *mut ZT_Node,
        config: *const ZT_Node_Config,
        uptr: *mut c_void,
        tptr: *mut c_void,
        callbacks: *const ZT_Node_Callbacks,
        now: i64,
    ) -> i32;

    pub fn ZT_Node_delete(node: *mut ZT_Node);

    pub fn ZT_Node_processWirePacket(
        node: *mut ZT_Node,
        tptr: *mut c_void,
        now: i64,
        local_socket: i64,
        remote_address: *const SOCKADDR_STORAGE,
        packet_data: *const c_void,
        packet_length: u32,
        next_deadline: *mut i64,
    ) -> i32;

    pub fn ZT_Node_processVirtualNetworkFrame(
        node: *mut ZT_Node,
        tptr: *mut c_void,
        now: i64,
        nwid: u64,
        local_mac: u64,
        dest_mac: u64,
        ether_type: u32,
        vlan_id: u32,
        frame_data: *const c_void,
        frame_length: u32,
        next_deadline: *mut i64,
    ) -> i32;

    pub fn ZT_Node_processBackgroundTasks(
        node: *mut ZT_Node,
        tptr: *mut c_void,
        now: i64,
        next_deadline: *mut i64,
    ) -> i32;

    pub fn ZT_Node_join(node: *mut ZT_Node, nwid: u64, uptr: *mut c_void, tptr: *mut c_void)
        -> i32;

    pub fn ZT_Node_leave(
        node: *mut ZT_Node,
        nwid: u64,
        uptr: *mut *mut c_void,
        tptr: *mut c_void,
    ) -> i32;

    pub fn ZT_Node_multicastSubscribe(
        node: *mut ZT_Node,
        tptr: *mut c_void,
        nwid: u64,
        multicast_group: u64,
        multicast_adi: u32,
    ) -> i32;

    pub fn ZT_Node_status(node: *mut ZT_Node, status: *mut ZT_NodeStatus);

    pub fn ZT_Node_address(node: *mut ZT_Node) -> u64;

    pub fn ZT_version(major: *mut i32, minor: *mut i32, revision: *mut i32);
}
