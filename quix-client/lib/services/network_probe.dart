//! 网络探测：根据链路速率推荐最优传输参数

class NetworkProbe {
  NetworkProbe._();

  /// 根据链路速率推荐最优传输参数
  /// 分档原则：高速网络用大分块（减少块数量与 ACK 开销）+ 高并发（充分占用带宽）；
  /// 低速网络用小分块（降低重传成本）+ 低并发（避免拥塞）。
  /// 同时控制「分块大小 × 并发流数」的峰值内存，避免移动端内存过大。
  static ({int chunkSize, int concurrency}) recommend(int? mbps) {
    if (mbps == null) {
      return (chunkSize: 4 * 1024 * 1024, concurrency: 8);
    }
    if (mbps >= 2500) {
      // 2.5G / 万兆有线
      return (chunkSize: 16 * 1024 * 1024, concurrency: 16);
    }
    if (mbps >= 1000) {
      // 千兆有线
      return (chunkSize: 8 * 1024 * 1024, concurrency: 16);
    }
    if (mbps >= 500) {
      // 高速 WiFi6 / 5G
      return (chunkSize: 8 * 1024 * 1024, concurrency: 12);
    }
    if (mbps >= 300) {
      // 中高速 WiFi6
      return (chunkSize: 4 * 1024 * 1024, concurrency: 8);
    }
    if (mbps >= 100) {
      // 百兆有线 / 普通 WiFi5
      return (chunkSize: 4 * 1024 * 1024, concurrency: 6);
    }
    if (mbps >= 50) {
      // 较慢 WiFi / 宽带
      return (chunkSize: 2 * 1024 * 1024, concurrency: 4);
    }
    if (mbps >= 20) {
      // 低速网络
      return (chunkSize: 1 * 1024 * 1024, concurrency: 4);
    }
    // 极低速网络
    return (chunkSize: 1 * 1024 * 1024, concurrency: 2);
  }
}
