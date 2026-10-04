//! 操作手册弹窗：按产品、当前模式（发送/接收）与当前端（手机/电脑）展示详细使用说明

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/app_mode.dart';
import '../theme/tokens.dart';

/// 弹出操作手册弹窗（按当前模式展示对应内容）
void showManualDialog(BuildContext context, AppMode mode) {
  showDialog<void>(
    context: context,
    builder: (_) => ManualDialog(mode: mode),
  );
}

class ManualDialog extends StatelessWidget {
  final AppMode mode;

  const ManualDialog({super.key, required this.mode});

  bool get _isSend => mode == AppMode.send;

  String get _modeTitle => _isSend ? '我发送' : '我接收';

  /// 当前端名称
  String get _deviceType => _isMobile ? '手机端' : '电脑端';

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: QxColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 0),
              child: Row(
                children: [
                  const Icon(Icons.menu_book_outlined,
                      size: 20, color: QxColors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '操作手册 · $_modeTitle模式（$_deviceType）',
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: Colors.white),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, size: 20, color: Colors.white54),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 20, color: QxColors.border),
            // 手册正文
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _section('关于 QuiX'),
                    _para('QuiX 是一款基于 QUIC 协议的点对点极速文件传输工具，'
                        '支持手机与电脑之间直连传输文件、文件夹与文本，'
                        '具备断点续传、多流并发、完整性校验（BLAKE3）与主动测速能力。'
                        '同一路径下传输失败可从断点继续，无需从头重传。'),
                    _section('关于「$_modeTitle」模式'),
                    ..._modeIntro(),
                    _section('连接与传输流程'),
                    ..._steps(),
                    _section('跨网络传输（ZeroTier）'),
                    ..._crossNetworkPart(),
                    _section('常见问题'),
                    ..._faq(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 内容章节 ----------------

  List<Widget> _modeIntro() {
    if (_isSend) {
      return [
        _para('「我发送」模式让你的设备作为发送端，把本机的文件、文件夹或文本'
            '发送到处于「我接收」模式的对端设备。发送端需要先与对端建立连接。'),
      ];
    }
    return [
      _para('「我接收」模式让你的设备作为接收端，启动接收服务并等待对端连接，'
          '对端发送的文件会自动保存到接收目录（默认可在设置中修改）。'),
    ];
  }

  List<Widget> _steps() {
    if (_isSend) {
      return _numbered([
        '让对端设备打开「我接收」模式，等待连接。',
        _isMobile
            ? '点击首页右上角「扫码」，扫描对端连接二维码；或复制对端连接地址后粘贴到智能输入框。'
            : '复制对端连接地址（quix://IP:端口?code=连接码）粘贴到智能输入框，'
                '或手动填写服务器 IP、端口与连接码。',
        '点击「连接」按钮，连接成功后状态灯变为绿色，并显示连接类型。',
        '选择要发送的文件或文件夹（桌面端还支持直接拖拽文件到窗口），'
            '也可输入文本发送到对端剪贴板。',
        '点击「发送文件」开始传输，可通过进度条查看进度、速度与剩余时间，'
            '传输中可暂停/继续或取消。',
        '传输完成后可继续发送其他文件；点击「断开连接」结束会话，'
            '对端会同步收到断开通知并更新连接状态。',
      ]);
    }
    return _numbered([
      '打开 App 后接收服务会自动启动（页面左上角显示服务状态）。',
      '把页面中的连接二维码或「复制连接信息」得到的地址发给发送方'
          '（微信/QQ 等任意方式均可）。',
      _isMobile
          ? '发送方扫码或粘贴连接地址发起连接，你也可以在设置中自定义连接码。'
          : '发送方粘贴连接地址或手动填写 IP/端口/连接码发起连接，'
              '你也可以在设置中自定义连接码。',
      '连接建立后，对端发送的文件会自动保存到接收目录，'
          '传输记录页可查看历史记录。',
      '传输完成后点击「断开连接」结束会话，对端会同步收到断开通知。',
    ]);
  }

  List<Widget> _crossNetworkPart() {
    if (_isSend) {
      return [
        _para('跨网络传输用于不在同一局域网时的传输（如手机蜂窝数据 → 电脑）。'
            '发送端无需额外配置：'),
        ..._numbered([
          '请接收方按其手册开启跨网络传输并完成 ZeroTier 授权。',
          '接收方分享给你的连接地址会包含跨网络信息，'
              '直接粘贴到智能输入框即可（首次连接时会自动加入对应 ZeroTier 网络）。',
          '连接成功后即可像局域网一样发送文件。',
        ]),
        _para('提示：跨网络速度取决于双方网络带宽，接收方授权成功后地址中的'
            '「跨网络 IP」才会生效。'),
      ];
    }
    return [
      _para('跨网络传输用于不在同一局域网时的接收（如手机蜂窝数据 ↔ 电脑），'
          '基于 ZeroTier 虚拟局域网实现。开启方式：'),
      ..._numbered([
        '进入设置，打开「跨网络传输」开关。',
        '在弹窗中输入 ZeroTier 网络 ID（Network ID），点击「测试组网」。',
        '首次使用需登录 my.zerotier.com，在对应网络的 Members 列表中'
            '勾选本设备的 Auth 复选框完成授权。',
        '授权成功后本设备自动获得 10.x.x.x 的跨网络 IP，弹窗自动关闭。',
        '连接信息中的地址会附带跨网络信息，发给发送方即可跨互联网接收。',
      ]),
      _para('注意：未完成授权时跨网络 IP 显示「暂未授权」，'
          '此时仍可使用局域网直连；关闭跨网络传输开关后仅启动局域网直连服务。'),
    ];
  }

  List<Widget> _faq() {
    return [
      _qa('连接不上怎么办？',
          '确认双方设备处于同一局域网（或已完成跨网络组网）；'
              '确认接收方服务已启动且连接码输入正确；'
              '检查防火墙是否放行了应用。'),
      _qa('断点续传如何工作？',
          '传输中断后重新连接并选择同一文件发送，'
              '已传输的部分不会重传，仅补传剩余部分。'),
      _qa('传输速度慢？',
          '发送方可在连接后使用「智能测速配置传输参数」实测链路并自动匹配最优分块大小与并发流数；'
              '跨网络传输速度主要受双方宽带/蜂窝网络限制。'),
      if (!_isSend) ...[
        _qa('接收的文件在哪里？',
            '默认保存在系统文档目录/QuiX（手机端为应用专属目录/QuiX），'
                '可在设置的「接收目录」中自定义。'),
        _qa('忘授权 ZeroTier 会怎样？',
            '下次启动服务时会弹出授权提醒，可选择「暂不授权，启动局域网直连服务」，'
                '网络 ID 会保留但跨网络服务不启动。'),
      ],
    ];
  }

  // ---------------- 通用构建 ----------------

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: QxColors.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(title,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
        ],
      ),
    );
  }

  Widget _para(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: Colors.white.withOpacity(0.7))),
    );
  }

  List<Widget> _numbered(List<String> steps) {
    return List.generate(steps.length, (i) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 18,
              height: 18,
              margin: const EdgeInsets.only(right: 8, top: 2),
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: QxColors.primary,
                shape: BoxShape.circle,
              ),
              child: Text('${i + 1}',
                  style: const TextStyle(color: Colors.white, fontSize: 10)),
            ),
            Expanded(
              child: Text(steps[i],
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: Colors.white.withOpacity(0.7))),
            ),
          ],
        ),
      );
    });
  }

  Widget _qa(String q, String a) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: QxColors.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline, size: 15, color: QxColors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(q,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(a,
              style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Colors.white.withOpacity(0.6))),
        ],
      ),
    );
  }
}
