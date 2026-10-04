//! 文件哈希计算（BLAKE3）
//! 说明：Dart 官方 `crypto` 包不含 BLAKE3，此处使用 `blake3_dart` 包（纯 Dart 实现）。

import 'dart:io';
import 'dart:typed_data';
// blake3_dart 主库未导出增量哈希所需的 HashContext，故直接引用内部实现
// ignore: implementation_imports
import 'package:blake3_dart/src/blake3_compact.dart'
    show HashContext, asHexString;

class HashUtil {
  /// 计算文件 BLAKE3 哈希（返回 64 位十六进制字符串）。
  /// 流式分块计算，避免大文件整体读入内存导致 OOM。
  static Future<String> computeHash(File file) async {
    final raf = await file.open();
    final ctx = HashContext.unkeyed();
    try {
      final buf = Uint8List(64 * 1024); // 64KB 缓冲
      while (true) {
        final n = await raf.readInto(buf);
        if (n <= 0) break;
        ctx.update(Uint8List.sublistView(buf, 0, n));
      }
    } finally {
      await raf.close();
    }
    final out = Uint8List(32);
    ctx.finalize(out);
    return asHexString(out);
  }
}
