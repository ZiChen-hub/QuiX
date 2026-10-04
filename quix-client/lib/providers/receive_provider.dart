//! 接收模式（服务端）状态：通过 FFI 启动/停止 Rust 服务端，接收文件

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/quix_core_ffi.dart';
import '../services/zerotier_vpn_controller.dart';

/// 服务端接收到的文件条目
class ReceivedFileEntry {
  final String fileName;
  final int fileSize;
  final DateTime receivedAt;
  final int durationMs;
  final String source;

  ReceivedFileEntry({
    required this.fileName,
    required this.fileSize,
    required this.receivedAt,
    required this.durationMs,
    required this.source,
  });

  /// 发起传输时间（接收完成时间 - 耗时）
  DateTime get startedAt =>
      receivedAt.subtract(Duration(milliseconds: durationMs));

  /// 平均传输速度（字节/秒）
  int get bytesPerSecond =>
      durationMs > 0 ? (fileSize * 1000 ~/ durationMs) : 0;
}

/// 收到的剪贴板文本条目
class ReceivedText {
  final String text;
  final DateTime receivedAt;

  ReceivedText({required this.text, required this.receivedAt});
}

/// 「我接收」模式的状态中枢
class ReceiveProvider extends ChangeNotifier {
  bool _running = false;
  String _ip = '';
  String _crossIp = '';
  int _port = 4433;
  String _code = '';
  String _certFingerprint = '';
  int _connectedCount = 0;
  String _statusMessage = '未启动';

  // 接收统计
  int _receivedCount = 0;
  int _totalSize = 0;
  int _totalDurationMs = 0;
  List<ReceivedFileEntry> _records = [];

  // 自定义接收目录（空表示用默认目录）
  String _receiveDir = '';

  // 自定义连接码（空表示自动生成）
  String _customCode = '';

  // ZeroTier 网络 ID（空表示未填写）
  String _zerotierNetworkId = '';

  // 跨网络传输开关（用户可控；关闭时仅局域网直连，ZeroTier ID 保留但隐藏）
  bool _crossNetworkEnabled = false;

  // 跨网络已开启但未授权：启动服务后弹出「暂不授权」提醒
  bool _crossAuthReminderNeeded = false;

  // 手机端跨网络引导是否进行中
  bool _crossNetworkBusy = false;

  // 服务（含桌面端组网）启动中：UI 显示「正在组网...」，跨网络 IP 显示「正在组网...」
  bool _serviceStarting = false;
  // R14：启动代次。start 递增，stop 也递增，用于识别「启动期间已被 stop」
  int _startGeneration = 0;

  // 剪贴板文本：收到新文本时的回调（UI 用于展示与复制）
  void Function(String text)? onTextReceived;
  int _lastSeenTextAtMs = 0;
  List<ReceivedText> _textHistory = [];
  // 服务端启动后首次刷新需先建立文本基线，避免把持久化历史误判为「新文本」
  bool _textBaselineNeeded = true;

  bool get running => _running;
  String get ip => _ip;
  String get crossIp => _crossIp;
  bool get crossNetworkBusy => _crossNetworkBusy;
  bool get crossNetworkEnabled => _crossNetworkEnabled;
  bool get crossAuthReminderNeeded => _crossAuthReminderNeeded;
  bool get serviceStarting => _serviceStarting;

  /// 跨网络 IP 展示文案：未获取到 IP 时，组网中显示「正在组网...」，否则「暂未授权」
  String get crossIpDisplay {
    if (_crossIp.isNotEmpty) return _crossIp;
    if (_serviceStarting || _crossNetworkBusy) return '正在组网...';
    return '暂未授权';
  }

  /// 跨网络组网服务是否启用（开关开启且已填写网络 ID）
  bool get isCrossNetworkService =>
      _crossNetworkEnabled && _zerotierNetworkId.isNotEmpty;

  int get port => _port;
  String get code => _code;
  String get certFingerprint => _certFingerprint;
  int get connectedCount => _connectedCount;
  String get statusMessage => _statusMessage;
  String get connectUri {
    if (!_running) return '';
    var uri = 'quix://$_ip:$_port?code=$_code';
    // 跨网络开关关闭时不附带组网参数（对端仅局域网直连）
    if (_crossNetworkEnabled && _zerotierNetworkId.isNotEmpty) {
      uri = '$uri&nwid=$_zerotierNetworkId';
    }
    if (_crossIp.isNotEmpty) {
      uri = '$uri&xip=$_crossIp';
    }
    return uri;
  }

  int get receivedCount => _receivedCount;
  int get totalSize => _totalSize;
  int get totalDurationMs => _totalDurationMs;
  List<ReceivedFileEntry> get records => _records;
  List<ReceivedText> get textHistory => _textHistory;

  String get receiveDir => _receiveDir;
  String get customCode => _customCode;
  String get zerotierNetworkId => _zerotierNetworkId;

  /// 启动服务端（进入接收模式时调用）
  Future<void> start() async {
    // R14：服务已运行或正在启动（含数十秒组网）时直接返回，
    // 杜绝组网过程中重复 start 产生孤儿服务/重复 isolate
    if (_running || _serviceStarting) return;
    final myGen = ++_startGeneration;
    _statusMessage = '正在启动...';
    _textBaselineNeeded = true; // 每次启动服务都重新建立文本基线
    notifyListeners();
    try {
      // 读取自定义接收目录（未设置则用系统文档目录/QuiX）
      final prefs = await SharedPreferences.getInstance();
      _receiveDir = prefs.getString('receive_output_dir') ?? '';
      _zerotierNetworkId = prefs.getString('zerotier_network_id') ?? '';
      _crossNetworkEnabled = prefs.getBool('cross_network_enabled') ?? false;
      _customCode = prefs.getString('custom_code') ?? ''; // R20：读取持久化的自定义连接码
      // 跨网络开关开启且已填写 ID 才启用组网；关闭时仅局域网直连
      // （ID 保留在本地但隐藏，开关关闭状态下组网服务不启动）
      final crossActive = isCrossNetworkService;
      // Rust 侧内嵌 ZeroTier 仅桌面端可用；手机端由 Dart 引导组网
      final useCross = crossActive && !Platform.isAndroid;
      // 桌面端组网可能阻塞数十秒（等待 my.zerotier.com 授权）：
      // 先切换到「正在组网...」状态并刷新界面，startServer 放入后台 Isolate，
      // 避免组网期间整个前端卡死
      _serviceStarting = true;
      if (useCross) {
        _statusMessage = '正在组网...';
      }
      notifyListeners();
      String outputDir;
      if (_receiveDir.isNotEmpty) {
        outputDir = _receiveDir;
      } else if (Platform.isAndroid) {
        // Android：使用应用专属外部存储（无需运行时权限，文件管理器可见），
        // 不可用时回退到应用内部目录
        final base = await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
        outputDir = '${base.path}${Platform.pathSeparator}QuiX';
      } else {
        final docs = await getApplicationDocumentsDirectory();
        outputDir = '${docs.path}${Platform.pathSeparator}QuiX';
      }
      // 确保接收目录存在（Rust 侧会在其中写记录文件与接收文件）
      await Directory(outputDir).create(recursive: true);
      final config = <String, dynamic>{
        'port': _port,
        'output_dir': outputDir,
        'enable_mdns': true,
        'enable_cross_network': useCross,
        if (useCross) 'zerotier_network_id': _zerotierNetworkId,
        if (_customCode.isNotEmpty) 'code': _customCode,
      };
      // 阻塞式启动（桌面端组网最长 180 秒）放入后台 Isolate，UI 保持响应
      final info =
          await Isolate.run(() => QuixCoreFfi.startServer(config));
      // R14：启动期间若已被 stop（代次已变），立即补停刚启动的服务，
      // 不置运行态并返回（finally 会复位 _serviceStarting），避免孤儿服务
      if (myGen != _startGeneration) {
        try {
          QuixCoreFfi.stopServer();
        } catch (_) {}
        return;
      }
      _ip = (info['ip'] as String?) ?? '';
      _crossIp = (info['cross_ip'] as String?) ?? '';
      _port = (info['port'] as int?) ?? _port;
      _code = (info['code'] as String?) ?? '';
      _certFingerprint = (info['cert_fingerprint'] as String?) ?? '';
      _running = true;
      if (_crossIp.isNotEmpty) {
        // 跨网络组网成功（已授权并分配 IP）
        _statusMessage = '跨网络组网服务已启动';
      } else if (useCross) {
        // 组网失败（未授权/超时），Rust 侧已回退局域网直连：
        // 状态按局域网显示，并标记需要弹「暂不授权」提醒
        _statusMessage = '局域网直连服务已启动';
        _crossAuthReminderNeeded = true;
      } else {
        _statusMessage = '局域网直连服务已启动';
      }
    } catch (e) {
      _running = false;
      _statusMessage = '启动失败: $e';
    } finally {
      _serviceStarting = false;
    }
    notifyListeners();
    // Android：Rust 侧不支持 ZeroTier 安装器，改由 Dart 引导组网
    if (_running && Platform.isAndroid && isCrossNetworkService) {
      _configureMobileCrossNetwork();
    }
  }

  /// 手机端：引导官方 ZeroTier App 加入网络，等待分配 IP 后写入跨网地址
  Future<void> configureMobileCrossNetwork() => _configureMobileCrossNetwork();

  Future<void> _configureMobileCrossNetwork() async {
    if (!_running ||
        _zerotierNetworkId.isEmpty ||
        _crossNetworkBusy ||
        _crossIp.isNotEmpty) {
      return;
    }
    _crossNetworkBusy = true;
    _statusMessage = '正在加入跨网络组网...';
    notifyListeners();
    try {
      final ip = await ZerotierVpnController.joinAndWaitIp(_zerotierNetworkId);
      _crossIp = ip;
      _statusMessage = '跨网络组网服务已启动';
    } catch (e) {
      // 组网未完成（未授权/超时）：服务按局域网直连运行，并标记提醒弹窗
      _statusMessage = '局域网直连服务已启动';
      _crossAuthReminderNeeded = true;
    } finally {
      _crossNetworkBusy = false;
      notifyListeners();
    }
  }

  /// 设置自定义接收目录并持久化；服务运行中则立即重启以生效
  Future<void> setReceiveDir(String path) async {
    _receiveDir = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('receive_output_dir', path);
    // 确保目录存在且可写（创建缺失目录 + 写探针校验）
    try {
      await Directory(path).create(recursive: true);
      final probe = File('${path}${Platform.pathSeparator}.quix_write_test');
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (_) {
      // 目录创建/写入失败时保留原值，交由服务端启动时再次校验
    }
    notifyListeners();
    if (_running) {
      stop();
      await start();
    }
  }

  /// 设置自定义连接码并持久化（下次启动服务时生效）。
  // R20：原来仅存内存，重启后丢失，改为写入 SharedPreferences
  Future<void> setCustomCode(String code) async {
    _customCode = code.trim();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_code', _customCode);
  }

  /// 设置 ZeroTier 网络 ID 并持久化（下次启动服务时生效）
  Future<void> setZerotierNetworkId(String id) async {
    _zerotierNetworkId = id.trim();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('zerotier_network_id', _zerotierNetworkId);
  }

  /// 设置跨网络传输开关并持久化
  /// （关闭时不启动组网服务，ZeroTier ID 保留但相关子标签隐藏）
  Future<void> setCrossNetworkEnabled(bool enabled) async {
    _crossNetworkEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('cross_network_enabled', enabled);
  }

  /// UI 展示「暂不授权」提醒弹窗后消费标记，避免重复弹出
  void consumeCrossAuthReminder() {
    if (_crossAuthReminderNeeded) {
      _crossAuthReminderNeeded = false;
      notifyListeners();
    }
  }

  /// 「暂不授权，启动局域网直连服务」：
  /// 关闭跨网络开关（ZeroTier ID 保留但隐藏），并以局域网直连模式重启服务
  Future<void> disableCrossNetworkKeepId() async {
    _crossNetworkEnabled = false;
    _crossAuthReminderNeeded = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('cross_network_enabled', false);
    notifyListeners();
    if (_running) {
      stop();
      await start();
    }
  }

  /// 「测试组网」：加入 ZeroTier 网络并等待授权分配 IP。
  /// 返回 null 表示成功（已获得跨网络 IP）；返回非空字符串为失败原因。
  Future<String?> testJoinCrossNetwork(String networkId) async {
    final id = networkId.trim();
    if (id.isEmpty) return '请输入 ZeroTier 网络 ID';
    if (id.length != 16 || int.tryParse('0x$id') == null) {
      return '网络 ID 应为 16 位十六进制字符（可在 my.zerotier.com 网络页查看）';
    }
    final idChanged = id != _zerotierNetworkId;
    await setZerotierNetworkId(id);
    await setCrossNetworkEnabled(true);
    try {
      if (Platform.isAndroid) {
        // 手机端：内嵌 ZeroTier VPN 组网（含官方 App 引导）
        _crossNetworkBusy = true;
        notifyListeners();
        try {
          final ip = await ZerotierVpnController.joinAndWaitIp(id);
          _crossIp = ip;
        } finally {
          _crossNetworkBusy = false;
          notifyListeners();
        }
      } else {
        // 桌面端：内嵌 ZeroTier 核心 FFI（Isolate 内阻塞，最长 180 秒含授权等待；
        // 已授权设备重启后秒级完成）。统一结果解析（R21）
        _crossIp = await QuixCoreFfi.ztJoinAndGetIp(id);
      }
      if (idChanged && _running) {
        // 修改了网络 ID：重启服务以按新 ID 组网并刷新连接信息
        stop();
        await start();
      } else if (_running) {
        _statusMessage = '跨网络组网服务已启动';
      }
      notifyListeners();
      return null;
    } catch (e) {
      notifyListeners();
      return e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
    }
  }

  /// 停止服务端（离开接收模式时调用）
  void stop() {
    _startGeneration++; // R14：使任何正在进行的 start 失效（返回后会补停服务）
    if (_running) {
      QuixCoreFfi.stopServer();
    }
    if (Platform.isAndroid && _crossIp.isNotEmpty) {
      ZerotierVpnController.stop();
    }
    _running = false;
    _connectedCount = 0;
    _crossIp = '';
    _crossNetworkBusy = false;
    _crossAuthReminderNeeded = false;
    _statusMessage = '已停止';
    notifyListeners();
  }

  /// 清空传输记录与文本历史
  Future<void> clearRecords() async {
    if (_running) {
      try {
        await Isolate.run(() {
          QuixCoreFfi.clearRecords();
          return true;
        });
      } catch (_) {
        // 服务端可能已停止，忽略
      }
    }
    _records = [];
    _textHistory = [];
    _receivedCount = 0;
    _totalSize = 0;
    _totalDurationMs = 0;
    _lastSeenTextAtMs = 0;
    _textBaselineNeeded = false; // 已清空，之后收到的是真新文本，无需再建基线
    notifyListeners();
  }

  /// 断开所有已连接的客户端（服务保持运行）
  Future<void> disconnectAll() async {
    if (!_running) return;
    try {
      await Isolate.run(() {
        QuixCoreFfi.disconnectAll();
        return true;
      });
      _connectedCount = 0;
      notifyListeners();
    } catch (_) {
      // 服务端可能已停止，忽略
    }
  }

  /// 刷新连接设备数、接收统计与记录
  void refreshStatus() {
    if (!_running) return;
    try {
      final s = QuixCoreFfi.status();
      _connectedCount = (s['connected'] as int?) ?? 0;

      final stats = s['stats'];
      if (stats is Map) {
        _receivedCount = _toInt(stats['count']);
        _totalSize = _toInt(stats['total_size']);
        _totalDurationMs = _toInt(stats['total_duration_ms']);
      }

      final records = s['records'];
      if (records is List) {
        _records = records.whereType<Map>().map((r) {
          return ReceivedFileEntry(
            fileName: (r['file_name'] as String?) ?? '',
            fileSize: _toInt(r['file_size']),
            receivedAt: DateTime.fromMillisecondsSinceEpoch(
              _toInt(r['received_at_ms']),
            ),
            durationMs: _toInt(r['duration_ms']),
            source: (r['source'] as String?) ?? '',
          );
        }).toList();
      }

      // 解析剪贴板文本历史，并检测新文本（首条时间戳变化时触发回调）
      final texts = s['texts'];
      if (texts is List) {
        _textHistory = texts.whereType<Map>().map((t) {
          return ReceivedText(
            text: (t['text'] as String?) ?? '',
            receivedAt: DateTime.fromMillisecondsSinceEpoch(_toInt(t['at_ms'])),
          );
        }).toList();
        if (_textBaselineNeeded) {
          // 首次刷新：建立基线（无论当前有无历史），跳过回调，
          // 避免把启动时加载的持久化历史误判为「新文本」
          _textBaselineNeeded = false;
          _lastSeenTextAtMs = _textHistory.isNotEmpty
              ? _textHistory.first.receivedAt.millisecondsSinceEpoch
              : 0;
        } else if (_textHistory.isNotEmpty) {
          final latestMs = _textHistory.first.receivedAt.millisecondsSinceEpoch;
          if (latestMs > _lastSeenTextAtMs) {
            _lastSeenTextAtMs = latestMs;
            onTextReceived?.call(_textHistory.first.text);
          }
        }
      }

      notifyListeners();
    } catch (_) {
      // 服务端可能已停止，忽略
    }
  }

  int _toInt(dynamic v) => (v as num?)?.toInt() ?? 0;
}
