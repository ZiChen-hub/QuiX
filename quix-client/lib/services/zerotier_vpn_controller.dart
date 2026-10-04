//! 内嵌 ZeroTier VPN 控制器（Android 专属）
//! 通过 MethodChannel quix/zerotier_vpn 调用 Kotlin 侧桥接

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class ZerotierVpnController {
  static const _channel = MethodChannel('quix/zerotier_vpn');

  /// 加入指定 ZeroTier 网络并等待获取分配的 IPv4 地址。
  ///
  /// 流程：VPN 授权弹窗 → 启动/绑定前台 VPN 服务 → join → 等待 IP 分配。
  /// 需要用户在 my.zerotier.com 授权本设备后才会分配 IP。
  ///
  /// [timeout] 整体超时（默认 3 分钟）。
  /// 返回分配到的 IPv4 地址；超时或失败抛异常。
  static Future<String> joinAndWaitIp(
    String networkId, {
    Duration timeout = const Duration(minutes: 3),
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('内嵌 ZeroTier VPN 仅支持 Android');
    }
    final completer = Completer<String>();
    late Timer timer;
    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('ZeroTier VPN 组网超时（${timeout.inMinutes} 分钟）'),
        );
      }
    });
    _channel
        .invokeMethod<String>('joinAndWaitIp', {'networkId': networkId})
        .then((ip) {
      if (!completer.isCompleted) {
        timer.cancel();
        if (ip != null && ip.isNotEmpty) {
          completer.complete(ip);
        } else {
          completer.completeError(Exception('ZeroTier 未返回有效 IP'));
        }
      }
    }).catchError((e) {
      if (!completer.isCompleted) {
        timer.cancel();
        completer.completeError(e);
      }
    });
    return completer.future;
  }

  /// 停止内嵌 ZeroTier VPN 服务并解绑。
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {
      // 忽略停止异常
    }
  }

  /// 检查内嵌 VPN 服务是否正在运行。
  static Future<bool> isRunning() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      return false;
    }
  }
}
