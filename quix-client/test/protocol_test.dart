//! 协议编解码单元测试：校验与 Rust 服务端字节级协议的一致性（大端序）

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quix_client/services/protocol.dart';

void main() {
  group('buildHello', () {
    test('编码 [10][code_len][code][device_type_len][device_type]', () {
      final hello = Protocol.buildHello('123456', 'mobile');
      final buf = ByteData.sublistView(hello);
      expect(buf.getUint32(0), Protocol.messageTypeHello);
      expect(buf.getUint32(4), 6);
      expect(utf8.decode(hello.sublist(8, 14)), '123456');
      expect(buf.getUint32(14), 6);
      expect(utf8.decode(hello.sublist(18)), 'mobile');
    });
  });

  group('buildChunkMessage', () {
    test('编码 [2][id_len][id][index:8][data_len:8][data]', () {
      final data = Uint8List.fromList([1, 2, 3, 4]);
      final msg = Protocol.buildChunkMessage('fid', 7, data);
      final buf = ByteData.sublistView(msg);
      expect(buf.getUint32(0), Protocol.messageTypeChunkData);
      expect(buf.getUint32(4), 3);
      expect(utf8.decode(msg.sublist(8, 11)), 'fid');
      expect(buf.getUint64(11), 7);
      expect(buf.getUint64(19), 4);
      expect(msg.sublist(27), data);
    });
  });

  group('buildResumeRequest', () {
    test('编码 [5][id_len][id][code_len][code]', () {
      final req = Protocol.buildResumeRequest('fid', '123456');
      final buf = ByteData.sublistView(req);
      expect(buf.getUint32(0), Protocol.messageTypeResumeRequest);
      expect(buf.getUint32(4), 3);
      expect(utf8.decode(req.sublist(8, 11)), 'fid');
      expect(buf.getUint32(11), 6);
      expect(utf8.decode(req.sublist(15)), '123456');
    });
  });

  group('parseMetadataResponse', () {
    test('解析 [count:8][bitmap_json]', () {
      final bitmapJson = Uint8List.fromList(utf8.encode(jsonEncode([0, 1, 1, 0])));
      final resp = Uint8List(8 + bitmapJson.length);
      ByteData.sublistView(resp).setUint64(0, 3);
      resp.setRange(8, 8 + bitmapJson.length, bitmapJson);

      final parsed = Protocol.parseMetadataResponse(resp);
      expect(parsed.count, 3);
      expect(parsed.bitmap, [0, 1, 1, 0]);
    });
  });

  group('parseResumeResponse', () {
    test('解析 [6][bitmap_json]', () {
      final bitmapJson = Uint8List.fromList(utf8.encode(jsonEncode([1, 0, 1])));
      final resp = Uint8List(4 + bitmapJson.length);
      ByteData.sublistView(resp).setUint32(0, Protocol.messageTypeResumeResponse);
      resp.setRange(4, 4 + bitmapJson.length, bitmapJson);

      expect(Protocol.parseResumeResponse(resp), [1, 0, 1]);
    });
  });

  group('buildAck / parseAck', () {
    test('ACK 往返 [chunk_index:8][received_count:8]', () {
      final ack = Protocol.buildAck(7, 3);
      final parsed = Protocol.parseAck(ack);
      expect(parsed.chunkIndex, 7);
      expect(parsed.receivedCount, 3);
      expect(ack.length, 16);
    });
  });
}
