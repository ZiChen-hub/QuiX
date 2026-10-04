//! 进度条：高度严格 3px，默认品牌渐变（青 → 蓝），可选纯色

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class ProgressBar extends StatelessWidget {
  final double value; // 0.0 - 1.0
  final Color? color; // 为 null 时使用品牌渐变

  const ProgressBar({
    super.key,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final factor = value.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(1.5),
      child: Stack(
        children: [
          Container(height: 3, color: Colors.white.withOpacity(0.08)),
          FractionallySizedBox(
            widthFactor: factor,
            child: Container(
              decoration: BoxDecoration(
                gradient: color != null
                    ? LinearGradient(colors: [color!, color!])
                    : QxColors.brandGradient,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
