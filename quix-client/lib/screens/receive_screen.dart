//! 接收模式（服务端）首页：连接信息、扫码连接、统计与记录

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/app_mode.dart';
import '../providers/receive_provider.dart';
import '../theme/tokens.dart';
import '../utils/formatter.dart';
import '../widgets/logo.dart';
import '../widgets/manual_dialog.dart';
import '../widgets/mode_switch.dart';

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  Timer? _timer;
  ReceiveProvider? _provider;
  // 「暂不授权」提醒弹窗展示中标记（防止重复弹出）
  bool _authDialogShowing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _provider = context.read<ReceiveProvider>();
      _provider!.start();
      _provider!.onTextReceived = _onTextReceived;
      _provider!.addListener(_onProviderChanged);
      _timer = Timer.periodic(const Duration(seconds: 2), (_) {
        _provider?.refreshStatus();
      });
    });
  }

  /// 监听跨网络「已开启但未授权」状态：弹出授权提醒（单按钮）
  void _onProviderChanged() {
    final p = _provider;
    if (p == null || !mounted) return;
    if (p.crossAuthReminderNeeded && !_authDialogShowing) {
      _authDialogShowing = true;
      p.consumeCrossAuthReminder();
      _showCrossAuthReminderDialog();
    }
  }

  /// 授权提醒弹窗：唯一按钮「暂不授权，启动局域网直连服务」
  /// 点击后自动关闭设置页中的跨网络开关（ID 保留但隐藏），服务以局域网直连重启
  Future<void> _showCrossAuthReminderDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: QxColors.surface2,
        title: const Text('跨网络组网等待授权',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          '本设备已加入 ZeroTier 网络，但尚未在该网络中授权。\n\n'
          '如需使用跨网络传输：在电脑浏览器打开 my.zerotier.com，'
          '进入对应网络的 Members 列表，勾选本设备左侧的 Auth 复选框完成授权；'
          '授权完成后重新开启跨网络传输开关即可。\n\n'
          '也可以暂时跳过授权，继续使用局域网直连传输。',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '暂不授权，启动局域网直连服务',
              style: TextStyle(color: QxColors.warning),
            ),
          ),
        ],
      ),
    );
    _authDialogShowing = false;
    if (mounted) {
      await context.read<ReceiveProvider>().disableCrossNetworkKeepId();
    }
  }

  /// 收到对端剪贴板文本：自动复制到系统剪贴板并提示
  void _onTextReceived(String text) {
    if (!mounted) return; // R17：先判断，避免 widget 销毁后再使用 context
    Clipboard.setData(ClipboardData(text: text));
    final preview = text.length > 40 ? '${text.substring(0, 40)}…' : text;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已收到并复制文本：$preview')),
    );
  }

  /// 清除传输记录（弹确认框）
  Future<void> _clearRecords() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: QxColors.surface2,
        title: const Text('清除记录', style: TextStyle(color: Colors.white)),
        content: const Text(
          '确定要清空所有传输记录吗？',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清除', style: TextStyle(color: QxColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<ReceiveProvider>().clearRecords();
    }
  }

  /// 断开所有已连接的客户端
  Future<void> _disconnectAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: QxColors.surface2,
        title: const Text('断开连接', style: TextStyle(color: Colors.white)),
        content: const Text(
          '确定要断开所有已连接的设备吗？',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('断开', style: TextStyle(color: QxColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<ReceiveProvider>().disconnectAll();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _provider?.removeListener(_onProviderChanged);
    _provider?.onTextReceived = null; // R17：摘除回调，避免销毁后仍被原生侧触发
    _provider?.stop();
    super.dispose();
  }

  void _copyUri() {
    final uri = context.read<ReceiveProvider>().connectUri;
    if (uri.isEmpty) return;
    Clipboard.setData(ClipboardData(text: uri));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('连接信息已复制')));
    }
  }

  /// 弹出二维码模态框
  void _showQrDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => const _QrDialog(),
    );
  }

  /// 弹出接收模式设置
  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: QxColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (_) => const _ReceiveSettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<ReceiveProvider>();
    const success = QxColors.success;
    const primary = QxColors.primary;

    return Scaffold(
      backgroundColor: QxColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Logo(fontSize: 20),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
            tooltip: '设置',
            onPressed: _showSettings,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: const ModeSwitch()),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 连接信息卡片
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: QxColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: QxColors.border),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: p.running ? success : Colors.white24,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Expanded（tight）是行内唯一弹性子项：占满剩余空间，
                      // 行尾的复制按钮作为普通子项自然贴齐卡片右缘，
                      // 与下方 IP/端口等值的右边缘对齐
                      // （不能用 Flexible+Spacer：多个弹性子项会平分空间，
                      // 剩余空间不会让给行尾子项，导致按钮悬在行中）
                      Expanded(
                        child: GestureDetector(
                          onTap: (p.running &&
                                  Platform.isAndroid &&
                                  p.isCrossNetworkService &&
                                  p.crossIp.isEmpty &&
                                  !p.crossNetworkBusy)
                              ? () => p.configureMobileCrossNetwork()
                              : null,
                          child: Text(
                            p.statusMessage,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: (p.running &&
                                      Platform.isAndroid &&
                                      p.isCrossNetworkService &&
                                      p.crossIp.isEmpty &&
                                      !p.crossNetworkBusy)
                                  ? primary
                                  : Colors.white70,
                            ),
                          ),
                        ),
                      ),
                      if (p.running)
                        // 复制按钮：无水平内边距的裸 Row，「复制」文字右边缘
                        // 与下方 IP/端口/连接码等值的右边缘严格贴齐
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _copyUri,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(Icons.copy, size: 14, color: primary),
                                SizedBox(width: 4),
                                Text('复制',
                                    style: TextStyle(
                                        color: primary, fontSize: 13)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _InfoRow(label: 'IP 地址', value: p.running ? p.ip : '--'),
                  // 跨网络组网启用时显示跨网络 IP；
                  // 组网中显示「正在组网...」，未授权显示「暂未授权」
                  if (p.isCrossNetworkService) ...[
                    const SizedBox(height: 8),
                    _InfoRow(
                      label: '跨网络 IP',
                      value: (p.running || p.serviceStarting)
                          ? p.crossIpDisplay
                          : '--',
                    ),
                  ],
                  const SizedBox(height: 8),
                  _InfoRow(label: '端口', value: p.running ? '${p.port}' : '--'),
                  const SizedBox(height: 8),
                  _InfoRow(label: '连接码', value: p.running ? p.code : '--------'),
                  const SizedBox(height: 8),
                  _InfoRow(label: '已连接设备', value: '${p.connectedCount} 台'),
                  if (p.connectedCount > 0) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _disconnectAll,
                        icon: const Icon(Icons.link_off, size: 16, color: QxColors.danger),
                        label: const Text(
                          '断开连接',
                          style: TextStyle(color: QxColors.danger, fontSize: 13),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: QxColors.danger),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),

            // 扫码连接按钮（未连接时显示；连接后自动隐藏）
            if (p.running && p.connectedCount == 0) ...[
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _showQrDialog,
                  icon: const Icon(Icons.qr_code_scanner, color: primary),
                  label: const Text('扫码连接', style: TextStyle(color: primary)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: primary),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],

            // 剪贴板文本历史
            Row(
              children: [
                Text(
                  '剪贴板文本',
                  style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.7)),
                ),
                const Spacer(),
                Text(
                  '${p.textHistory.length} 条',
                  style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.4)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (p.textHistory.isEmpty)
              Text(
                '暂无收到的文本',
                style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.35)),
              )
            else
              ...p.textHistory
                  .map((t) => _TextTile(text: t.text, receivedAt: t.receivedAt))
                  .toList(),
            const SizedBox(height: 20),

            // 传输记录
            Row(
              children: [
                Text(
                  '传输记录',
                  style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.7)),
                ),
                const Spacer(),
                if (p.records.isNotEmpty || p.textHistory.isNotEmpty)
                  TextButton(
                    onPressed: _clearRecords,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      '清除记录',
                      style: TextStyle(fontSize: 12, color: QxColors.danger),
                    ),
                  ),
                Text(
                  '${p.records.length} 个',
                  style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.4)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (p.records.isEmpty)
              Text(
                '暂无传输记录',
                style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.35)),
              )
            else
              ...p.records.map((r) => _RecordTile(record: r)).toList(),
          ],
        ),
      ),
    );
  }
}

// ===== 二维码模态框（连接成功后自动关闭） =====
class _QrDialog extends StatefulWidget {
  const _QrDialog();

  @override
  State<_QrDialog> createState() => _QrDialogState();
}

class _QrDialogState extends State<_QrDialog> {
  ReceiveProvider? _provider;

  @override
  void initState() {
    super.initState();
    _provider = context.read<ReceiveProvider>();
    _provider!.addListener(_onProviderChanged);
  }

  void _onProviderChanged() {
    if (_provider != null && _provider!.connectedCount > 0 && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _provider?.removeListener(_onProviderChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<ReceiveProvider>();
    return Dialog(
      backgroundColor: QxColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '扫码连接',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: p.connectUri,
                version: QrVersions.auto,
                size: 200,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '使用手机 QuiX 扫描二维码建立连接',
              style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.5)),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭', style: TextStyle(color: QxColors.primary)),
            ),
          ],
        ),
      ),
    );
  }
}

// ===== 接收模式设置（接收目录 + 系统信息） =====
class _ReceiveSettingsSheet extends StatelessWidget {
  const _ReceiveSettingsSheet();

  Future<void> _pickReceiveDir(BuildContext context) async {
    if (Platform.isAndroid) {
      // Android：打开真实文件系统目录选择器（需授予"所有文件访问"权限，
      // Rust std::fs 才能写入任意路径）
      final path = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const _AndroidDirPicker()),
      );
      if (path != null && path.isNotEmpty && context.mounted) {
        await context.read<ReceiveProvider>().setReceiveDir(path);
      }
      return;
    }
    final path = await FilePicker.platform.getDirectoryPath();
    if (path != null && path.isNotEmpty && context.mounted) {
      await context.read<ReceiveProvider>().setReceiveDir(path);
    }
  }

  Widget _paramTile({
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: QxColors.surface2,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(fontSize: 13, color: Colors.white70)),
            ),
            Text(value, style: const TextStyle(fontSize: 13, color: Colors.white)),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, size: 18, color: Colors.white38),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<ReceiveProvider>();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('设置', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white)),
            const SizedBox(height: 20),
            Text('接收目录', style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.45))),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _pickReceiveDir(context),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  color: QxColors.surface2,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.folder_open, size: 18, color: QxColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        p.receiveDir.isEmpty
                            ? (Platform.isAndroid
                                ? '默认（应用专属目录/QuiX）'
                                : '默认（系统文档目录/QuiX）')
                            : p.receiveDir,
                        style: const TextStyle(fontSize: 13, color: Colors.white),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 18, color: Colors.white38),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '更改接收目录后，服务将自动重启并立即生效',
              style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.35)),
            ),
            const SizedBox(height: 20),
            const _CustomCodeInput(),
            const SizedBox(height: 20),
            const _CrossNetworkSetting(),
            const SizedBox(height: 20),
            Text('系统信息', style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.45))),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: QxColors.surface2,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  _SheetInfoRow(label: 'IP 地址', value: p.running ? p.ip : '--'),
                  _SheetInfoRow(label: '端口', value: p.running ? '${p.port}' : '--'),
                  _SheetInfoRow(label: '连接码', value: p.running ? p.code : '--------'),
                  if (p.certFingerprint.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('证书指纹', style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.45))),
                          const SizedBox(height: 4),
                          Text(
                            p.certFingerprint,
                            style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.75), fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ),
                  _SheetInfoRow(label: '平台', value: _platformLabel()),
                  _SheetInfoRow(label: '版本', value: 'v1.6.3'),
                  _SheetInfoRow(label: '协议', value: 'QUIC'),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text('帮助', style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.45))),
            const SizedBox(height: 8),
            _paramTile(
              label: '操作手册',
              value: '查看详细使用说明',
              onTap: () => showManualDialog(context, AppMode.receive),
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomCodeInput extends StatefulWidget {
  const _CustomCodeInput();

  @override
  State<_CustomCodeInput> createState() => _CustomCodeInputState();
}

class _CustomCodeInputState extends State<_CustomCodeInput> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = context.read<ReceiveProvider>();
      if (_controller.text.isEmpty && p.customCode.isNotEmpty) {
        _controller.text = p.customCode;
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('自定义连接码', style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.45))),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          onChanged: (v) => context.read<ReceiveProvider>().setCustomCode(v),
          style: const TextStyle(fontSize: 13, color: Colors.white),
          decoration: InputDecoration(
            hintText: '留空则自动生成',
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
            filled: true,
            fillColor: QxColors.surface2,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '留空则自动生成 8 位连接码；修改后下次启动服务时生效',
          style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.35)),
        ),
      ],
    );
  }
}

/// 跨网络传输开关设置：开关 + 子标签（网络 ID / 跨网络 IP）+ 组网弹窗
class _CrossNetworkSetting extends StatelessWidget {
  const _CrossNetworkSetting();

  Future<void> _onToggle(BuildContext context, bool enabled) async {
    final p = context.read<ReceiveProvider>();
    if (!enabled) {
      await p.setCrossNetworkEnabled(false);
      return;
    }
    // 首次开启（未填写网络 ID）时弹出组网弹窗；取消则回退开关
    if (p.zerotierNetworkId.isEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _ZerotierJoinDialog(),
      );
      if (confirmed != true && context.mounted) {
        await context.read<ReceiveProvider>().setCrossNetworkEnabled(false);
      }
    } else {
      await p.setCrossNetworkEnabled(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<ReceiveProvider>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 开关（左关右开），作为 ZeroTier 网络 ID 输入框的父标签
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: QxColors.surface2,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(Icons.lan_outlined, size: 18, color: QxColors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text('跨网络传输',
                    style: const TextStyle(fontSize: 13, color: Colors.white)),
              ),
              Switch(
                value: p.crossNetworkEnabled,
                activeColor: QxColors.primary,
                onChanged: (v) => _onToggle(context, v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '开启后通过 ZeroTier 跨局域网传输；关闭时仅局域网直连',
          style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.35)),
        ),
        // 开关开启时显示子标签；关闭状态下全部隐藏
        if (p.crossNetworkEnabled) ...[
          const SizedBox(height: 8),
          InkWell(
            // 始终可点击：未设置时填写，已设置时修改（弹窗内预填当前 ID）
            onTap: () => showDialog(
                context: context,
                builder: (_) => const _ZerotierJoinDialog()),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: QxColors.surface2,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  // 标签用固定宽度（不用 Expanded），值侧 Expanded 是行内
                  // 唯一弹性子项并 textAlign 右对齐：ID 与编辑图标贴齐行右缘，
                  // 与下方「跨网络 IP」行的值对齐
                  Text('ZeroTier 网络 ID',
                      style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withOpacity(0.7))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      p.zerotierNetworkId.isEmpty ? '未设置，点击填写' : p.zerotierNetworkId,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                          color: p.zerotierNetworkId.isEmpty
                              ? Colors.white.withOpacity(0.4)
                              : Colors.white),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  // 编辑图标：提示网络 ID 可点击修改
                  const Icon(Icons.edit_outlined,
                      size: 14, color: QxColors.primary),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: QxColors.surface2,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text('跨网络 IP',
                      style: TextStyle(
                          fontSize: 13, color: Colors.white.withOpacity(0.7))),
                ),
                Text(
                  p.crossIpDisplay,
                  style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// ZeroTier 组网弹窗：输入网络 ID → 测试组网 → 授权引导 → 获取跨网络 IP
class _ZerotierJoinDialog extends StatefulWidget {
  const _ZerotierJoinDialog();

  @override
  State<_ZerotierJoinDialog> createState() => _ZerotierJoinDialogState();
}

class _ZerotierJoinDialogState extends State<_ZerotierJoinDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _testing = false; // 正在加入网络（等待授权）
  bool _guideExpanded = false; // 「如何获取网络 ID」指南展开状态
  String? _error; // 组网失败信息
  bool _closed = false; // 弹窗已关闭（后台 join 完成时不再操作 UI）

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final id = context.read<ReceiveProvider>().zerotierNetworkId;
      if (_controller.text.isEmpty && id.isNotEmpty) {
        _controller.text = id;
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _close([bool confirmed = false]) {
    _closed = true;
    Navigator.of(context).pop(confirmed);
  }

  /// 「测试组网」：加入网络并等待授权；成功自动关闭弹窗，失败回输入态显示错误
  Future<void> _testJoin() async {
    final id = _controller.text.trim();
    setState(() {
      _testing = true;
      _error = null;
    });
    final future = context.read<ReceiveProvider>().testJoinCrossNetwork(id);
    // 等待期间展示授权引导（同一弹窗内容切换）
    unawaited(future.then((error) {
      if (!mounted || _closed) return;
      if (error == null) {
        // 授权成功：自动关闭所有弹窗
        _close(true);
      } else {
        // 组网失败：回到输入态并显示失败信息
        setState(() {
          _testing = false;
          _error = error;
        });
      }
    }));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: QxColors.surface2,
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      title: Text(
        _testing ? '等待 ZeroTier 网络授权' : '跨网络组网（ZeroTier）',
        style: const TextStyle(color: Colors.white, fontSize: 17),
      ),
      content: SingleChildScrollView(
        child: _testing
            ? _buildAuthGuide()
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '填写 ZeroTier 网络 ID，加入后即可与其他网络内的设备跨网传输',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _controller,
                    autofocus: true,
                    style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white,
                        fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: '例如 8d1c312afa8b5107',
                      hintStyle:
                          TextStyle(color: Colors.white.withOpacity(0.3)),
                      filled: true,
                      fillColor: QxColors.bg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      style:
                          const TextStyle(color: QxColors.danger, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 4),
                  // 可折叠的获取网络 ID 指南（默认折叠）
                  Theme(
                    data: Theme.of(context)
                        .copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      initiallyExpanded: _guideExpanded,
                      onExpansionChanged: (v) => _guideExpanded = v,
                      iconColor: QxColors.primary,
                      collapsedIconColor: QxColors.primary,
                      title: const Text(
                        '如何获取 ZeroTier 网络 ID？',
                        style: TextStyle(color: QxColors.primary, fontSize: 13),
                      ),
                      children: _numberedSteps(
                        _guideSteps(),
                        circleSize: 18,
                        circleFontSize: 10,
                        stepFontSize: 12,
                        stepColor: Colors.white.withOpacity(0.7),
                        spacing: 8,
                      ),
                    ),
                  ),
                ],
              ),
      ),
      actions: _testing
          ? [
              // 等待授权期间仅提供「暂时跳过」
              TextButton(
                onPressed: () => _close(false),
                child: const Text('暂时跳过',
                    style: TextStyle(color: Colors.white54)),
              ),
            ]
          : [
              // 左下角取消 / 右下角测试组网
              TextButton(
                onPressed: () => _close(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: _testJoin,
                child: const Text('测试组网'),
              ),
            ],
    );
  }

  /// 等待授权引导内容（详细步骤）
  Widget _buildAuthGuide() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '本设备已加入网络，需要你在 ZeroTier 中授权后才能获取跨网络 IP：',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(height: 12),
        ..._numberedSteps(
          _authSteps(),
          circleSize: 20,
          circleFontSize: 11,
          stepFontSize: 13,
          stepColor: Colors.white70,
          boldStep: true,
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: QxColors.bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.badge_outlined,
                  size: 15, color: Colors.white54),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  _controller.text.trim(),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child:
                  CircularProgressIndicator(strokeWidth: 2, color: QxColors.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '授权完成后会自动完成组网并关闭本弹窗（最长等待 3 分钟）',
                style:
                    TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 构建带序号圆圈的步骤列表
  List<Widget> _numberedSteps(
    List<String> steps, {
    required double circleSize,
    required double circleFontSize,
    required double stepFontSize,
    required Color stepColor,
    double spacing = 8,
    bool boldStep = false,
  }) {
    return List.generate(steps.length, (i) {
      return Padding(
        padding: EdgeInsets.only(bottom: spacing),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: circleSize,
              height: circleSize,
              margin: EdgeInsets.only(right: spacing, top: 1),
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: QxColors.primary,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${i + 1}',
                style: TextStyle(
                    color: Colors.white, fontSize: circleFontSize),
              ),
            ),
            Expanded(
              child: Text(
                steps[i],
                style: TextStyle(
                    color: stepColor,
                    fontSize: stepFontSize,
                    height: 1.4,
                    fontWeight:
                        boldStep ? FontWeight.w600 : FontWeight.normal),
              ),
            ),
          ],
        ),
      );
    });
  }

  List<String> _guideSteps() => const [
        '在电脑浏览器打开 my.zerotier.com，注册并登录 ZeroTier 账号',
        '进入 Networks 页面，点击 Create A Network 创建一个网络',
        '打开刚创建的网络，在页面顶部即可看到 16 位 Network ID',
        '将该 Network ID 复制并填入本弹窗，点击「测试组网」',
        '回到该网络的 Members 列表，勾选本设备左侧的 Auth 复选框完成授权',
        '授权后本设备会获得 10.x.x.x 的跨网络 IP，即可开始跨网传输',
      ];

  List<String> _authSteps() => const [
        '在电脑浏览器打开 my.zerotier.com 并登录你的 ZeroTier 账号',
        '进入 Networks 页面，点击下面方框中的网络 ID 进入网络详情',
        '向下滚动到 Members（成员）区域，找到本设备的条目',
        '勾选该条目最左侧的 Auth 复选框，授权本设备加入网络',
        '授权成功后本设备会自动获得跨网络 IP，QuiX 将自动完成组网',
      ];
}

// ===== Android 真实文件系统目录选择器 =====
class _AndroidDirPicker extends StatefulWidget {
  const _AndroidDirPicker();

  @override
  State<_AndroidDirPicker> createState() => _AndroidDirPickerState();
}

class _AndroidDirPickerState extends State<_AndroidDirPicker> {
  String? _root;
  String _cwd = '';
  List<Directory> _dirs = [];
  bool _loading = true;
  bool _granted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// 定位主共享存储根（/storage/emulated/0）并进入
  Future<void> _init() async {
    // 由应用外部目录上溯四级：files → <pkg> → data → Android → 0
    final base = await getExternalStorageDirectory();
    if (base == null) {
      setState(() {
        _error = '无法访问共享存储';
        _loading = false;
      });
      return;
    }
    var d = Directory(base.path);
    for (var i = 0; i < 4; i++) {
      d = d.parent;
    }
    _root = d.path;
    await _enter(d.path);
  }

  /// 检查"所有文件访问"权限并列出指定目录
  Future<void> _enter(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    var status = await Permission.manageExternalStorage.status;
    if (!status.isGranted) {
      // request() 对 manageExternalStorage 会跳转系统授权页并等待结果
      status = await Permission.manageExternalStorage.request();
    }
    if (!status.isGranted) {
      if (!mounted) return;
      setState(() {
        _granted = false;
        _cwd = path;
        _dirs = [];
        _loading = false;
      });
      return;
    }
    try {
      final entries = await Directory(path).list(followLinks: false).toList();
      final items = entries.whereType<Directory>().toList();
      items.sort(
          (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _granted = true;
        _dirs = items;
        _cwd = path;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _granted = true;
        _error = '读取目录失败：$e';
        _cwd = path;
        _loading = false;
      });
    }
  }

  /// 返回上一级（到共享存储根为止）
  void _up() {
    final root = _root;
    if (root != null && _cwd == root) return;
    _enter(Directory(_cwd).parent.path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: QxColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('选择接收目录'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 当前路径 + 返回上级
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '上级目录',
                    icon: const Icon(Icons.drive_folder_upload),
                    onPressed:
                        _root != null && _cwd != _root ? _up : null,
                  ),
                  Expanded(
                    child: Text(
                      _cwd,
                      style: const TextStyle(
                          fontSize: 12, fontFamily: 'monospace'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildBody()),
            // 选择当前目录
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _granted && !_loading
                      ? () => Navigator.of(context).pop(_cwd)
                      : null,
                  icon: const Icon(Icons.check),
                  label: const Text('选择此文件夹'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (!_granted) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_off, size: 48, color: Colors.white38),
              const SizedBox(height: 16),
              const Text(
                '自定义接收目录需要"所有文件访问"权限',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => _enter(_cwd),
                child: const Text('前往授权'),
              ),
            ],
          ),
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: Colors.white54)),
      );
    }
    if (_dirs.isEmpty) {
      return const Center(
        child: Text('该文件夹下没有子文件夹',
            style: TextStyle(color: Colors.white38)),
      );
    }
    return ListView.separated(
      itemCount: _dirs.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: QxColors.border),
      itemBuilder: (context, i) {
        final dir = _dirs[i];
        final name = dir.path.split(Platform.pathSeparator).last;
        return ListTile(
          leading: const Icon(Icons.folder, color: QxColors.primary),
          title: Text(name,
              style: const TextStyle(fontSize: 14, color: Colors.white)),
          trailing:
              const Icon(Icons.chevron_right, color: Colors.white38),
          onTap: () => _enter(dir.path),
        );
      },
    );
  }
}

class _SheetInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _SheetInfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.45))),
          Text(value, style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.45))),
        Text(
          value,
          style: const TextStyle(fontSize: 14, color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _TextTile extends StatelessWidget {
  final String text;
  final DateTime receivedAt;

  const _TextTile({required this.text, required this.receivedAt});

  @override
  Widget build(BuildContext context) {
    final hh = receivedAt.hour.toString().padLeft(2, '0');
    final mm = receivedAt.minute.toString().padLeft(2, '0');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: QxColors.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.content_copy, size: 14, color: Colors.white54),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, color: Colors.white),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$hh:$mm',
                style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.4)),
              ),
              IconButton(
                tooltip: '复制',
                icon: const Icon(Icons.copy, size: 16, color: QxColors.primary),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制')),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  final ReceivedFileEntry record;

  const _RecordTile({required this.record});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: QxColors.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.arrow_downward, size: 16, color: Colors.white54),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.fileName,
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '${Formatter.formatBytes(record.fileSize)} · '
                  '${Formatter.formatSpeed(record.bytesPerSecond)} · '
                  '用时 ${_formatDuration(record.durationMs)} · '
                  '${_formatTime(record.startedAt)}',
                  style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.45)),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 平台中文名
String _platformLabel() {
  switch (Platform.operatingSystem) {
    case 'windows':
      return 'Windows';
    case 'macos':
      return 'macOS';
    case 'linux':
      return 'Linux';
    case 'android':
      return 'Android';
    case 'ios':
      return 'iOS';
    default:
      return Platform.operatingSystem;
  }
}

/// 毫秒 → 「X分Y秒」/「Y秒」
String _formatDuration(int ms) {
  final totalSeconds = ms ~/ 1000;
  if (totalSeconds < 60) return '${totalSeconds}秒';
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '${minutes}分${seconds}秒';
}

/// 时间 → 「HH:mm」/「MM-dd HH:mm」
String _formatTime(DateTime t) {
  final now = DateTime.now();
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
  if (sameDay) return '$hh:$mm';
  final md = '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  return '$md $hh:$mm';
}
