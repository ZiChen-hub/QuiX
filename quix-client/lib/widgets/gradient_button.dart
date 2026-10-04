//! 渐变主按钮：品牌渐变（青 → 蓝）实底 + 深色前景，用于主操作

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class GradientButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final EdgeInsetsGeometry? padding;
  final double height;

  const GradientButton({
    super.key,
    required this.child,
    this.onPressed,
    this.padding,
    this.height = 48,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(QxRadius.button),
          child: Ink(
            height: height,
            padding: padding,
            decoration: BoxDecoration(
              gradient: QxColors.brandGradient,
              borderRadius: BorderRadius.circular(QxRadius.button),
            ),
            child: Center(
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: QxColors.onPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
