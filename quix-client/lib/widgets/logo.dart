//! 品牌 Logo：QuiX 整体使用品牌渐变（青 → 蓝）

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class Logo extends StatelessWidget {
  final double fontSize;

  const Logo({super.key, this.fontSize = 22});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => QxColors.brandGradient.createShader(bounds),
      child: Text(
        'QuiX',
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );
  }
}
