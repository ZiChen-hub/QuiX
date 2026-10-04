//! 文件分块逻辑：将文件切分为固定大小的块

import 'dart:io';
import 'dart:typed_data';

class FileChunker {
  final int chunkSize;

  // R19：为每条发送流（readerId = streamIndex）复用一个长期 RandomAccessFile，
  // 避免每个块都 open/close（高块数时开销显著）。
  // 各流持有独立句柄：单流内 setPosition+read 串行，流之间互不干扰
  final Map<int, RandomAccessFile> _handles = {};
  // 同一 readerId 并发打开时共享同一个 Future，防止重复打开
  final Map<int, Future<RandomAccessFile>> _opening = {};

  FileChunker({this.chunkSize = 4 * 1024 * 1024});

  /// 计算文件所需的总块数
  int totalChunks(int fileSize) => (fileSize + chunkSize - 1) ~/ chunkSize;

  /// 获取（或首次打开并缓存）指定读取者的长期句柄
  Future<RandomAccessFile> _handle(File file, int readerId) {
    final existing = _handles[readerId];
    if (existing != null) return Future<RandomAccessFile>.value(existing);
    return _opening.putIfAbsent(readerId, () async {
      final raf = await file.open();
      _handles[readerId] = raf;
      _opening.remove(readerId);
      return raf;
    });
  }

  /// 读取指定索引的数据块（[readerId] 标识调用它的发送流）
  Future<Uint8List> readChunk(File file, int chunkIndex, int readerId) async {
    final raf = await _handle(file, readerId);
    final offset = chunkIndex * chunkSize;
    await raf.setPosition(offset);
    final remaining = await raf.length() - offset;
    final length = remaining < chunkSize ? remaining : chunkSize;
    return raf.read(length);
  }

  /// 关闭并释放所有缓存的文件句柄（传输结束后调用）
  Future<void> close() async {
    final handles = _handles.values.toList();
    _handles.clear();
    _opening.clear();
    for (final raf in handles) {
      await raf.close();
    }
  }
}
