//! 节点状态持久化：ZT state get/put 回调 → home 目录下文件。
//! 文件命名对照官方 JNI 层（com_zerotierone_sdk_Node.cpp L399-525）：
//! identity.public / identity.secret / planet / moons.d/<16hex>.moon /
//! peers.d/<10hex> / networks.d/<16hex>.conf

use std::ffi::c_void;
use std::fs;
use std::path::{Path, PathBuf};
use std::slice;

use super::capi::*;

/// 根据状态对象类型与 ID 计算相对路径
fn state_path(obj_type: i32, id: &[u64]) -> Option<PathBuf> {
    let id0 = id.first().copied().unwrap_or(0);
    match obj_type {
        ZT_STATE_OBJECT_IDENTITY_PUBLIC => Some(PathBuf::from("identity.public")),
        ZT_STATE_OBJECT_IDENTITY_SECRET => Some(PathBuf::from("identity.secret")),
        ZT_STATE_OBJECT_PLANET => Some(PathBuf::from("planet")),
        ZT_STATE_OBJECT_MOON => Some(PathBuf::from(format!("moons.d/{id0:016x}.moon"))),
        ZT_STATE_OBJECT_PEER => Some(PathBuf::from(format!("peers.d/{id0:010x}"))),
        ZT_STATE_OBJECT_NETWORK_CONFIG => Some(PathBuf::from(format!(
            "networks.d/{id0:016x}.conf"
        ))),
        _ => None,
    }
}

/// state put：len < 0 表示删除；否则整体覆盖写入
pub(super) unsafe extern "C" fn state_put(
    _node: *mut ZT_Node,
    uptr: *mut c_void,
    _tptr: *mut c_void,
    obj_type: i32,
    id: *const u64,
    data: *const c_void,
    len: i32,
) {
    let Some(rel) = state_path(obj_type, id_to_slice(id)) else {
        return;
    };
    let ctx = &*(uptr as *const super::ZtContext);
    let path = ctx.home.join(&rel);

    if len < 0 {
        // 删除状态对象；不存在视为成功
        let _ = fs::remove_file(&path);
        return;
    }

    let bytes = slice::from_raw_parts(data as *const u8, len as usize);
    if write_file(&path, bytes).is_err() {
        tracing::warn!("状态写入失败: {}", path.display());
    }
}

/// state get：返回写入字节数；未找到/缓冲区不足返回 -1
pub(super) unsafe extern "C" fn state_get(
    _node: *mut ZT_Node,
    uptr: *mut c_void,
    _tptr: *mut c_void,
    obj_type: i32,
    id: *const u64,
    buf: *mut c_void,
    buf_len: u32,
) -> i32 {
    let Some(rel) = state_path(obj_type, id_to_slice(id)) else {
        return -1;
    };
    let ctx = &*(uptr as *const super::ZtContext);
    let path = ctx.home.join(&rel);

    match fs::read(&path) {
        Ok(bytes) => {
            if bytes.len() > buf_len as usize {
                return -1;
            }
            std::ptr::copy_nonoverlapping(
                bytes.as_ptr() as *const c_void,
                buf,
                bytes.len(),
            );
            bytes.len() as i32
        }
        Err(_) => -1,
    }
}

unsafe fn id_to_slice(id: *const u64) -> &'static [u64] {
    if id.is_null() {
        &[]
    } else {
        slice::from_raw_parts(id, 2)
    }
}

fn write_file(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, bytes)
}
