//! ZeroTier 物理网络 UDP 通道（本地端口 9994）：
//! - socket 绑定
//! - 核心 wirePacketSend 回调 → socket 发出
//! 接收循环在父模块（mod.rs）中与线程生命周期统一管理。

use std::ffi::c_void;
use std::net::UdpSocket;
use std::slice;

use super::capi::*;
use super::sockaddr::storage_to_socketaddr;
use super::ZtContext;

/// 绑定本地 9994 UDP 端口（nonblocking，供接收线程轮询）
pub(super) fn bind() -> std::io::Result<UdpSocket> {
    let socket = UdpSocket::bind("0.0.0.0:9994")?;
    socket.set_nonblocking(true)?;
    Ok(socket)
}

/// wirePacketSend 回调：通过 9994 socket 发往物理远端
pub(super) unsafe extern "C" fn wire_packet_send(
    _node: *mut ZT_Node,
    uptr: *mut c_void,
    _tptr: *mut c_void,
    _local_socket: i64,
    remote_address: *const SOCKADDR_STORAGE,
    data: *const c_void,
    len: u32,
    _ttl: u32,
) -> i32 {
    let ctx = &*(uptr as *const ZtContext);
    let Some(addr) = storage_to_socketaddr(&*remote_address) else {
        return -1;
    };
    let bytes = slice::from_raw_parts(data as *const u8, len as usize);
    match ctx.socket.send_to(bytes, addr) {
        Ok(_) => 0,
        Err(e) => {
            tracing::trace!("ZeroTier UDP 发送失败: {e}");
            -1
        }
    }
}
