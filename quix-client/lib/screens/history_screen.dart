//! 传输历史记录页（传输 Tab）：统计、搜索、按设备筛选、打开文件/目录

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transfer_history.dart';
import '../providers/transfer_provider.dart';
import '../theme/tokens.dart';
import '../utils/formatter.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _peerFilter = '全部设备';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TransferProvider>();
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final all = provider.history;

    // 设备（peer）列表：从历史记录去重提取
    final peers = <String>{};
    for (final r in all) {
      if (r.peer.isNotEmpty) peers.add(r.peer);
    }

    // 筛选：「我发送」模式只会发送，所有记录均为发送方向
    var history = all.where((r) => r.direction == '发送').toList();
    final q = _searchController.text.trim();
    if (q.isNotEmpty) {
      final lower = q.toLowerCase();
      history = history.where((r) => r.fileName.toLowerCase().contains(lower)).toList();
    }
    if (_peerFilter != '全部设备') {
      history = history.where((r) => r.peer == _peerFilter).toList();
    }

    // 统计（基于全部历史）
    final totalCount = all.length;
    final totalBytes = all.fold<int>(0, (s, r) => s + r.fileSize);
    final successCount = all.where((r) => r.status == '完成').length;

    return Scaffold(
      backgroundColor: QxColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          '传输记录',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: '清除记录',
            icon: const Icon(Icons.delete_outline, color: Colors.white70),
            onPressed: all.isEmpty
                ? null
                : () => _confirmClear(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // 统计卡片
          if (totalCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: _StatsBar(
                totalCount: totalCount,
                totalBytes: totalBytes,
                successCount: successCount,
              ),
            ),

          // 最近 7 天传输量
          if (totalCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: _DailyChart(totals: _dailyTotals(all)),
            ),

          // 搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 13, color: Colors.white),
              decoration: InputDecoration(
                hintText: '搜索文件名',
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                prefixIcon: const Icon(Icons.search, size: 18, color: Colors.white38),
                isDense: true,
                filled: true,
                fillColor: QxColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),

          // 设备筛选 chips
          if (peers.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                children: [
                  _peerChip('全部设备', _peerFilter == '全部设备'),
                  for (final p in peers.toList()) _peerChip(p, _peerFilter == p),
                ],
              ),
            ),

          Expanded(
            child: history.isEmpty
                ? Center(
                    child: Text(
                      '暂无传输记录',
                      style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 14),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    itemCount: history.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final record = history[index];
                      return _HistoryTile(
                        record: record,
                        onOpen: () => _openFile(record.path),
                        onReveal: () => _revealInFolder(record.path),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _peerChip(String label, bool selected) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _peerFilter = label),
        showCheckmark: false,
        labelStyle: TextStyle(
          fontSize: 12,
          color: selected ? QxColors.bg : Colors.white70,
        ),
        backgroundColor: QxColors.surface,
        selectedColor: QxColors.primary,
        side: BorderSide(color: selected ? QxColors.primary : QxColors.border),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
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
    if (confirmed == true && context.mounted) {
      await context.read<TransferProvider>().clearHistory();
    }
  }

  Future<void> _openFile(String path) async {
    if (path.isEmpty) return;
    if (!File(path).existsSync()) {
      _showSnack('文件不存在');
      return;
    }
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      }
    } catch (_) {
      _showSnack('无法打开文件');
    }
  }

  Future<void> _revealInFolder(String path) async {
    if (path.isEmpty) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', ['/select,', path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [File(path).parent.path]);
      }
    } catch (_) {
      _showSnack('无法打开所在文件夹');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

/// 顶部统计条：总文件数、总传输量、成功/失败
class _StatsBar extends StatelessWidget {
  final int totalCount;
  final int totalBytes;
  final int successCount;

  const _StatsBar({
    required this.totalCount,
    required this.totalBytes,
    required this.successCount,
  });

  @override
  Widget build(BuildContext context) {
    final failCount = totalCount - successCount;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: QxColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _stat('文件', '$totalCount'),
          _divider(),
          _stat('总量', Formatter.formatBytes(totalBytes)),
          _divider(),
          _stat('成功', '$successCount', color: QxColors.success),
          _divider(),
          _stat('失败', '$failCount', color: failCount > 0 ? QxColors.danger : Colors.white54),
        ],
      ),
    );
  }

  Widget _divider() {
    return Container(width: 1, height: 28, color: QxColors.border);
  }

  Widget _stat(String label, String value, {Color? color}) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: color ?? Colors.white,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.45)),
          ),
        ],
      ),
    );
  }
}

/// 计算最近 7 天的每日传输量（仅统计成功记录），索引 0=6天前，6=今天
List<int> _dailyTotals(List<TransferRecord> records) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final totals = List<int>.filled(7, 0);
  for (final r in records) {
    if (r.status != '完成') continue;
    final d = DateTime(r.timestamp.year, r.timestamp.month, r.timestamp.day);
    final diff = today.difference(d).inDays;
    if (diff >= 0 && diff < 7) {
      totals[6 - diff] += r.fileSize;
    }
  }
  return totals;
}

class _DailyChart extends StatelessWidget {
  final List<int> totals;

  const _DailyChart({required this.totals});

  @override
  Widget build(BuildContext context) {
    final maxVal = totals.fold<int>(0, (m, v) => v > m ? v : m);
    const labels = ['6天前', '5天前', '4天前', '3天前', '2天前', '昨天', '今天'];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: QxColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('近 7 天传输量',
              style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.45))),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      children: [
                        Text(
                          totals[i] > 0 ? Formatter.formatBytes(totals[i]) : '',
                          style: TextStyle(
                              fontSize: 9, color: Colors.white.withOpacity(0.5)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Container(
                          height: _barHeight(totals[i], maxVal),
                          decoration: BoxDecoration(
                            color: totals[i] > 0 ? QxColors.primary : QxColors.surface2,
                            borderRadius:
                                const BorderRadius.vertical(top: Radius.circular(4)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          labels[i],
                          style: TextStyle(
                              fontSize: 9, color: Colors.white.withOpacity(0.4)),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  double _barHeight(int v, int maxVal) {
    if (maxVal == 0) return 4;
    return 4 + (v / maxVal) * 60;
  }
}

class _HistoryTile extends StatelessWidget {
  final TransferRecord record;
  final VoidCallback onOpen;
  final VoidCallback onReveal;

  const _HistoryTile({
    required this.record,
    required this.onOpen,
    required this.onReveal,
  });

  @override
  Widget build(BuildContext context) {
    final isSend = record.direction == '发送';
    final isDone = record.status == '完成';
    final color = isDone ? QxColors.success : QxColors.danger;
    final isMobile = Platform.isAndroid || Platform.isIOS;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: QxColors.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            isSend ? Icons.arrow_upward : Icons.arrow_downward,
            size: 18,
            color: Colors.white.withOpacity(0.6),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.fileName,
                  style: const TextStyle(fontSize: 14, color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '${Formatter.formatBytes(record.fileSize)} · ${_formatTime(record.timestamp)}'
                  '${record.peer.isNotEmpty ? ' · ${record.peer}' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withOpacity(0.4),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(record.status, style: TextStyle(fontSize: 12, color: color)),
          // 桌面端：提供打开文件与定位操作
          if (!isMobile && record.path.isNotEmpty) ...[
            const SizedBox(width: 4),
            IconButton(
              tooltip: '打开文件',
              icon: const Icon(Icons.open_in_new, size: 16, color: Colors.white54),
              onPressed: onOpen,
            ),
            IconButton(
              tooltip: '打开所在目录',
              icon: const Icon(Icons.folder_open, size: 16, color: Colors.white54),
              onPressed: onReveal,
            ),
          ],
        ],
      ),
    );
  }

  static String _formatTime(DateTime t) {
    final now = DateTime.now();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    if (sameDay) return '$hh:$mm';
    final md = '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    return '$md $hh:$mm';
  }
}
