//! 模式切换控件：左「接收」/ 右「发送」，当前模式高亮
//! 已连接状态下切换需弹窗确认（符合 PRD 模式切换约束）
//! 桌面端显示 SegmentedButton，移动端通过首页图标入口调用 requestModeChange

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_mode.dart';
import '../providers/app_provider.dart';
import '../providers/receive_provider.dart';
import '../providers/transfer_provider.dart';
import '../theme/tokens.dart';

/// 模式切换控件（桌面端右上角 / 侧边栏）
class ModeSwitch extends StatelessWidget {
  const ModeSwitch({super.key});

  /// 请求切换到指定模式（含活动连接确认与断开），供各端入口复用
  static Future<void> requestModeChange(
      BuildContext context, AppMode target) async {
    final app = context.read<AppProvider>();
    if (target == app.mode) return;

    final transfer = context.read<TransferProvider>();
    final receive = context.read<ReceiveProvider>();

    // 当前模式存在活动连接（发送端已连接 / 接收端有设备接入）时需确认
    final hasActiveConnection =
        (app.mode == AppMode.send && transfer.isConnected) ||
            (app.mode == AppMode.receive && receive.connectedCount > 0);

    if (hasActiveConnection) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: QxColors.surface2,
          title: const Text('切换模式', style: TextStyle(color: Colors.white)),
          content: const Text(
            '当前已连接设备，切换模式将断开连接，确认继续？',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('继续', style: TextStyle(color: QxColors.danger)),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      // 断开当前模式下的连接后再切换
      if (app.mode == AppMode.send) {
        await transfer.disconnect();
      } else {
        receive.stop();
      }
    }

    await app.setMode(target);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppProvider>();
    // 移动端顶栏空间紧张：缩小字号/内边距/高度，避免横向溢出 11px
    final compact = Platform.isAndroid || Platform.isIOS;
    return SegmentedButton<AppMode>(
      segments: const [
        ButtonSegment(value: AppMode.receive, label: Text('接收')),
        ButtonSegment(value: AppMode.send, label: Text('发送')),
      ],
      selected: {app.mode},
      onSelectionChanged: (s) => requestModeChange(context, s.first),
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(
            horizontal: compact ? 9 : 12)),
        minimumSize:
            WidgetStatePropertyAll(Size(0, compact ? 30 : 36)),
        textStyle: WidgetStatePropertyAll(
            TextStyle(fontSize: compact ? 12 : 13)),
        side: const WidgetStatePropertyAll(BorderSide(color: QxColors.border)),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          // 选中态：青色实底 + 深色文字，保证清晰可读、无重叠
          if (states.contains(WidgetState.selected)) {
            return QxColors.primary;
          }
          return Colors.transparent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return QxColors.onPrimary;
          }
          return QxColors.primary;
        }),
      ),
    );
  }
}
