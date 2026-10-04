//! 启动页（首次启动）：选择「我发送」或「我接收」模式
//! iOS 仅显示「我发送」；Android 与桌面端双模式可选

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_mode.dart';
import '../providers/app_provider.dart';
import '../theme/tokens.dart';
import '../widgets/logo.dart';

class StartupScreen extends StatelessWidget {
  const StartupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppProvider>();

    return Scaffold(
      backgroundColor: QxColors.bg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo：品牌渐变
              const Logo(fontSize: 44),
              const SizedBox(height: 8),
              Text(
                '极速文件传输',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.5),
                ),
              ),
              const SizedBox(height: 48),
              _ModeButton(
                icon: Icons.arrow_upward,
                title: '我发送',
                subtitle: '连接其他设备，发送文件',
                onTap: () => app.setMode(AppMode.send),
              ),
              const SizedBox(height: 16),
              if (!Platform.isIOS)
                _ModeButton(
                  icon: Icons.arrow_downward,
                  title: '我接收',
                  subtitle: '等待其他设备连接，接收文件',
                  onTap: () => app.setMode(AppMode.receive),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ModeButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 320,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          color: QxColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: QxColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, color: QxColors.primary, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.45),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white38),
          ],
        ),
      ),
    );
  }
}
