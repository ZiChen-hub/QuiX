//! 应用模式（统一程序版）：发送 = 客户端，接收 = 服务端

/// 应用运行模式
enum AppMode { send, receive }

extension AppModeLabel on AppMode {
  String get label => this == AppMode.send ? '我发送' : '我接收';
}
