//! 协议编解码：与 Rust 服务端字节级协议一致（统一使用大端序）
//! 消息格式详见开发案第 4 节。消息类型统一为 4 字节（u32 大端序）。

import 'dart:convert';
import 'dart:typed_data';

import '../models/file_metadata.dart';

/// 协议编解码工具
class Protocol {
  static const int messageTypeMetadata = 1;
  static const int messageTypeChunkData = 2;
  static const int messageTypeResumeRequest = 5;
  static const int messageTypeResumeResponse = 6;
  static const int messageTypeAck = 7;
  // 客户端→服务端「控制流注册」标记（连接存活监测）
  static const int messageTypeControlChannel = 8;
  // 连接鉴权：客户端连接后立即发送连接码
  static const int messageTypeHello = 10;
  // 剪贴板文本消息（客户端 → 服务端）
  static const int messageTypeTextMessage = 11;
  // 主动测速（客户端 → 服务端）
  static const int messageTypeSpeedTest = 12;
  // 断开通知（双向）：客户端→服务端表示主动退出；服务端→客户端表示主动踢出
  static const int messageTypeDisconnectNotify = 13;
  // 完整性校验结果（服务端 → 客户端）：1 字节，1=BLAKE3 校验通过，0=失败
  static const int messageTypeVerifyResult = 14;

  /// 元数据响应中「拒绝」的哨兵值（连接码错误等拒绝场景）
  static const int rejectSentinel = 0xFFFFFFFFFFFFFFFF;

  /// 构建元数据消息：[1:4][json_len:8][json]
  static Uint8List buildMetadataMessage(FileMetadata meta) {
    final json = Uint8List.fromList(utf8.encode(jsonEncode(meta.toJson())));
    final buf = ByteData(4 + 8 + json.length);
    buf.setUint32(0, messageTypeMetadata);
    buf.setUint64(4, json.length);
    final out = buf.buffer.asUint8List();
    out.setRange(12, 12 + json.length, json);
    return out;
  }

  /// 构建数据块消息：[2:4][id_len:4][id][index:8][data_len:8][data]
  static Uint8List buildChunkMessage(String fileId, int chunkIndex, Uint8List data) {
    final id = Uint8List.fromList(utf8.encode(fileId));
    final buf = ByteData(4 + 4 + id.length + 8 + 8 + data.length);
    int offset = 0;
    buf.setUint32(offset, messageTypeChunkData);
    offset += 4;
    buf.setUint32(offset, id.length);
    offset += 4;
    final out = buf.buffer.asUint8List();
    out.setRange(offset, offset + id.length, id);
    offset += id.length;
    buf.setUint64(offset, chunkIndex);
    offset += 8;
    buf.setUint64(offset, data.length);
    offset += 8;
    out.setRange(offset, offset + data.length, data);
    return out;
  }

  /// 解析元数据响应：[count:8][bitmap_json]
  static MetadataResponse parseMetadataResponse(Uint8List resp) {
    final buf = ByteData.sublistView(resp);
    final count = buf.getUint64(0);
    final bitmapJson = utf8.decode(resp.sublist(8));
    return MetadataResponse(count: count, bitmap: _parseBitmap(bitmapJson));
  }

  /// 构建断点续传请求：[5:4][id_len:4][id][code_len:4][code]
  static Uint8List buildResumeRequest(String fileId, String code) {
    final id = Uint8List.fromList(utf8.encode(fileId));
    final codeBytes = Uint8List.fromList(utf8.encode(code));
    final buf = ByteData(4 + 4 + id.length + 4 + codeBytes.length);
    int offset = 0;
    buf.setUint32(offset, messageTypeResumeRequest);
    offset += 4;
    buf.setUint32(offset, id.length);
    offset += 4;
    final out = buf.buffer.asUint8List();
    out.setRange(offset, offset + id.length, id);
    offset += id.length;
    buf.setUint32(offset, codeBytes.length);
    offset += 4;
    out.setRange(offset, offset + codeBytes.length, codeBytes);
    return out;
  }

  /// 解析断点续传响应：[6:4][bitmap_json]
  static List<int> parseResumeResponse(Uint8List resp) {
    // 前 4 字节为类型 6，其余为位图 JSON
    return _parseBitmap(utf8.decode(resp.sublist(4)));
  }

  /// 构建控制流注册消息：[8:4]（连接后主动注册，用于存活监测）
  static Uint8List buildControlChannel() {
    final buf = ByteData(4);
    buf.setUint32(0, messageTypeControlChannel);
    return buf.buffer.asUint8List();
  }

  /// 构建连接鉴权消息：[10:4][code_len:4][code][device_type_len:4][device_type]
  static Uint8List buildHello(String code, String deviceType) {
    final codeBytes = utf8.encode(code);
    final typeBytes = utf8.encode(deviceType);
    final data = ByteData(4 + 4 + codeBytes.length + 4 + typeBytes.length);
    final out = data.buffer.asUint8List();
    var off = 0;
    data.setUint32(off, messageTypeHello);
    off += 4;
    data.setUint32(off, codeBytes.length);
    off += 4;
    out.setRange(off, off + codeBytes.length, codeBytes);
    off += codeBytes.length;
    data.setUint32(off, typeBytes.length);
    off += 4;
    out.setRange(off, off + typeBytes.length, typeBytes);
    return out;
  }

  /// 构建剪贴板文本消息：[11:4][text_len:4][text]
  static Uint8List buildTextMessage(String text) {
    final textBytes = Uint8List.fromList(utf8.encode(text));
    final buf = ByteData(4 + 4 + textBytes.length);
    buf.setUint32(0, messageTypeTextMessage);
    buf.setUint32(4, textBytes.length);
    final out = buf.buffer.asUint8List();
    out.setRange(8, 8 + textBytes.length, textBytes);
    return out;
  }

  /// 构建主动测速消息头：[12:4][total_bytes:8]（数据紧随其后）
  static Uint8List buildSpeedTestHeader(int totalBytes) {
    final buf = ByteData(4 + 8);
    buf.setUint32(0, messageTypeSpeedTest);
    buf.setUint64(4, totalBytes);
    return buf.buffer.asUint8List();
  }

  /// 构建断开通知消息：[13:4]（客户端主动断开时发送，服务端据此立即释放连接）
  static Uint8List buildDisconnectNotify() {
    final buf = ByteData(4);
    buf.setUint32(0, messageTypeDisconnectNotify);
    return buf.buffer.asUint8List();
  }

  /// 构建元数据响应：[count:8][bitmap_json]（上传方向，客户端作为接收方使用）
  static Uint8List buildMetadataResponse(int count, List<int> bitmap) {
    final bitmapJson = Uint8List.fromList(utf8.encode(jsonEncode(bitmap)));
    final buf = ByteData(8 + bitmapJson.length);
    buf.setUint64(0, count);
    final out = buf.buffer.asUint8List();
    out.setRange(8, 8 + bitmapJson.length, bitmapJson);
    return out;
  }

  /// 构建数据块 ACK：[chunk_index:8][received_count:8]
  static Uint8List buildAck(int chunkIndex, int receivedCount) {
    final buf = ByteData(16);
    buf.setUint64(0, chunkIndex);
    buf.setUint64(8, receivedCount);
    return buf.buffer.asUint8List();
  }

  /// 解析元数据消息 JSON 为 FileMetadata（接收方使用）
  static FileMetadata parseFileMetadata(String json) {
    return FileMetadata.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  /// 解析位图 JSON 数组（元素 0/1 表示该块是否已接收）
  static List<int> _parseBitmap(String json) {
    final decoded = jsonDecode(json);
    if (decoded is List) {
      return decoded.map((e) => (e as num).toInt()).toList();
    }
    return [];
  }

  /// 解析 ACK：[chunk_index:8][received_count:8]
  static Ack parseAck(Uint8List ack) {
    final buf = ByteData.sublistView(ack);
    return Ack(
      chunkIndex: buf.getUint64(0),
      receivedCount: buf.getUint64(8),
    );
  }
}

/// 元数据响应
class MetadataResponse {
  final int count;
  final List<int> bitmap;
  MetadataResponse({required this.count, required this.bitmap});
}

/// 数据块确认
class Ack {
  final int chunkIndex;
  final int receivedCount;
  Ack({required this.chunkIndex, required this.receivedCount});
}
