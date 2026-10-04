//! 扫码页：扫描服务器二维码建立连接
//! 说明：qr_code_scanner 的精确 API 以实际版本为准。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';

import '../theme/tokens.dart';
import '../utils/quix_url.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final GlobalKey _qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? _controller;
  bool _handled = false;

  @override
  void reassemble() {
    super.reassemble();
    // 热重载时恢复相机
    if (_controller != null) {
      _controller!.pauseCamera();
    }
  }

  void _onQRViewCreated(QRViewController controller) {
    _controller = controller;
    controller.scannedDataStream.listen((scanData) {
      final raw = scanData.code;
      if (raw == null || _handled) return;
      _handled = true;
      _handleScan(raw);
    });
  }

  Future<void> _handleScan(String raw) async {
    final info = QuixUrl.parse(raw);
    if (info == null) {
      if (mounted) {
        _showError('无效的二维码');
      }
      _handled = false; // 允许重新扫描
      return;
    }

    // 解析成功：不等待连接，立即震动反馈并关闭扫码页，
    // 将连接信息回传给首页（由首页发起连接并隐藏扫码按钮）
    HapticFeedback.mediumImpact();
    if (mounted) {
      Navigator.of(context).pop<QuixUrl>(info);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: QxColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '扫码连接',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                QRView(
                  key: _qrKey,
                  onQRViewCreated: _onQRViewCreated,
                ),
                // 居中取景框
                Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    border: Border.all(color: QxColors.primary, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(
                  '扫描服务器二维码以建立连接',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    '取消',
                    style: TextStyle(color: QxColors.primary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
