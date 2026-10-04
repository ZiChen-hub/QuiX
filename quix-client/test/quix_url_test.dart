//! 连接地址解析与格式化工具单元测试

import 'package:flutter_test/flutter_test.dart';
import 'package:quix_client/utils/formatter.dart';
import 'package:quix_client/utils/quix_url.dart';

void main() {
  group('QuixUrl.parse', () {
    test('解析完整连接地址', () {
      final url = QuixUrl.parse('quix://192.168.1.5:4433?code=123456');
      expect(url, isNotNull);
      expect(url!.host, '192.168.1.5');
      expect(url.port, 4433);
      expect(url.code, '123456');
    });

    test('缺少端口时使用默认 4433', () {
      final url = QuixUrl.parse('quix://192.168.1.5?code=123456');
      expect(url, isNotNull);
      expect(url!.port, 4433);
      expect(url.code, '123456');
    });

    test('缺少连接码时返回空字符串', () {
      final url = QuixUrl.parse('quix://192.168.1.5:4433');
      expect(url, isNotNull);
      expect(url!.code, '');
    });

    test('非 quix 协议返回 null', () {
      expect(QuixUrl.parse('http://192.168.1.5:4433?code=1'), isNull);
      expect(QuixUrl.parse('not a url'), isNull);
      expect(QuixUrl.parse(''), isNull);
    });

    test('前后空格可容忍', () {
      final url = QuixUrl.parse('  quix://192.168.1.5:4433?code=123456  ');
      expect(url, isNotNull);
      expect(url!.host, '192.168.1.5');
    });
  });

  group('Formatter', () {
    test('formatBytes', () {
      expect(Formatter.formatBytes(0), '0 B');
      expect(Formatter.formatBytes(512), '512 B');
      expect(Formatter.formatBytes(1024), '1.0 KB');
      expect(Formatter.formatBytes(1024 * 1024), '1.0 MB');
      expect(Formatter.formatBytes(1024 * 1024 * 1024), '1.0 GB');
    });

    test('formatSpeed', () {
      expect(Formatter.formatSpeed(1024), '1.0 KB/s');
    });
  });
}
