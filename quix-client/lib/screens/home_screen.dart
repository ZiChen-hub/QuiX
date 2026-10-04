//! 首页：品牌标识、连接信息、文件选择与发送

import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/transfer_provider.dart';
import '../theme/tokens.dart';
import '../utils/quix_url.dart';
import '../widgets/connection_card.dart';
import '../widgets/file_selector.dart';
import '../widgets/gradient_button.dart';
import '../widgets/mode_switch.dart';
import '../widgets/progress_bar.dart';
import '../widgets/status_indicator.dart';
import 'scan_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _ipController =
      TextEditingController(text: '127.0.0.1');
  final TextEditingController _portController =
      TextEditingController(text: '4433');
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _smartController = TextEditingController();
  final TextEditingController _textController = TextEditingController();

  // 跨网络 ZeroTier 网络 ID（从粘贴的 URI 解析，非空时连接前先加入该网络）
  String _nwid = '';
  // 跨网络可达地址（从粘贴的 URI 解析，局域网直连失败后作为备选）
  String _xip = '';

  // 主动测速状态
  bool _speedTesting = false;

  // 已通过扫码解析到连接信息：隐藏扫码按钮；连接失败或重启 App 后恢复
  bool _scanConsumed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TransferProvider>().loadRecentDevices();
    });
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    _codeController.dispose();
    _smartController.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null && result.files.isNotEmpty) {
      final files = result.files
          .where((f) => f.path != null)
          .map((f) => File(f.path!))
          .toList();
      if (files.isNotEmpty && mounted) {
        context.read<TransferProvider>().selectFiles(files);
      }
    }
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path != null && path.isNotEmpty && mounted) {
      await context.read<TransferProvider>().selectFolder(path);
    }
  }

  /// 智能输入：粘贴 quix://IP:PORT?code=XXXX 时自动填充 IP/端口/连接码
  void _onSmartInputChanged(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('quix://')) return;
    final parsed = QuixUrl.parse(trimmed);
    if (parsed == null) return;
    _ipController.text = parsed.host;
    _portController.text = '${parsed.port}';
    _codeController.text = parsed.code;
    _nwid = parsed.nwid;
    _xip = parsed.xip;
    // 填充后清空智能输入框，避免二次触发
    _smartController.clear();
    if (mounted) {
      _showSnack('已识别连接信息');
    }
  }

  /// 扫码连接：扫码页解析到连接信息后立即关闭并回传，
  /// 此处填充表单、隐藏扫码按钮并发起连接；连接失败则恢复扫码按钮
  Future<void> _scanAndConnect() async {
    final info = await Navigator.push<QuixUrl>(
      context,
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (info == null || !mounted) return;
    _ipController.text = info.host;
    _portController.text = '${info.port}';
    _codeController.text = info.code;
    _nwid = info.nwid;
    _xip = info.xip;
    setState(() => _scanConsumed = true);
    _showSnack('已识别连接信息，正在连接...');
    await context.read<TransferProvider>().connect(
          info.host,
          info.port,
          code: info.code,
          nwid: info.nwid,
          xip: info.xip,
        );
    // 连接失败：恢复扫码按钮，允许重新扫码
    if (mounted && !context.read<TransferProvider>().isConnected) {
      setState(() => _scanConsumed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TransferProvider>();
    const success = QxColors.success;

    return DropTarget(
      onDragDone: (detail) {
        final files = detail.files
            .where((f) => f.path.isNotEmpty)
            .map((f) => File(f.path))
            .toList();
        if (files.isEmpty) return;
        if (files.length == 1 && Directory(files.first.path).existsSync()) {
          context.read<TransferProvider>().selectFolder(files.first.path);
        } else {
          context.read<TransferProvider>().selectFiles(files);
        }
      },
      child: Scaffold(
        body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 品牌标识 + 连接状态（桌面端顶部显示设备名/首页，移动端显示品牌）
              Row(
                children: [
                  Text(
                    MediaQuery.of(context).size.width >= 900
                        ? (provider.deviceName.isNotEmpty
                            ? provider.deviceName
                            : '首页')
                        : 'QuiX',
                    style: TextStyle(
                      fontSize:
                          MediaQuery.of(context).size.width >= 900 ? 20 : 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  StatusIndicator(
                    color: provider.isConnected ? success : Colors.white30,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    provider.connectionType,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.7),
                    ),
                  ),
                  const Spacer(),
                  // 扫码连接入口（仅移动端；扫码解析到信息后立即隐藏，
                  // 桌面端无摄像头扫码插件，不显示）
                  if ((Platform.isAndroid || Platform.isIOS) &&
                      !_scanConsumed)
                    TextButton.icon(
                      onPressed: _scanAndConnect,
                      icon: const Icon(Icons.qr_code_scanner,
                          size: 18, color: QxColors.primary),
                      label: const Text(
                        '扫码',
                        style: TextStyle(color: QxColors.primary, fontSize: 13),
                      ),
                    ),
                  // 模式切换按钮：与接收模式一致，固定在右上角
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Center(child: const ModeSwitch()),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 智能输入框：粘贴 quix://IP:PORT?code=XXXX 自动填充（连接成功后隐藏）
              if (!provider.isConnected) ...[
                TextField(
                  controller: _smartController,
                  onChanged: _onSmartInputChanged,
                  style: const TextStyle(fontSize: 14, color: Colors.white),
                  decoration: InputDecoration(
                    hintText: '粘贴连接地址 quix://IP:端口?code=连接码',
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
                    prefixIcon: const Icon(Icons.link, size: 18, color: QxColors.primary),
                    filled: true,
                    fillColor: QxColors.surface2,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // 连接信息卡片
              ConnectionCard(
                ip: provider.serverIp.isEmpty ? '未连接' : provider.serverIp,
                port: provider.serverPort,
                code: provider.connectionCode.isEmpty
                    ? '--------'
                    : provider.connectionCode,
                statusText: provider.statusMessage,
                statusColor:
                    provider.isConnected ? success : QxColors.warning,
              ),
              const SizedBox(height: 16),

              // 连接成功后提供断开连接入口（连接设置区已隐藏）
              if (provider.isConnected)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: QxColors.danger,
                      side: const BorderSide(color: QxColors.border),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: const Icon(Icons.link_off, size: 16),
                    onPressed: () => context.read<TransferProvider>().disconnect(),
                    label: const Text('断开连接'),
                  ),
                ),

              // 最近连接（一键重连）
              if (provider.recentDevices.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '最近连接',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withOpacity(0.7),
                  ),
                ),
                Column(
                  children: provider.recentDevices.map((d) {
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        d.deviceName.isNotEmpty ? d.deviceName : d.ip,
                        style: const TextStyle(fontSize: 14, color: Colors.white),
                      ),
                      subtitle: Text(
                        '${d.ip}:${d.port}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 16, color: Colors.white38),
                        onPressed: () => context
                            .read<TransferProvider>()
                            .removeRecentDevice(d.ip, d.port),
                      ),
                      onTap: () => context
                          .read<TransferProvider>()
                          .connect(d.ip, d.port,
                              deviceName: d.deviceName, nwid: d.nwid),
                    );
                  }).toList(),
                ),
              ],
              const SizedBox(height: 16),

              // 连接设置（连接成功后隐藏，断开后重新显示）
              if (!provider.isConnected) ...[
                Text(
                  '连接设置',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withOpacity(0.7),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildField(controller: _ipController, label: '服务器 IP'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: _buildField(controller: _portController, label: '端口'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildField(controller: _codeController, label: '连接码（8 位字母数字）'),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () async {
                      final ip = _ipController.text.trim();
                      final port = int.tryParse(_portController.text.trim());
                      final code = _codeController.text.trim();
                      if (ip.isEmpty || port == null) {
                        _showSnack('请输入有效的 IP 和端口');
                        return;
                      }
                      await provider.connect(ip, port,
                          code: code, nwid: _nwid, xip: _xip);
                    },
                    child: const Text('连接'),
                  ),
                ),
              ],
              const SizedBox(height: 24),

              // 剪贴板文本传输
              Text(
                '发送文本',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.7),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      enabled: provider.isConnected,
                      onSubmitted: (_) => _sendText(),
                      style: const TextStyle(fontSize: 13, color: Colors.white),
                      decoration: InputDecoration(
                        hintText: '输入文本，发送到对端剪贴板',
                        hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                        filled: true,
                        fillColor: QxColors.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: provider.isConnected ? _sendText : null,
                    tooltip: '发送文本',
                    icon: const Icon(Icons.send, color: QxColors.primary),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // 智能测速配置传输参数（连接后可用）
              if (provider.isConnected)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _speedTesting ? null : _runSpeedTest,
                    icon: const Icon(Icons.speed, size: 16, color: QxColors.primary),
                    label: Text(
                      _speedTesting ? '测速中...' : '智能测速配置传输参数',
                      style: const TextStyle(color: QxColors.primary, fontSize: 13),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: QxColors.primary),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              if (provider.isConnected) const SizedBox(height: 24),

              // 文件选择
              FileSelector(
                fileName: provider.fileName,
                count: provider.selectedCount,
                onBrowse: _pickFile,
                onBrowseFolder: _pickFolder,
              ),
              const SizedBox(height: 16),

              // 发送按钮
              SizedBox(
                width: double.infinity,
                child: GradientButton(
                  height: 48,
                  onPressed: (provider.isConnected &&
                          provider.selectedFile != null &&
                          !provider.isTransferring)
                      ? () => context.read<TransferProvider>().sendFile()
                      : null,
                  child: Text(provider.isTransferring ? '发送中...' : '发送文件'),
                ),
              ),
              const SizedBox(height: 16),

              // 进度条
              if (provider.isTransferring || provider.progress > 0)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ProgressBar(value: provider.progress),
                    const SizedBox(height: 8),
                    Text(
                      '${provider.queueTotal > 1 ? '队列 ${provider.queueIndex + 1}/${provider.queueTotal} · ' : ''}'
                      '${(provider.progress * 100).toStringAsFixed(0)}% · ${provider.speed}'
                      '${provider.eta.isNotEmpty ? ' · ${provider.eta}' : ''}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.6),
                      ),
                    ),
                    if (provider.isTransferring) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: provider.paused
                                  ? () => context.read<TransferProvider>().resume()
                                  : () => context.read<TransferProvider>().pause(),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: QxColors.primary,
                                side: const BorderSide(color: QxColors.border),
                              ),
                              icon: Icon(provider.paused ? Icons.play_arrow : Icons.pause, size: 16),
                              label: Text(provider.paused ? '继续' : '暂停'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => context.read<TransferProvider>().cancel(),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: QxColors.danger,
                                side: const BorderSide(color: QxColors.border),
                              ),
                              icon: const Icon(Icons.close, size: 16),
                              label: const Text('取消'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
  }) {
    return TextField(
      controller: controller,
      keyboardType: label == '端口'
          ? TextInputType.number
          : TextInputType.text,
      style: const TextStyle(fontSize: 14, color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
        filled: true,
        fillColor: QxColors.surface2,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }

  /// 发送剪贴板文本到对端
  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    await context.read<TransferProvider>().sendText(text);
    _textController.clear();
    _showSnack('文本已发送');
  }

  /// 主动测速并应用最优参数
  Future<void> _runSpeedTest() async {
    setState(() => _speedTesting = true);
    try {
      final result =
          await context.read<TransferProvider>().speedTestAndApply();
      _showSnack(result);
    } catch (e) {
      _showSnack('测速失败：$e');
    } finally {
      if (mounted) setState(() => _speedTesting = false);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
