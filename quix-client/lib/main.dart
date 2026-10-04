//! 应用入口：强制深色模式，注入全局状态，底部导航三 Tab

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quic/flutter_quic.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'models/app_mode.dart';
import 'providers/app_provider.dart';
import 'providers/receive_provider.dart';
import 'providers/transfer_provider.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/receive_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/startup_screen.dart';
import 'theme/tokens.dart';
import 'widgets/device_list_sidebar.dart';

/// 全局导航键：供无 BuildContext 的服务（如 ZeroTier 引导弹窗）使用
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    // 初始化 flutter_quic 的 Rust 桥接
    await RustLib.init();
    // 强制竖屏
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    runApp(const QuiXApp());
  } catch (e, st) {
    // 启动阶段异常写入应用支持目录，便于排查窗口不显示问题
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}startup_error.log');
      f.writeAsStringSync('$e\n\n$st\n');
    } catch (_) {}
    rethrow;
  }
}

/// QuiX 根组件
class QuiXApp extends StatelessWidget {
  const QuiXApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TransferProvider()),
        ChangeNotifierProvider(create: (_) => ReceiveProvider()),
        ChangeNotifierProvider(create: (_) => AppProvider()..load()),
      ],
      child: MaterialApp(
        navigatorKey: rootNavigatorKey,
        title: 'QuiX',
        debugShowCheckedModeBanner: false,
        // 强制深色模式，不跟随系统
        theme: buildDarkTheme(),
        home: const RootScreen(),
      ),
    );
  }
}

/// 根路由：未选择模式时显示启动页，否则进入主壳
class RootScreen extends StatelessWidget {
  const RootScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppProvider>();
    if (!app.loaded) {
      return const Scaffold(
        backgroundColor: QxColors.bg,
        body: Center(child: CircularProgressIndicator(color: QxColors.primary)),
      );
    }
    if (!app.chosen) {
      return const StartupScreen();
    }
    return const MainShell();
  }
}

/// 主壳：底部导航（首页 / 传输 / 设置）
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // 首帧后加载历史记录与传输设置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TransferProvider>().loadHistory();
      context.read<TransferProvider>().loadTransferSettings();
      context.read<TransferProvider>().loadTrustedDevices();
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppProvider>();
    // 接收模式：服务端 UI
    if (app.mode == AppMode.receive) {
      return const ReceiveScreen();
    }

    // 桌面端（宽屏）使用左侧设备列表 + 右侧内容的布局
    final isDesktop = MediaQuery.of(context).size.width >= 900;
    if (isDesktop) {
      return Scaffold(
        backgroundColor: QxColors.bg,
        body: Row(
          children: [
            DeviceListSidebar(
              selectedIndex: _index,
              onSelect: (i) => setState(() => _index = i),
            ),
            const VerticalDivider(width: 1, color: QxColors.border),
            Expanded(
              child: IndexedStack(
                index: _index,
                children: const [
                  HomeScreen(),
                  HistoryScreen(),
                  SettingsScreen(),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          HomeScreen(),
          HistoryScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: QxColors.surface,
        indicatorColor: QxColors.primary.withOpacity(0.3),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.swap_vert),
            label: '传输',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

/// 构建深色主题（深灰背景 + 品牌渐变强调）
ThemeData buildDarkTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: QxColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: QxColors.primary,
      secondary: QxColors.primaryEnd,
      tertiary: QxColors.primaryEnd,
      surface: QxColors.surface,
      onSurface: QxColors.textPrimary,
      error: QxColors.danger,
      onError: Colors.white,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: QxColors.textPrimary,
      ),
      iconTheme: IconThemeData(color: QxColors.textPrimary),
    ),
    dividerTheme: const DividerThemeData(
      color: QxColors.border,
      thickness: 1,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: QxColors.primary,
        foregroundColor: QxColors.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(QxRadius.button)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: QxColors.surface2,
      contentTextStyle: const TextStyle(color: QxColors.textPrimary, fontSize: 14),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(QxRadius.button)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: QxColors.surface,
      indicatorColor: QxColors.primary.withOpacity(0.3),
    ),
  );
}
