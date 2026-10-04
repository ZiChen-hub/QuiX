//! 全局状态管理：连接状态、文件分块、进度更新

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/file_metadata.dart';
import '../models/transfer_history.dart';
import '../services/hash_util.dart';
import '../services/history_store.dart';
import '../services/network_probe.dart';
import '../services/quic_service.dart';
import '../services/resume_store.dart';
import '../services/zerotier_service.dart';
import '../utils/formatter.dart';

/// 最近连接的设备
class RecentDevice {
  final String ip;
  final int port;
  final String deviceName;
  final String nwid;
  final DateTime lastConnected;

  RecentDevice({
    required this.ip,
    required this.port,
    required this.deviceName,
    this.nwid = '',
    required this.lastConnected,
  });

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'port': port,
        'name': deviceName,
        'nwid': nwid,
        'ts': lastConnected.millisecondsSinceEpoch,
      };

  static RecentDevice fromJson(Map<String, dynamic> json) => RecentDevice(
        ip: json['ip'] as String,
        port: (json['port'] as num).toInt(),
        deviceName: (json['name'] as String?) ?? '',
        nwid: (json['nwid'] as String?) ?? '',
        lastConnected:
            DateTime.fromMillisecondsSinceEpoch((json['ts'] as num).toInt()),
      );
}

/// 已信任设备（TOFU 保存的服务器证书指纹）
class TrustedDevice {
  final String key;
  final String host;
  final int port;
  final String fingerprint;

  TrustedDevice({
    required this.key,
    required this.host,
    required this.port,
    required this.fingerprint,
  });
}

/// 传输状态中枢（对应开发案 3.2 节定义）
class TransferProvider extends ChangeNotifier {
  final QuicService _quic = QuicService();

  // === 连接状态 ===
  bool _isConnected = false;
  String _connectionType = '未连接'; // '局域网直连' | 'IPv6直连' | 'UPnP穿透' | 'ZeroTier组网'
  String _connectionCode = '';
  String _serverIp = '';
  int _serverPort = 4433;
  String _deviceName = ''; // 当前连接的设备名称（mDNS 发现得到）
  bool _fingerprintMismatch = false; // 证书指纹变化（疑似中间人）
  List<RecentDevice> _recentDevices = []; // 最近连接的设备
  List<TrustedDevice> _trustedDevices = []; // 已信任的设备（证书指纹）

  // 断线自动重连
  String _lastIp = '';
  int _lastPort = 4433;
  String _lastCode = '';
  String _lastNwid = '';
  String _lastXip = '';
  bool _autoReconnect = false;
  bool _reconnecting = false;
  bool _isConnecting = false; // R15：连接建立重入守卫
  Completer<bool>? _verifyCompleter; // R4：服务端 BLAKE3 完整性校验结果
  final Stopwatch _speedWatch = Stopwatch(); // R16：仅统计活跃发送时长（暂停停表）
  double _baseProgress = 0.0; // R16：本次发送起始整体进度（只计本次字节）

  // === 文件状态 ===
  List<File> _selectedFiles = [];
  String? _fileName;
  int? _fileSize;
  String? _folderRoot; // 文件夹传输时的根目录（用于计算相对路径）

  // === 传输状态 ===
  bool _isTransferring = false;
  double _progress = 0.0;
  String _speed = '0 MB/s';
  String _statusMessage = '就绪';
  bool _isSending = true; // true=发送模式, false=接收模式
  bool _paused = false;
  bool _cancelled = false;
  String _eta = '';
  int _queueIndex = 0; // 传输队列当前位置（0-based）
  int _queueTotal = 0; // 传输队列总数

  // === 传输参数（可配置） ===
  int _chunkSize = 4 * 1024 * 1024;
  int _concurrency = 8;

  // === 传输历史 ===
  List<TransferRecord> _history = [];

  // ===== getters =====
  bool get isConnected => _isConnected;
  String get connectionType => _connectionType;
  String get connectionCode => _connectionCode;
  String get serverIp => _serverIp;
  int get serverPort => _serverPort;
  String get deviceName => _deviceName;
  int get chunkSize => _chunkSize;
  int get concurrency => _concurrency;
  File? get selectedFile => _selectedFiles.isEmpty ? null : _selectedFiles.first;
  List<File> get selectedFiles => _selectedFiles;
  int get selectedCount => _selectedFiles.length;
  String? get fileName => _fileName;
  int? get fileSize => _fileSize;
  bool get isTransferring => _isTransferring;
  double get progress => _progress;
  String get speed => _speed;
  String get statusMessage => _statusMessage;
  bool get isSending => _isSending;
  bool get paused => _paused;
  String get eta => _eta;
  int get queueIndex => _queueIndex;
  int get queueTotal => _queueTotal;
  bool get fingerprintMismatch => _fingerprintMismatch;
  List<RecentDevice> get recentDevices => _recentDevices;
  List<TrustedDevice> get trustedDevices => _trustedDevices;
  List<TransferRecord> get history => _history;

  // ===== 连接逻辑 =====

  /// 建立 QUIC 连接（可选携带连接码，用于服务端鉴权；握手期强 pinning 校验证书指纹）
  /// 先尝试局域网直连 [ip]；失败后若有 [xip]（跨网络可达地址）则加入 ZeroTier 后重连
  Future<void> connect(String ip, int port,
      {String code = '', String deviceName = '', String nwid = '', String xip = ''}) async {
    // R15：已连接或上一次连接尚未完成时，先清理上一代原生连接与监控，
    // 再建立新连接，避免组网/切模式时重复 connect 产生孤儿连接与重复监控
    if (_isConnected || _isConnecting) {
      _autoReconnect = false;
      try {
        await _quic.close();
      } catch (_) {}
      _isConnected = false;
      _connectionType = '未连接';
    }
    _isConnecting = true;

    _serverIp = ip;
    _serverPort = port;
    _connectionCode = code;
    _deviceName = deviceName;
    _statusMessage = '正在连接...';
    notifyListeners();

    // 保存连接参数，供断线后自动重连
    _lastIp = ip;
    _lastPort = port;
    _lastCode = code;
    _lastNwid = nwid;
    _lastXip = xip;
    _autoReconnect = true;

    // 1. 局域网直连
    try {
      await _establishConnection(ip, port, code);
      _isConnected = true;
      _connectionType = '局域网直连';
      _statusMessage = '已连接';
      unawaited(_saveRecentDevice(ip, port, deviceName, nwid));
      _startConnectionMonitor();
      _isConnecting = false;
      notifyListeners();
      return;
    } catch (e) {
      if (xip.isEmpty) {
        _handleConnectError(e);
        _autoReconnect = false; // 无跨网络备选，连接失败后不再自动重连
        notifyListeners();
        return;
      }
      _statusMessage = '局域网直连失败，尝试跨网络...';
      notifyListeners();
    }

    // 2. 跨网络备选（加入 ZeroTier 后使用可达地址重连）
    try {
      if (nwid.isNotEmpty) {
        _statusMessage = '正在加入 ZeroTier 网络，首次使用需在 my.zerotier.com 授权本设备...';
        notifyListeners();
        await ZerotierService.joinAndWaitIp(nwid);
      }
      await _establishConnection(xip, port, code);
      _isConnected = true;
      _connectionType = 'ZeroTier组网';
      _statusMessage = '已连接（跨网络）';
      unawaited(_saveRecentDevice(xip, port, deviceName, nwid));
      _startConnectionMonitor();
      notifyListeners();
    } catch (e) {
      _handleConnectError(e);
      _autoReconnect = false; // 跨网络也失败，不再自动重连
      notifyListeners();
    }
    _isConnecting = false;
  }

  /// 建立连接并完成证书指纹校验（TOFU + 强 pinning）
  Future<void> _establishConnection(String host, int port, String code) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'server_fingerprint_$host:$port';
    final known = prefs.getString(key);

    final fingerprint = await _quic.connect(host, port, code,
        expectedFingerprint: known);

    // 首次连接（无已知指纹）：保存实际指纹，完成信任
    if (known == null && fingerprint != null && fingerprint.isNotEmpty) {
      await prefs.setString(key, fingerprint);
    }
    _fingerprintMismatch = false;
  }

  /// 将连接异常映射为可读状态
  void _handleConnectError(Object e) {
    _isConnected = false;
    _connectionType = '未连接';
    final msg = e.toString();
    if (msg.contains('指纹不匹配')) {
      _fingerprintMismatch = true;
      _statusMessage = '安全警告：服务器证书已变化，已拒绝连接';
    } else {
      _fingerprintMismatch = false;
      _statusMessage = _describeConnectionError(e);
    }
  }

  /// 加载最近连接的设备
  Future<void> loadRecentDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('recent_devices');
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List;
      _recentDevices = list
          .whereType<Map>()
          .map((e) => RecentDevice.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      _recentDevices = [];
    }
    notifyListeners();
  }

  /// 保存最近连接的设备（去重、最新在前、最多 10 个）
  Future<void> _saveRecentDevice(
      String ip, int port, String deviceName, String nwid) async {
    _recentDevices.removeWhere((d) => d.ip == ip && d.port == port);
    _recentDevices.insert(
      0,
      RecentDevice(
        ip: ip,
        port: port,
        deviceName: deviceName,
        nwid: nwid,
        lastConnected: DateTime.now(),
      ),
    );
    if (_recentDevices.length > 10) {
      _recentDevices = _recentDevices.sublist(0, 10);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'recent_devices',
      jsonEncode(_recentDevices.map((d) => d.toJson()).toList()),
    );
    notifyListeners();
  }

  /// 移除最近设备
  Future<void> removeRecentDevice(String ip, int port) async {
    _recentDevices.removeWhere((d) => d.ip == ip && d.port == port);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'recent_devices',
      jsonEncode(_recentDevices.map((d) => d.toJson()).toList()),
    );
    notifyListeners();
  }

  /// 将底层连接异常映射为用户可读的具体原因（对齐 PRD 第五章文案）
  String _describeConnectionError(Object e) {
    final msg = e.toString();
    // ZeroTier 组网错误（含授权/超时提示）优先透传，避免被通用超时文案覆盖
    if (msg.contains('my.zerotier.com') || msg.contains('ZeroTier')) {
      return msg.replaceFirst(RegExp(r'^Exception:\s*'), '');
    }
    if (msg.contains('连接超时')) {
      return '连接超时：请确认两端在同一网络、对端服务已启动、IP/端口正确，'
          '并检查路由器 AP 隔离与电脑防火墙设置';
    }
    if (msg.contains('连接码错误') || msg.contains('invalid code')) {
      return '连接码错误，请重新输入';
    }
    if (msg.contains('TimedOut') || msg.contains('timeout') || msg.contains('超时')) {
      return '网络连接失败，请检查网络设置';
    }
    if (msg.contains('EndpointStopping') || msg.contains('Stopping')) {
      return '连接已断开，请重新连接';
    }
    if (msg.contains('refused') || msg.contains('拒绝')) {
      return '端口无法访问，请确认服务端已启动';
    }
    return '连接失败：$msg';
  }

  /// 断开连接（主动）：先尽力通知服务端释放连接（对端「已连接设备」数
  /// 随之同步下降），再关闭本地连接
  Future<void> disconnect() async {
    _autoReconnect = false; // 用户主动断开，不再自动重连
    try {
      await _quic.sendDisconnectNotify().timeout(const Duration(seconds: 2));
    } catch (_) {
      // 通知失败（网络已不可达等）不阻断断开流程
    }
    await _quic.close();
    _isConnected = false;
    _connectionType = '未连接';
    _statusMessage = '已断开';
    notifyListeners();
  }

  /// 发送剪贴板文本到对端
  Future<void> sendText(String text) async {
    if (!_isConnected) {
      _statusMessage = '未连接，无法发送文本';
      notifyListeners();
      return;
    }
    try {
      await _quic.sendText(text);
    } catch (e) {
      _statusMessage = '发送文本失败: $e';
      notifyListeners();
    }
  }

  /// 后台启动连接监控（检测服务端断线并触发自动重连）
  void _startConnectionMonitor() {
    unawaited(_quic.startConnectionMonitor(
      onDisconnected: (bool serverRequested) {
        // 服务端主动断开（对端点击「断开连接」）或意外断开，同步本地状态
        if (_isConnected) {
          _isConnected = false;
          _connectionType = '未连接';
          _isTransferring = false;
          if (serverRequested) {
            // 对端主动断开：不再自动重连
            _autoReconnect = false;
            _statusMessage = '对端已断开连接';
          } else {
            _statusMessage = '连接已断开';
          }
          notifyListeners();
          // 意外断开时自动重连
          if (!_autoReconnect) return;
          unawaited(_attemptReconnect());
        }
      },
      onVerifyResult: (bool ok) {
        // R4：服务端完成 BLAKE3 校验后回传结果，唤醒等待中的 _sendOneFile
        final c = _verifyCompleter;
        if (c != null && !c.isCompleted) {
          c.complete(ok);
        }
      },
    ));
  }

  /// 断线自动重连（最多重试 3 次，间隔 2 秒）
  Future<void> _attemptReconnect() async {
    if (_reconnecting) return;
    _reconnecting = true;
    try {
      for (var i = 0; i < 3; i++) {
        if (!_autoReconnect || _isConnected) break;
        _statusMessage = '正在重连 (${i + 1}/3)...';
        notifyListeners();
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!_autoReconnect || _isConnected) break;
        try {
          await connect(_lastIp, _lastPort,
              code: _lastCode, nwid: _lastNwid, xip: _lastXip);
          if (_isConnected) break;
        } catch (_) {
          // 继续下一次重试
        }
      }
    } finally {
      _reconnecting = false;
      // 重连多次仍失败，放弃自动重连
      if (!_isConnected) {
        _autoReconnect = false;
      }
    }
  }

  // ===== 传输历史 =====

  /// 从本地加载历史记录
  Future<void> loadHistory() async {
    _history = await HistoryStore.load();
    notifyListeners();
  }

  /// 记录一条传输历史
  Future<void> _recordTransfer({
    required String fileName,
    required int fileSize,
    required String direction,
    required String status,
    String path = '',
  }) async {
    final peer = _deviceName.isNotEmpty ? _deviceName : _serverIp;
    final record = TransferRecord(
      fileName: fileName,
      fileSize: fileSize,
      direction: direction,
      timestamp: DateTime.now(),
      status: status,
      peer: peer,
      path: path,
    );
    _history.insert(0, record);
    notifyListeners();
    await HistoryStore.add(record);
  }

  /// 清空传输历史
  Future<void> clearHistory() async {
    await HistoryStore.clear();
    _history = [];
    notifyListeners();
  }

  /// 加载传输参数（分块大小、并发流数）
  Future<void> loadTransferSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _chunkSize = prefs.getInt('chunk_size') ?? _chunkSize;
    _concurrency = prefs.getInt('concurrency') ?? _concurrency;
    notifyListeners();
  }

  /// 主动测速：通过当前 QUIC 连接实测传输速度（字节/秒）
  Future<int> runSpeedTest() async {
    if (!_isConnected) {
      throw Exception('未连接，无法测速');
    }
    return _quic.speedTest();
  }

  /// 主动测速并应用最优参数，返回结果描述
  Future<String> speedTestAndApply() async {
    final bytesPerSec = await runSpeedTest();
    final mbps = (bytesPerSec * 8 / 1000000).round();
    final rec = NetworkProbe.recommend(mbps);
    _chunkSize = rec.chunkSize;
    _concurrency = rec.concurrency;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('chunk_size', _chunkSize);
    await prefs.setInt('concurrency', _concurrency);

    final chunkMb = (_chunkSize / (1024 * 1024)).toStringAsFixed(0);
    return '实测 ${Formatter.formatSpeed(bytesPerSec)}（约 $mbps Mbps），'
        '已配置 $chunkMb MB / $_concurrency 流';
  }

  /// 加载已信任的设备（证书指纹列表）
  Future<void> loadTrustedDevices() async {
    final prefs = await SharedPreferences.getInstance();
    const prefix = 'server_fingerprint_';
    final keys = prefs.getKeys().where((k) => k.startsWith(prefix)).toList();
    final list = <TrustedDevice>[];
    for (final key in keys) {
      final addr = key.substring(prefix.length);
      final idx = addr.lastIndexOf(':');
      final host = idx > 0 ? addr.substring(0, idx) : addr;
      final port = idx > 0 ? (int.tryParse(addr.substring(idx + 1)) ?? 4433) : 4433;
      final fp = prefs.getString(key) ?? '';
      list.add(TrustedDevice(key: key, host: host, port: port, fingerprint: fp));
    }
    _trustedDevices = list;
    notifyListeners();
  }

  /// 移除某个已信任的设备（撤销证书指纹，下次连接将重新校验）
  Future<void> removeTrustedDevice(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
    _trustedDevices.removeWhere((d) => d.key == key);
    notifyListeners();
  }

  // ===== 文件传输 =====

  /// 暂停当前传输
  void pause() {
    if (_isTransferring && !_paused) {
      _paused = true;
      _speedWatch.stop(); // R16：暂停期间不累计发送时长，速率/ETA 不失实
      _statusMessage = '已暂停';
      notifyListeners();
    }
  }

  /// 继续当前传输
  void resume() {
    if (_paused) {
      _paused = false;
      if (!_speedWatch.isRunning) _speedWatch.start(); // R16：恢复计时
      _statusMessage = _isSending ? '发送中...' : '接收中...';
      notifyListeners();
    }
  }

  /// 取消当前传输
  void cancel() {
    if (_isTransferring) {
      _cancelled = true;
      _paused = false;
      notifyListeners();
    }
  }

  String _formatEta(int ms) {
    final totalSeconds = (ms / 1000).round();
    if (totalSeconds < 60) return '约 $totalSeconds 秒';
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    return '约 $m 分 $s 秒';
  }

  /// 选择待发送文件（支持多选）
  void selectFiles(List<File> files) {
    _folderRoot = null;
    _selectedFiles = files;
    if (files.isEmpty) {
      _fileName = null;
      _fileSize = null;
      _statusMessage = '就绪';
    } else {
      _fileName = files.first.path.split(Platform.pathSeparator).last;
      _fileSize = files.fold<int>(0, (sum, f) => sum + f.lengthSync());
      _statusMessage = files.length > 1 ? '已选择 ${files.length} 个文件' : '已选择文件';
    }
    notifyListeners();
  }

  /// 选择文件夹（递归遍历，保持相对路径发送）
  Future<void> selectFolder(String folderPath) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) {
      _statusMessage = '文件夹不存在';
      notifyListeners();
      return;
    }
    final files = <File>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        files.add(entity);
      }
    }
    if (files.isEmpty) {
      _statusMessage = '文件夹为空';
      notifyListeners();
      return;
    }
    _folderRoot = folderPath;
    _selectedFiles = files;
    _fileName = folderPath.split(Platform.pathSeparator).last;
    _fileSize = files.fold<int>(0, (sum, f) => sum + f.lengthSync());
    _statusMessage = '已选择文件夹（${files.length} 个文件）';
    notifyListeners();
  }

  /// 计算文件相对路径（文件夹传输时返回相对根目录的路径，否则返回文件名）
  String _relativePathOf(File file) {
    final root = _folderRoot;
    if (root == null) {
      return file.path.split(Platform.pathSeparator).last;
    }
    var rel = file.path.substring(root.length).replaceAll('\\', '/');
    if (rel.startsWith('/')) rel = rel.substring(1);
    return rel;
  }

  /// 选择单个文件
  void selectFile(File file) => selectFiles([file]);

  /// 清空已选文件
  void clearSelectedFiles() {
    _selectedFiles = [];
    _fileName = null;
    _fileSize = null;
    _folderRoot = null;
    _statusMessage = '就绪';
    notifyListeners();
  }

  /// 发送所有已选文件（支持多文件队列）
  Future<void> sendFile() async {
    if (_selectedFiles.isEmpty) {
      _statusMessage = '请先选择文件';
      notifyListeners();
      return;
    }

    _isTransferring = true;
    _isSending = true;
    _progress = 0.0;
    _paused = false;
    _cancelled = false;
    _eta = '';
    _queueTotal = _selectedFiles.length;
    _queueIndex = 0;
    notifyListeners();

    final total = _selectedFiles.length;
    var done = 0;
    var cancelled = false;
    for (var i = 0; i < total; i++) {
      if (_cancelled) {
        cancelled = true;
        break;
      }
      _queueIndex = i;
      if (total > 1) {
        _statusMessage = '正在发送 (${i + 1}/$total)';
        notifyListeners();
      }
      final result = await _sendOneFile(_selectedFiles[i]);
      if (result == _SendResult.done) {
        done++;
      } else if (result == _SendResult.cancelled) {
        cancelled = true;
        break;
      }
    }

    _isTransferring = false;
    _paused = false;
    _cancelled = false;
    _eta = '';
    _queueIndex = 0;
    _queueTotal = 0;
    if (cancelled) {
      _statusMessage = '已取消';
    } else if (total > 1) {
      _statusMessage = done == total ? '全部发送完成' : '发送完成 $done/$total';
    }
    _selectedFiles = [];
    _fileName = null;
    _fileSize = null;
    notifyListeners();
  }

  /// 发送单个文件，返回结果状态
  Future<_SendResult> _sendOneFile(File file) async {
    final fileName = _relativePathOf(file);
    final size = file.lengthSync();
    final path = file.path;
    try {
      // R4：创建本次完整性校验结果等待器（在发元数据前创建，
      // 以捕获服务端对空文件在元数据阶段直接回传的结果）
      _verifyCompleter = Completer<bool>();
      // 计算 BLAKE3 哈希
      final hash = await HashUtil.computeHash(file);
      final totalChunks = (size + _chunkSize - 1) ~/ _chunkSize;

      // 复用或创建 file_id（断点续传）
      // R13：file_id 绑定 chunk_size；分块配置改变后不复用旧 id（否则续传会静默损坏文件）
      String? fileId = await ResumeStore.getFileId(path, size, _chunkSize);
      final isResume = fileId != null;
      fileId ??= const Uuid().v4();
      await ResumeStore.saveFileId(path, size, _chunkSize, fileId);

      final meta = FileMetadata(
        fileId: fileId,
        fileName: fileName,
        fileSize: size,
        chunkSize: _chunkSize,
        totalChunks: totalChunks,
        hash: hash,
        code: _connectionCode,
      );

      // 发送元数据，服务端返回已接收位图
      _statusMessage = isResume ? '检测到未完成传输，正在续传...' : '发送元数据...';
      notifyListeners();
      final resp = await _quic.sendMetadata(meta);

      // 初始进度 = 已接收块 / 总块数
      if (totalChunks > 0) {
        _progress = resp.count / totalChunks;
      }
      _baseProgress = _progress; // R16：记录本次发送起点，速率只计本次新发送字节
      notifyListeners();

      // 仅发送缺失块
      _statusMessage = '发送数据...';
      notifyListeners();
      _speedWatch
        ..reset()
        ..start();
      _speed = '0 MB/s';
      await _quic.sendChunks(fileId, file, meta, resp.bitmap, (p) {
        _progress = p;
        // R16：仅统计本次新发送字节（扣除续传起点）与活跃时长（暂停时已停表）
        final activeMs = _speedWatch.elapsedMilliseconds;
        final gain = (p - _baseProgress).clamp(0.0, 1.0);
        if (activeMs > 0 && gain > 0) {
          final sentBytes = (gain * size).round();
          final bytesPerSec = sentBytes * 1000 ~/ activeMs;
          _speed = Formatter.formatSpeed(bytesPerSec);
          _eta = (p < 1.0)
              ? _formatEta((activeMs / gain * (1 - p)).round())
              : '';
        }
        notifyListeners();
      },
          concurrency: _concurrency,
          isPaused: () => _paused,
          isCancelled: () => _cancelled);
      _speedWatch.stop();

      // R4：所有块 ACK 已返回，但必须再等待服务端 BLAKE3 校验结果，
      // 不能仅凭 ACK/finish 判定成功；超时未收到结果视为失败
      final verifyOk = await _verifyCompleter!
          .future
          .timeout(const Duration(seconds: 30), onTimeout: () => false);
      _verifyCompleter = null;
      if (!verifyOk) {
        // 校验失败：保留续传记录与服务端会话，便于重新发送补齐
        throw const FileSystemException('完整性校验失败，文件可能已损坏，请重试');
      }

      _progress = 1.0;
      // 校验通过后清除续传记录
      await ResumeStore.clear(path, size, _chunkSize);
      await _recordTransfer(
        fileName: fileName,
        fileSize: size,
        direction: '发送',
        status: '完成',
        path: path,
      );
      return _SendResult.done;
    } on TransferCancelledException {
      await _recordTransfer(
        fileName: fileName,
        fileSize: size,
        direction: '发送',
        status: '已取消',
        path: path,
      );
      return _SendResult.cancelled;
    } catch (e) {
      // 连接码错误等明确拒绝场景
      final msg = e.toString();
      _statusMessage = msg.contains('连接码错误') ? '连接码错误' : '发送失败: $msg';
      await _recordTransfer(
        fileName: fileName,
        fileSize: size,
        direction: '发送',
        status: '失败',
        path: path,
      );
      return _SendResult.failed;
    }
  }
}

/// 单个文件发送结果
enum _SendResult { done, failed, cancelled }
