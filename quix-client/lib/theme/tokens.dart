import 'package:flutter/material.dart';

/// QuiX 设计 Token：颜色、渐变、圆角、断点集中管理。
/// 所有界面应引用这里的常量，而非散落硬编码色值，便于整体换肤。
abstract final class QxColors {
  // 品牌
  static const primary = Color(0xFF00D4FF); // 电光青（主色）
  static const primaryEnd = Color(0xFF4F7CFF); // 品牌渐变尾色（蓝）
  static const onPrimary = Color(0xFF0B0E12); // 主色之上的文字/图标

  // 背景（三级）
  static const bg = Color(0xFF121417); // 背景主
  static const surface = Color(0xFF1A1D22); // 卡片/次级表面
  static const surface2 = Color(0xFF202429); // 输入框/浮层/三级表面

  // 边框与分隔
  static const border = Color(0xFF2A2E35);

  // 语义色
  static const success = Color(0xFF34C759); // 成功/已连接
  static const warning = Color(0xFFFF9500); // 警告/进行中
  static const danger = Color(0xFFFF453A); // 失败/破坏性操作

  // 文本（基于白色透明度，避免硬编码不透明度的散落写法）
  static const textPrimary = Colors.white;
  static const textSecondary = Color(0xB3FFFFFF); // ~70% 白
  static const textTertiary = Color(0x80FFFFFF); // ~50% 白
  static const textDisabled = Color(0x59FFFFFF); // ~35% 白

  /// 品牌渐变：青 → 蓝（Logo / 进度条 / 主按钮）
  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primary, primaryEnd],
  );
}

/// 圆角规范
abstract final class QxRadius {
  static const card = 16.0;
  static const button = 10.0;
  static const input = 8.0;
}

/// 响应式断点
abstract final class QxBreakpoints {
  /// 宽屏（桌面端侧边栏布局）阈值
  static const desktop = 900.0;
}
