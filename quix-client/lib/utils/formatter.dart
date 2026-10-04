//! 格式化工具：文件大小、速率等

class Formatter {
  /// 将字节数格式化为人类可读字符串
  static String formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    if (bytes < 1024) {
      return '$bytes ${units[0]}';
    }
    double value = bytes.toDouble();
    int unit = 0;
    while (value >= 1024.0 && unit < units.length - 1) {
      value /= 1024.0;
      unit += 1;
    }
    return '${value.toStringAsFixed(1)} ${units[unit]}';
  }

  /// 将字节速率格式化为 "x MB/s"
  static String formatSpeed(int bytesPerSecond) {
    return '${formatBytes(bytesPerSecond)}/s';
  }
}
