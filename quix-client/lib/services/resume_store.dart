//! 断点续传记录：持久化 file_id，跨重连复用
//! 使用 shared_preferences 以「文件路径:文件大小:分块大小」为键记录 file_id。

import 'package:shared_preferences/shared_preferences.dart';

class ResumeStore {
  static const String _prefix = 'quix_resume_';

  /// 获取文件对应的 file_id（不存在则返回 null）。
  // R13：键中纳入 chunk_size，分块配置变化后视为全新传输（不复用旧 file_id）
  static Future<String?> getFileId(String path, int size, int chunkSize) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key(path, size, chunkSize));
  }

  /// 保存文件对应的 file_id
  static Future<void> saveFileId(
      String path, int size, int chunkSize, String fileId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(path, size, chunkSize), fileId);
  }

  /// 清除某文件的续传记录（传输完成后调用）
  static Future<void> clear(String path, int size, int chunkSize) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(path, size, chunkSize));
  }

  static String _key(String path, int size, int chunkSize) =>
      '$_prefix$path:$size:$chunkSize';
}
