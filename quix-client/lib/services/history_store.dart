//! 传输历史记录持久化（shared_preferences）

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/transfer_history.dart';

class HistoryStore {
  static const String _key = 'quix_transfer_history';

  /// 加载历史记录（新在前）
  static Future<List<TransferRecord>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List;
    // R18：逐记录容错，单条损坏或版本过旧只跳过该条，不影响其余历史加载
    final result = <TransferRecord>[];
    for (final e in list) {
      try {
        result.add(TransferRecord.fromJson(e as Map<String, dynamic>));
      } catch (_) {
        // 忽略单条异常记录
      }
    }
    return result;
  }

  /// 保存全部历史记录
  static Future<void> save(List<TransferRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(records.map((e) => e.toJson()).toList());
    await prefs.setString(_key, raw);
  }

  /// 追加一条记录（新在前）
  static Future<void> add(TransferRecord record) async {
    final records = await load();
    records.insert(0, record);
    await save(records);
  }

  /// 清空所有历史记录
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
