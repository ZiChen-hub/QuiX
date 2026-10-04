//! QUIC 客户端服务：封装 flutter_quic 插件，提供高层文件传输接口
//! 说明：基于 flutter_quic 1.0.0 的真实 API。
//! 注意：flutter_quic 的 open_bi 返回独立的 send/recv 流，此处用 _BiStream 封装。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_quic/flutter_quic.dart';

import '../models/file_metadata.dart';
import 'file_chunker.dart';
import 'protocol.dart';

/// 双向流封装（flutter_quic 的 connectionOpenBi 返回独立的 send/recv 流）
class _BiStream {
  QuicSendStream send;
  QuicRecvStream recv;

  _BiStream(this.send, this.recv);
}

/// 传输被用户取消
class TransferCancelledException implements Exception {
  @override
  String toString() => '传输已取消';
}

/// 连接超时（QUIC 握手在限定时间内未完成）
class QuicConnectTimeoutException implements Exception {
  @override
  String toString() => '连接超时：10 秒内未建立连接';
}

/// QUIC 连接与流操作的抽象封装
class QuicService {
  QuicEndpoint? _endpoint;
  QuicConnection? _connection;
  bool _connected = false;
  // 连接代际：每次 connect/close 递增，用于让旧 listener 在重连后失效，
  // 避免其延迟回调误伤新连接
  int _generation = 0;

  bool get isConnected => _connected;

  /// 建立 QUIC 连接（握手后立即校验连接码），返回服务端证书指纹（SHA256 hex）
  /// [expectedFingerprint] 非空时，握手期强 pinning（证书不匹配则拒绝连接）
  Future<String?> connect(String host, int port, String code,
      {String? expectedFingerprint}) async {
    _generation++; // 新连接进入新代际，旧 listener 失效
    _endpoint = await createClientEndpoint(
      expectedFingerprint: expectedFingerprint,
    );
    // 握手 + Hello 鉴权必须在 10 秒内完成，否则对端不可达/被防火墙拦截时会
    // 因「禁用空闲超时」而无限期挂在「正在连接...」
    final QuicEndpoint connectedEndpoint;
    final QuicConnection rawConnection;
    try {
      final r = await endpointConnect(
        endpoint: _endpoint!,
        addr: _socketAddr(host, port),
        serverName: host,
      ).timeout(const Duration(seconds: 10));
      connectedEndpoint = r.$1;
      rawConnection = r.$2;
    } on TimeoutException {
      throw QuicConnectTimeoutException();
    }
    _endpoint = connectedEndpoint;
    _connection = rawConnection;

    // 连接时校验连接码（并声明设备类型）
    final deviceType = (Platform.isAndroid || Platform.isIOS) ? 'mobile' : 'desktop';
    final ok = await _hello(code, deviceType);
    if (!ok) {
      throw Exception('连接码错误');
    }
    _connected = true;

    // 获取服务端证书指纹（SHA256 hex），供上层做 TOFU 校验
    final fp = await endpointLastCertFingerprint(endpoint: _endpoint!);
    _endpoint = fp.$1;
    return fp.$2;
  }

  /// 发送连接鉴权消息并读取结果
  Future<bool> _hello(String code, String deviceType) async {
    final stream = await _openBiStream();
    await _write(stream, Protocol.buildHello(code, deviceType));
    await _finishSend(stream);
    final resp = await _read(stream, 1);
    return resp[0] == 1;
  }

  /// 关闭连接（flutter_quic 未暴露 close，仅重置本地状态）
  Future<void> close() async {
    _generation++; // 递增代际，让旧 listener 失效（其延迟回调不再影响新连接）
    _connection = null;
    _endpoint = null;
    _connected = false;
  }

  /// 拼接 socket 地址：IPv6 需要方括号 `[host]:port`，IPv4 直接 `host:port`
  String _socketAddr(String host, int port) {
    if (host.contains(':') && !host.startsWith('[')) {
      return '[$host]:$port';
    }
    return '$host:$port';
  }

  // ===== 上传（客户端→服务端） =====

  /// 发送文件元数据并接收响应
  Future<MetadataResponse> sendMetadata(FileMetadata meta) async {
    final stream = await _openBiStream();
    await _write(stream, Protocol.buildMetadataMessage(meta));
    await _finishSend(stream);

    final countBytes = await _read(stream, 8);
    final bitmapBytes = await _readToEnd(stream);
    final resp = Uint8List.fromList([...countBytes, ...bitmapBytes]);
    final result = Protocol.parseMetadataResponse(resp);
    if (result.count == Protocol.rejectSentinel) {
      throw Exception('连接码错误');
    }
    return result;
  }

  /// 发送剪贴板文本到服务端（MessageType 11）
  Future<void> sendText(String text) async {
    final stream = await _openBiStream();
    await _write(stream, Protocol.buildTextMessage(text));
    await _finishSend(stream);
    // 读取服务端 1 字节确认
    await _read(stream, 1);
  }

  /// 主动测速（MessageType 12）：发送测试数据并计时，返回字节/秒。
  /// 默认 8MB，并设 2 秒时间上限——低速网络下不会因固定大额数据量而耗时过长。
  Future<int> speedTest({int testBytes = 8 * 1024 * 1024}) async {
    final stream = await _openBiStream();
    await _write(stream, Protocol.buildSpeedTestHeader(testBytes));

    // 分块写测试数据（复用同一缓冲区，避免大内存分配）
    const chunkSize = 1024 * 1024; // 1MB
    const maxDuration = Duration(seconds: 2); // 测速时间上限
    final chunk = Uint8List(chunkSize); // 全零
    final watch = Stopwatch()..start();
    var sent = 0;
    while (sent < testBytes && watch.elapsed < maxDuration) {
      final n = (testBytes - sent < chunkSize) ? testBytes - sent : chunkSize;
      await _write(stream,
          n == chunkSize ? chunk : Uint8List.sublistView(chunk, 0, n));
      sent += n;
    }
    await _finishSend(stream);
    // 读取服务端 1 字节确认
    await _read(stream, 1);
    watch.stop();

    if (watch.elapsedMilliseconds <= 0 || sent == 0) return 0;
    return sent * 1000 ~/ watch.elapsedMilliseconds;
  }

  /// 查询断点续传位图（MessageType 5 → 6）
  Future<List<int>> requestResume(String fileId, String code) async {
    final stream = await _openBiStream();
    await _write(stream, Protocol.buildResumeRequest(fileId, code));
    await _finishSend(stream);
    final resp = await _readToEnd(stream);
    return Protocol.parseResumeResponse(resp);
  }

  /// 发送文件缺失数据块（多流并发）
  Future<void> sendChunks(
    String fileId,
    File file,
    FileMetadata meta,
    List<int> receivedBitmap,
    void Function(double progress) onProgress, {
    int concurrency = 8,
    bool Function()? isPaused,
    bool Function()? isCancelled,
  }) async {
    final totalChunks = meta.totalChunks;

    final missing = <int>[];
    for (int i = 0; i < totalChunks; i++) {
      final received = i < receivedBitmap.length && receivedBitmap[i] == 1;
      if (!received) {
        missing.add(i);
      }
    }

    if (missing.isEmpty) {
      onProgress(1.0);
      return;
    }

    final chunker = FileChunker(chunkSize: meta.chunkSize);
    try {
      final streamCount =
          concurrency < missing.length ? concurrency : missing.length;
      final streams = <_BiStream>[];
      for (int s = 0; s < streamCount; s++) {
        streams.add(await _openBiStream());
      }

      final initialReceived = totalChunks - missing.length;
      int completed = 0;
      void onChunkDone() {
        completed++;
        onProgress((initialReceived + completed) / totalChunks);
      }

      await Future.wait([
        for (int s = 0; s < streamCount; s++)
          _sendChunksOnStream(
            streams[s],
            fileId,
            file,
            chunker,
            missing,
            s,
            streamCount,
            onChunkDone,
            isPaused,
            isCancelled,
          ),
      ]);
    } finally {
      await chunker.close(); // R19：释放缓存的长期文件句柄
    }
  }

  /// 在单个流上按跨步方式发送缺失块
  Future<void> _sendChunksOnStream(
    _BiStream stream,
    String fileId,
    File file,
    FileChunker chunker,
    List<int> missing,
    int streamIndex,
    int streamCount,
    void Function() onChunkDone,
    bool Function()? isPaused,
    bool Function()? isCancelled,
  ) async {
    int sent = 0;
    for (int k = streamIndex; k < missing.length; k += streamCount) {
      await _waitIfPaused(isPaused, isCancelled);
      final chunkIndex = missing[k];
      final data = await chunker.readChunk(file, chunkIndex, streamIndex);
      await _write(stream, Protocol.buildChunkMessage(fileId, chunkIndex, data));
      sent++;
      onChunkDone();
    }
    await _finishSend(stream);

    for (int a = 0; a < sent; a++) {
      final ackBytes = await _read(stream, 16);
      Protocol.parseAck(ackBytes);
    }
  }

  /// 暂停时挂起；被取消则抛出异常
  Future<void> _waitIfPaused(
    bool Function()? isPaused,
    bool Function()? isCancelled,
  ) async {
    while (isPaused?.call() == true) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (isCancelled?.call() == true) throw TransferCancelledException();
    }
    if (isCancelled?.call() == true) throw TransferCancelledException();
  }

  // ===== 连接保活与断线检测 =====

  /// 尽力通知服务端本端即将主动断开（服务端据此立即释放连接并同步状态）。
  /// 网络已不可达时静默失败（服务端稍后会因连接关闭自行清理）。
  Future<void> sendDisconnectNotify() async {
    if (_connection == null) return;
    try {
      final stream = await _openBiStream();
      await _write(stream, Protocol.buildDisconnectNotify());
      await _finishSend(stream);
    } catch (_) {
      // 通知失败不影响断开流程
    }
  }

  /// 启动连接监控：打开一条控制流并注册，
  /// 服务端关闭连接时该控制流会被关闭，从而触发 onDisconnected 回调。
  /// [serverRequested] 为 true 表示服务端主动断开（收到 DisconnectNotify），
  /// 上层不应自动重连。
  Future<void> startConnectionMonitor({
    void Function(bool serverRequested)? onDisconnected,
    void Function(bool verifyOk)? onVerifyResult,
  }) async {
    final myGen = _generation; // 记录本 listener 所属代际
    final control = await _openBiStream();
    await _write(control, Protocol.buildControlChannel());

    var serverRequested = false;
    // 持续读取服务端发来的控制消息（断线检测、断开通知、完整性校验结果）
    while (_connected && myGen == _generation) {
      try {
        final typeBytes = await _readOrNull(control, 4);
        if (typeBytes == null) break; // 控制流被服务端关闭 → 连接断开
        final type = ByteData.sublistView(typeBytes).getUint32(0);
        if (type == Protocol.messageTypeDisconnectNotify) {
          // 服务端主动断开（如对端点击「断开连接」）
          serverRequested = true;
          break;
        } else if (type == Protocol.messageTypeVerifyResult) {
          // 服务端回传 BLAKE3 完整性校验结果：再读 1 字节并上报（继续监听）
          final resultBytes = await _readOrNull(control, 1);
          if (resultBytes == null) break;
          onVerifyResult?.call(resultBytes[0] == 1);
        }
        // 忽略未知的控制消息类型
      } catch (_) {
        // 连接断开，优雅退出监听循环
        break;
      }
    }
    // 监听循环退出（服务端断开 / 本地关闭），只有当前代际才通知上层连接已断开
    // （旧 listener 因 close/重连失效后，即使延迟退出也不再误伤新连接）
    if (myGen == _generation) {
      onDisconnected?.call(serverRequested);
    }
  }

  // ===== 底层 flutter_quic 调用 =====

  Future<_BiStream> _openBiStream() async {
    final result = await connectionOpenBi(connection: _connection!);
    _connection = result.$1;
    return _BiStream(result.$2, result.$3);
  }

  Future<void> _write(_BiStream stream, Uint8List data) async {
    stream.send = await sendStreamWriteAll(stream: stream.send, data: data);
  }

  Future<void> _finishSend(_BiStream stream) async {
    stream.send = await sendStreamFinish(stream: stream.send);
  }

  Future<Uint8List> _read(_BiStream stream, int length) async {
    final out = BytesBuilder();
    int total = 0;
    while (total < length) {
      final result = await recvStreamRead(
        stream: stream.recv,
        maxLength: BigInt.from(length - total),
      );
      stream.recv = result.$1;
      final data = result.$2;
      if (data == null || data.isEmpty) {
        throw const FileSystemException('连接意外关闭，数据不完整');
      }
      out.add(data);
      total += data.length;
    }
    return out.toBytes();
  }

  Future<Uint8List?> _readOrNull(_BiStream stream, int length) async {
    final out = BytesBuilder();
    int total = 0;
    while (total < length) {
      final result = await recvStreamRead(
        stream: stream.recv,
        maxLength: BigInt.from(length - total),
      );
      stream.recv = result.$1;
      final data = result.$2;
      if (data == null) {
        if (total == 0) return null;
        throw const FileSystemException('数据不完整');
      }
      if (data.isEmpty) {
        if (total == 0) return null;
        throw const FileSystemException('数据不完整');
      }
      out.add(data);
      total += data.length;
    }
    return out.toBytes();
  }

  Future<Uint8List> _readToEnd(_BiStream stream) async {
    final result = await recvStreamReadToEnd(
      stream: stream.recv,
      maxLength: BigInt.from(1024 * 1024 * 1024),
    );
    stream.recv = result.$1;
    return result.$2;
  }
}
