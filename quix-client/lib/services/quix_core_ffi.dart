//! QuiX 服务端动态库 FFI 桥接（「我接收」/服务端模式）
//!
//! 通过 dart:ffi 调用 quix_core.dll / libquix_core.so 暴露的 C ABI：
//! - quix_server_start(config_json) -> JSON {ip,port,code}
//! - quix_server_stop()
//! - quix_server_status() -> JSON {connected,ip,port,code}
//! - quix_server_free(ptr)
//! - quix_zt_join(nwid) -> JSON {ip,node_address}（仅 Windows，阻塞调用）
//! - quix_zt_leave()（仅 Windows）
//! - quix_zt_status() -> JSON {active,online,ip}（仅 Windows）

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

// FFI 函数签名（typedef 必须声明在顶层，不能放在类内）
typedef _StartNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _StartDart = Pointer<Utf8> Function(Pointer<Utf8>);

typedef _StopNative = Void Function();
typedef _StopDart = void Function();

typedef _StatusNative = Pointer<Utf8> Function();
typedef _StatusDart = Pointer<Utf8> Function();

typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

typedef _ClearRecordsNative = Pointer<Utf8> Function();
typedef _ClearRecordsDart = Pointer<Utf8> Function();

typedef _ZtJoinNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _ZtJoinDart = Pointer<Utf8> Function(Pointer<Utf8>);

typedef _ZtLeaveNative = Void Function();
typedef _ZtLeaveDart = void Function();

typedef _ZtStatusNative = Pointer<Utf8> Function();
typedef _ZtStatusDart = Pointer<Utf8> Function();

/// 动态库 FFI 桥接（单例式静态方法）
class QuixCoreFfi {
  static DynamicLibrary? _lib;
  static bool _loaded = false;

  static late final _StartDart _start;
  static late final _StopDart _stop;
  static late final _StatusDart _status;
  static late final _FreeDart _free;
  static late final _ClearRecordsDart _clearRecords;
  static late final _ClearRecordsDart _disconnectAll;
  // 内嵌 ZeroTier（仅 Windows 符号存在；其他平台不 lookup）
  static late final _ZtJoinDart _ztJoin;
  static late final _ZtLeaveDart _ztLeave;
  static late final _ZtStatusDart _ztStatus;

  /// 加载动态库（首次调用时）
  static void ensureLoaded() {
    if (_loaded) return;
    final lib = Platform.isWindows
        ? DynamicLibrary.open('quix_core.dll')
        : Platform.isAndroid
            ? DynamicLibrary.open('libquix_core.so')
            : Platform.isLinux
                ? DynamicLibrary.open('libquix_core.so')
                : Platform.isMacOS
                    ? DynamicLibrary.open('libquix_core.dylib')
                    : throw UnsupportedError('不支持的平台');
    _lib = lib;
    _start = lib.lookupFunction<_StartNative, _StartDart>('quix_server_start');
    _stop = lib.lookupFunction<_StopNative, _StopDart>('quix_server_stop');
    _status = lib.lookupFunction<_StatusNative, _StatusDart>('quix_server_status');
    _free = lib.lookupFunction<_FreeNative, _FreeDart>('quix_server_free');
    _clearRecords = lib.lookupFunction<_ClearRecordsNative, _ClearRecordsDart>('quix_server_clear_records');
    _disconnectAll = lib.lookupFunction<_ClearRecordsNative, _ClearRecordsDart>('quix_server_disconnect_all');
    if (Platform.isWindows) {
      _ztJoin = lib.lookupFunction<_ZtJoinNative, _ZtJoinDart>('quix_zt_join');
      _ztLeave = lib.lookupFunction<_ZtLeaveNative, _ZtLeaveDart>('quix_zt_leave');
      _ztStatus = lib.lookupFunction<_ZtStatusNative, _ZtStatusDart>('quix_zt_status');
    }
    _loaded = true;
  }

  /// 启动服务端，返回 `{ip, port, code}`；失败抛异常
  static Map<String, dynamic> startServer(Map<String, dynamic> config) {
    ensureLoaded();
    final ptr = jsonEncode(config).toNativeUtf8();
    try {
      final resultPtr = _start(ptr);
      return _parseResult(_readAndFree(resultPtr));
    } finally {
      malloc.free(ptr);
    }
  }

  /// 停止服务端
  static void stopServer() {
    ensureLoaded();
    _stop();
  }

  /// 获取服务端状态，返回 `{connected, ip, port, code}`；失败抛异常
  static Map<String, dynamic> status() {
    ensureLoaded();
    final resultPtr = _status();
    return _parseResult(_readAndFree(resultPtr));
  }

  /// 清空接收记录与文本历史
  static void clearRecords() {
    ensureLoaded();
    final resultPtr = _clearRecords();
    _parseResult(_readAndFree(resultPtr));
  }

  /// 断开所有已连接的客户端
  static void disconnectAll() {
    ensureLoaded();
    final resultPtr = _disconnectAll();
    _parseResult(_readAndFree(resultPtr));
  }

  /// 读取 C 字符串并调用 quix_server_free 释放
  static String _readAndFree(Pointer<Utf8> ptr) {
    if (ptr == nullptr) return '{}';
    final str = ptr.toDartString();
    _free(ptr);
    return str;
  }

  /// 解析结果 JSON；含 error 字段则抛异常
  static Map<String, dynamic> _parseResult(String jsonStr) {
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    if (map.containsKey('error')) {
      throw Exception(map['error']);
    }
    return map;
  }

  // ==================== 内嵌 ZeroTier（仅 Windows）====================

  /// 加入 ZeroTier 网络并等待授权与 IP（后台 Isolate 执行，UI 不阻塞；
  /// Rust 侧最长阻塞 180 秒等待 my.zerotier.com 授权）。
  /// 返回 `{ip, node_address}`；失败抛异常。
  static Future<Map<String, dynamic>> ztJoin(String networkId) {
    return Isolate.run(() => ztJoinSync(networkId));
  }

  /// 加入 ZeroTier 网络并返回分配到的 IP；未返回 IP（未授权/超时等）则抛异常。
  // R21：统一各调用点对 ztJoin 结果（error/ip）的重复解析
  static Future<String> ztJoinAndGetIp(
    String networkId, {
    String failHint = 'ZeroTier 未返回有效 IP，请确认已在网络中授权本设备',
  }) async {
    final result = await ztJoin(networkId); // _parseResult 已在含 error 时抛异常
    final ip = result['ip'] as String?;
    if (ip == null || ip.isEmpty) {
      throw Exception(failHint);
    }
    return ip;
  }

  /// 同步版加入（阻塞当前 isolate，勿在 UI isolate 调用）
  static Map<String, dynamic> ztJoinSync(String networkId) {
    ensureLoaded();
    final ptr = networkId.toNativeUtf8();
    try {
      final resultPtr = _ztJoin(ptr);
      return _parseResult(_readAndFree(resultPtr));
    } finally {
      malloc.free(ptr);
    }
  }

  /// 停止内嵌 ZeroTier 并清理 TUN 适配器（仅 Windows）
  static void ztLeave() {
    if (!Platform.isWindows) return;
    ensureLoaded();
    _ztLeave();
  }

  /// 查询内嵌 ZeroTier 状态（仅 Windows）。
  /// 返回 `{active, online, node_address, nwid, ip}`。
  static Map<String, dynamic> ztStatus() {
    if (!Platform.isWindows) return {'active': false, 'online': false};
    ensureLoaded();
    final resultPtr = _ztStatus();
    return _parseResult(_readAndFree(resultPtr));
  }
}
