//! ZeroTier 跨网络组网服务
//! 桌面端：通过 zerotier-cli 管理
//! 手机端：引导官方 ZeroTier One App 加入网络，自动检测分配的 IP

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../theme/tokens.dart';
import 'quix_core_ffi.dart';
import 'zerotier_vpn_controller.dart';

class ZerotierService {
  /// 官方 ZeroTier One Android App 包名
  static const _ztPackage = 'com.zerotier.one';

  /// 原生通道（检测/启动外部 App）
  static const _channel = MethodChannel('quix/native');

  /// 检测系统是否安装 ZeroTier
  static Future<bool> isInstalled() async {
    if (Platform.isAndroid) {
      try {
        return await _channel.invokeMethod<bool>(
              'isAppInstalled',
              {'pkg': _ztPackage},
            ) ??
            false;
      } catch (_) {
        return false;
      }
    }
    if (Platform.isWindows) {
      // Windows 端 ZeroTier 核心已内嵌，无需单独安装官方客户端
      return true;
    }
    return File('/usr/local/bin/zerotier-cli').existsSync();
  }

  /// 加入指定网络并等待获取 IP
  static Future<String?> joinAndWaitIp(String networkId) async {
    if (Platform.isAndroid) {
      // Android：通过内嵌 ZeroTier VPN 组网
      return ZerotierVpnController.joinAndWaitIp(networkId);
    }
    if (Platform.isWindows) {
      // Windows：内嵌 ZeroTier 核心 FFI 组网；统一结果解析（R21）
      return QuixCoreFfi.ztJoinAndGetIp(networkId,
          failHint: 'ZeroTier 未返回有效 IP');
    }
    // Linux/macOS：zerotier-cli 兜底
    final cli = '/usr/local/bin/zerotier-cli';

    // 先 join
    final join = await Process.run(cli, ['join', networkId]);
    if (join.exitCode != 0) {
      throw Exception('加入网络失败: ${join.stderr}');
    }

    // 轮询等待 IP（网络需在 my.zerotier.com 授权后才会分配 IP）
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final r = await Process.run(cli, ['listnetworks']);
      if (r.exitCode == 0) {
        final lines = r.stdout.toString().split('\n');
        for (final line in lines) {
          if (line.contains(networkId)) {
            final parts = line.trim().split(RegExp(r'\s+'));
            if (parts.length >= 9) {
              final ip = parts[8];
              if (ip.isNotEmpty && ip != '-' && !ip.startsWith('127.')) {
                return ip;
              }
            }
          }
        }
      }
    }
    return null;
  }

  // ============ 移动端：引导官方 App 组网 ============

  /// 启动 ZeroTier App（返回是否成功）
  static Future<bool> _launchMobileApp() async {
    try {
      return await _channel.invokeMethod<bool>(
            'launchApp',
            {'pkg': _ztPackage},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 打开应用商店的 ZeroTier 页面
  static Future<void> _openAppStore() async {
    final uri = Uri.parse(
      'https://play.google.com/store/apps/details?id=$_ztPackage',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// 快照当前全部全局 IPv4 地址
  static Future<Set<String>> _snapshotIpv4() async {
    final set = <String>{};
    final interfaces = await NetworkInterface.list();
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (addr.type == InternetAddressType.IPv4 && !ip.startsWith('127.')) {
          set.add(ip);
        }
      }
    }
    return set;
  }

  /// 等待基线之外出现新的 IPv4 地址（即 ZeroTier 分配的地址）
  static Future<String?> waitForNewIp(
    Set<String> baseline, {
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final current = await _snapshotIpv4();
      final diff = current.difference(baseline);
      if (diff.isNotEmpty) return diff.first;
      await Future.delayed(const Duration(seconds: 2));
    }
    return null;
  }

  /// 弹出操作引导弹窗，等待用户点击"打开 ZeroTier"
  static Future<void> _showGuideSheet(String networkId, bool installed) {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return Future.value();
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: QxColors.surface2,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final steps = installed
            ? [
                '网络 ID 已复制，点击下方按钮打开 ZeroTier One',
                '点右上角 + 号，粘贴网络 ID 并加入',
                '打开网络开关，授予 VPN 连接权限',
                '在电脑浏览器 my.zerotier.com 的网络成员中勾选授权本机',
                '保持 ZeroTier 连接，返回 QuiX 即会自动完成组网',
              ]
            : [
                '点击下方按钮前往应用商店安装 ZeroTier One',
                '打开 ZeroTier One，按提示授予 VPN 权限',
                '点右上角 + 号，输入网络 ID（已复制，可粘贴）并加入',
                '在电脑浏览器 my.zerotier.com 的网络成员中勾选授权本机',
                '保持 ZeroTier 连接，返回 QuiX 即会自动完成组网',
              ];
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ZeroTier 跨网络组网',
                style: TextStyle(
                  color: QxColors.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        margin: const EdgeInsets.only(right: 10, top: 1),
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: QxColors.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          steps[i],
                          style: const TextStyle(
                            color: QxColors.textSecondary,
                            fontSize: 13.5,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Container(
                margin: const EdgeInsets.only(top: 4, bottom: 16),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: QxColors.bg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.vpn_key_outlined,
                        size: 15, color: QxColors.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SelectableText(
                        networkId,
                        style: const TextStyle(
                          color: QxColors.textPrimary,
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    const Text('已复制',
                        style: TextStyle(
                            color: QxColors.primary, fontSize: 12)),
                  ],
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: Icon(
                    installed ? Icons.open_in_new : Icons.download,
                    size: 17,
                  ),
                  label: Text(installed ? '打开 ZeroTier 并继续' : '前往安装 ZeroTier'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: QxColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 完整手机端引导流程：
  /// 复制网络 ID → 展示步骤 → 打开 App/商店 → 等待 ZeroTier 分配 IP
  /// 返回分配到的 IP；超时/取消返回 null
  static Future<String?> runMobileGuide(String networkId) async {
    if (!Platform.isAndroid) return null;

    await Clipboard.setData(ClipboardData(text: networkId));
    final baseline = await _snapshotIpv4();
    final installed = await isInstalled();
    await _showGuideSheet(networkId, installed);

    if (installed) {
      final ok = await _launchMobileApp();
      if (!ok) await _openAppStore();
    } else {
      await _openAppStore();
    }

    return waitForNewIp(baseline);
  }
}
