//! 连接信息卡片：毛玻璃材质，展示 IP/端口/连接码

import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/tokens.dart';
import 'status_indicator.dart';

class ConnectionCard extends StatelessWidget {
  final String ip;
  final int port;
  final String code;
  final String statusText;
  final Color statusColor;

  const ConnectionCard({
    super.key,
    required this.ip,
    required this.port,
    required this.code,
    required this.statusText,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    // 毛玻璃效果
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$ip:$port',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '连接码 $code',
                style: TextStyle(
                  fontSize: 12,
                  color: QxColors.primary,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  StatusIndicator(color: statusColor),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      statusText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
