//! 设置页：网络设置、帮助、数据、关于

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_mode.dart';
import '../providers/transfer_provider.dart';
import '../theme/tokens.dart';
import '../widgets/manual_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TransferProvider>();

    return Scaffold(
      backgroundColor: QxColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          '设置',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        children: [
          _sectionTitle('网络设置'),
          _settingItem('跨网络传输', '接收端控制'),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '跨网络（ZeroTier）由「我接收」模式设置中的「跨网络传输」开关控制，'
              '开启并完成组网后即可跨互联网传输',
              style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.35)),
            ),
          ),
          const SizedBox(height: 16),
          _sectionTitle('帮助'),
          _clickableSettingItem(
              '操作手册', '查看详细使用说明', () => showManualDialog(context, AppMode.send)),
          const SizedBox(height: 16),
          _sectionTitle('数据'),
          _clickableSettingItem('清空传输记录', '${provider.history.length} 条', _clearHistory),
          const SizedBox(height: 16),
          _sectionTitle('信任设备'),
          if (provider.trustedDevices.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '暂无已信任的设备',
                style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.35)),
              ),
            )
          else
            ...provider.trustedDevices.map(_trustedDeviceTile),
          const SizedBox(height: 16),
          _sectionTitle('关于'),
          _settingItem('版本', 'v1.6.3'),
          _settingItem('协议', '基于 QUIC 协议'),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: Colors.white.withOpacity(0.4),
        ),
      ),
    );
  }

  Widget _settingItem(String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: QxColors.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 14, color: Colors.white)),
          Text(
            value,
            style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.4)),
          ),
        ],
      ),
    );
  }

  Widget _clickableSettingItem(
      String label, String value, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: QxColors.surface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 14, color: Colors.white)),
            Row(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withOpacity(0.5),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right,
                    size: 18, color: Colors.white38),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _clearHistory() async {
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
      await context.read<TransferProvider>().clearHistory();
    }
  }

  Widget _trustedDeviceTile(TrustedDevice device) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: QxColors.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.verified_user_outlined, size: 16, color: QxColors.success),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${device.host}:${device.port}',
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  device.fingerprint,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.white.withOpacity(0.4),
                    fontFamily: 'monospace',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '撤销信任',
            icon: const Icon(Icons.delete_outline, size: 16, color: QxColors.danger),
            onPressed: () =>
                context.read<TransferProvider>().removeTrustedDevice(device.key),
          ),
        ],
      ),
    );
  }
}
