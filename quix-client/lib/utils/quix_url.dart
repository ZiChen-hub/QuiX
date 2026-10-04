//! 解析 QuiX 连接 URL：quix://<ip>:<port>?code=<8位连接码>&nwid=<ZeroTier网络ID>

class QuixUrl {
  final String host;
  final int port;
  final String code;
  final String nwid;
  final String xip;

  QuixUrl({
    required this.host,
    required this.port,
    required this.code,
    required this.nwid,
    required this.xip,
  });

  /// 解析二维码中的连接地址，格式不符则返回 null
  static QuixUrl? parse(String url) {
    try {
      final uri = Uri.parse(url.trim());
      if (uri.scheme != 'quix' || uri.host.isEmpty) {
        return null;
      }
      return QuixUrl(
        host: uri.host,
        port: uri.hasPort ? uri.port : 4433,
        code: uri.queryParameters['code'] ?? '',
        nwid: uri.queryParameters['nwid'] ?? '',
        xip: uri.queryParameters['xip'] ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}
