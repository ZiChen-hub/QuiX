//! 应用级状态：当前模式（发送/接收）与首次启动标记

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_mode.dart';

/// 应用全局模式状态（统一程序版）
class AppProvider extends ChangeNotifier {
  AppMode _mode = AppMode.send;
  bool _chosen = false;
  bool _loaded = false;

  AppMode get mode => _mode;
  bool get chosen => _chosen;
  bool get loaded => _loaded;

  /// 从本地加载上次选择的模式（首次启动则保持未选择）
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('app_mode');
    if (saved == 'receive') {
      _mode = AppMode.receive;
      _chosen = true;
    } else if (saved == 'send') {
      _mode = AppMode.send;
      _chosen = true;
    }
    _loaded = true;
    notifyListeners();
  }

  /// 切换模式并持久化
  Future<void> setMode(AppMode m) async {
    if (_mode == m && _chosen) return;
    _mode = m;
    _chosen = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_mode', m == AppMode.receive ? 'receive' : 'send');
  }
}
