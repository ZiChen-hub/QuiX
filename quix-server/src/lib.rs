//! QuiX 服务端动态库：对外暴露 C ABI，供 Flutter（统一程序）通过 FFI 调用

pub mod config;
mod discovery;
mod file_io;
mod localip;
pub mod network;
pub mod qr_gen;
pub mod server;
mod session;
mod stream_handler;
pub mod utils;
// Windows 端跨网络由内嵌 ZeroTier 核心（ztembed）实现，zerotier-cli 封装仅用于其他平台
#[cfg(not(windows))]
mod zerotier_manager;
#[cfg(windows)]
pub mod ztembed;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{Arc, Mutex, OnceLock};

use server::ServerHandle;

/// 全局 tokio 运行时（服务端后台任务运行其上，进程内常驻）
fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| tokio::runtime::Runtime::new().expect("创建 tokio 运行时失败"))
}

/// 当前运行的服务端句柄
static SERVER: Mutex<Option<Arc<ServerHandle>>> = Mutex::new(None);

/// 从 C 字符串转为 Rust String（null 视为空）
unsafe fn cstr_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    CStr::from_ptr(ptr).to_string_lossy().into_owned()
}

/// 将 JSON 值转为 C 字符串（调用方需用 quix_server_free 释放）
fn json_to_cstring(v: serde_json::Value) -> *mut c_char {
    CString::new(v.to_string()).unwrap_or_default().into_raw()
}

/// 将启动/调用结果统一转为 C 字符串
fn result_to_cstring(result: Result<serde_json::Value, String>) -> *mut c_char {
    json_to_cstring(match result {
        Ok(v) => v,
        Err(e) => serde_json::json!({ "error": e }),
    })
}

/// 启动服务端。
/// 入参为 JSON 配置字符串，返回 JSON：`{"ip","port","code"}` 或 `{"error":"..."}`。
#[no_mangle]
pub extern "C" fn quix_server_start(config_json: *const c_char) -> *mut c_char {
    let result = (|| -> Result<serde_json::Value, String> {
        let json = unsafe { cstr_to_string(config_json) };
        let config: config::Config =
            serde_json::from_str(&json).map_err(|e| format!("配置解析失败: {e}"))?;
        let code = config
            .code
            .clone()
            .unwrap_or_else(utils::generate_connection_code);
        let port = config.port;
        // 局域网 IP 始终作为主连接地址；启用跨网络时额外提供跨网络可达地址（IPv6 → UPnP → ZeroTier）
        let ip = utils::get_local_ip().unwrap_or_else(|| "127.0.0.1".to_string());
        let mut cross_ip: Option<String> = None;
        let mut connection_type = "局域网直连";
        if config.enable_cross_network {
            match runtime().block_on(network::establish_cross_network(
                port,
                &config.zerotier_network_id,
            )) {
                Ok(Some(reachable)) => {
                    cross_ip = Some(reachable);
                    connection_type = "跨网络";
                }
                Ok(None) => {}
                Err(e) => {
                    tracing::warn!("跨网络组网失败，回退局域网直连: {e:#}");
                }
            }
        }
        let handle = runtime()
            .block_on(ServerHandle::start(config, code.clone(), ip.clone()))
            .map_err(|e| format!("{e:#}"))?;
        let fingerprint = handle.cert_fingerprint.clone();
        *SERVER.lock().expect("服务端句柄锁被毒化") = Some(Arc::new(handle));
        Ok(serde_json::json!({
            "ip": ip,
            "cross_ip": cross_ip,
            "port": port,
            "code": code,
            "cert_fingerprint": fingerprint,
            "connection_type": connection_type,
        }))
    })();

    result_to_cstring(result)
}

/// 停止服务端。
#[no_mangle]
pub extern "C" fn quix_server_stop() {
    if let Some(handle) = SERVER.lock().expect("服务端句柄锁被毒化").take() {
        handle.stop();
    }
    // 清理 UPnP 端口映射，避免在路由器上遗留映射
    runtime().block_on(network::cleanup_upnp());
    // 停止内嵌 ZeroTier（Windows，跨网络组网跟随接收服务生命周期）
    #[cfg(windows)]
    network::stop_zerotier_embedded();
}

/// 获取服务端状态。
/// 返回 JSON：`{"connected","mobile","desktop","ip","port","code","stats","records"}` 或 `{"error":"..."}`。
#[no_mangle]
pub extern "C" fn quix_server_status() -> *mut c_char {
    let result = (|| -> Result<serde_json::Value, String> {
        let guard = SERVER.lock().expect("服务端句柄锁被毒化");
        let handle = guard.as_ref().ok_or("服务器未启动")?;
        let types = handle.device_types();
        let mobile = types.iter().filter(|t| *t == "mobile").count();
        let desktop = types.iter().filter(|t| *t == "desktop").count();
        let (count, total_size, total_duration_ms) = handle.stats();
        let texts: Vec<serde_json::Value> = handle
            .text_history()
            .iter()
            .map(|t| serde_json::json!({ "text": t.text, "at_ms": t.received_at_ms }))
            .collect();
        let records: Vec<serde_json::Value> = handle
            .received_files()
            .iter()
            .map(|r| {
                serde_json::json!({
                    "file_name": r.file_name,
                    "file_size": r.file_size,
                    "received_at_ms": r.received_at_ms,
                    "duration_ms": r.duration_ms,
                    "source": r.source,
                })
            })
            .collect();
        Ok(serde_json::json!({
            "connected": handle.connected_count(),
            "mobile": mobile,
            "desktop": desktop,
            "ip": handle.ip,
            "port": handle.port,
            "code": handle.code,
            "stats": {
                "count": count,
                "total_size": total_size,
                "total_duration_ms": total_duration_ms,
            },
            "records": records,
            "texts": texts,
        }))
    })();

    result_to_cstring(result)
}

/// 清空接收记录与文本历史。
/// 返回 JSON：`{"ok":true}` 或 `{"error":"..."}`。
#[no_mangle]
pub extern "C" fn quix_server_clear_records() -> *mut c_char {
    let result = (|| -> Result<serde_json::Value, String> {
        let handle = {
            let guard = SERVER.lock().expect("服务端句柄锁被毒化");
            guard.as_ref().cloned().ok_or("服务器未启动")?
        };
        runtime()
            .block_on(handle.clear_records())
            .map_err(|e| format!("{e:#}"))?;
        Ok(serde_json::json!({ "ok": true }))
    })();

    result_to_cstring(result)
}

/// 断开所有已连接的客户端（服务保持运行）。
/// 返回 JSON：`{"ok":true}` 或 `{"error":"..."}`。
#[no_mangle]
pub extern "C" fn quix_server_disconnect_all() -> *mut c_char {
    let result = (|| -> Result<serde_json::Value, String> {
        let handle = {
            let guard = SERVER.lock().expect("服务端句柄锁被毒化");
            guard.as_ref().cloned().ok_or("服务器未启动")?
        };
        runtime().block_on(handle.disconnect_all());
        Ok(serde_json::json!({ "ok": true }))
    })();

    result_to_cstring(result)
}

/// 释放 quix_server_* / quix_zt_* 返回的字符串。
#[no_mangle]
pub extern "C" fn quix_server_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(ptr));
    }
}

// ==================== 内嵌 ZeroTier（Windows）====================

/// 加入 ZeroTier 网络并等待授权与分配 IP（阻塞调用，最长 180 秒，
/// Dart 侧应在后台 Isolate 调用）。
/// 入参为网络 ID 字符串；返回 JSON：`{"ip","node_address"}` 或 `{"error":"..."}`。
#[cfg(windows)]
#[no_mangle]
pub extern "C" fn quix_zt_join(network_id: *const c_char) -> *mut c_char {
    let result = (|| -> Result<serde_json::Value, String> {
        let nwid = unsafe { cstr_to_string(network_id) };
        let r = ztembed::join(&nwid, std::time::Duration::from_secs(180))
            .map_err(|e| format!("{e:#}"))?;
        Ok(serde_json::json!({
            "ip": r.ip,
            "node_address": format!("{:010x}", r.node_address),
        }))
    })();
    result_to_cstring(result)
}

/// 停止内嵌 ZeroTier 并清理 TUN 适配器。
#[cfg(windows)]
#[no_mangle]
pub extern "C" fn quix_zt_leave() {
    ztembed::leave();
}

/// 查询内嵌 ZeroTier 状态。
/// 返回 JSON：`{"active","online","node_address","nwid","ip"}`。
#[cfg(windows)]
#[no_mangle]
pub extern "C" fn quix_zt_status() -> *mut c_char {
    let v = match ztembed::status() {
        Some((online, node_address, nwid, ip)) => serde_json::json!({
            "active": true,
            "online": online,
            "node_address": format!("{:010x}", node_address),
            "nwid": format!("{nwid:016x}"),
            "ip": ip,
        }),
        None => serde_json::json!({ "active": false, "online": false }),
    };
    json_to_cstring(v)
}
