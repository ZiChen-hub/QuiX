# QuiX

基于 QUIC 协议的跨平台极速文件传输工具。多流并发分块传输、断点续传、BLAKE3 完整性校验，局域网零配置直连，跨网络（IPv6 / UPnP / ZeroTier）可靠传输。

## 特性

- **极速传输**：QUIC 多流并发 + 分块上传，并发流数与块大小可调（并发 2~24 流、块 1~16MB）
- **智能测速配置**：发送端连接后可一键实测链路速率，自动匹配最优「块大小 × 并发流数」组合（实际传输参数以发送端为准）
- **断点续传**：传输中断后自动只补传缺失块（位图记录，分块配置变更后自动失效以避免静默损坏）
- **完整性校验**：BLAKE3 逐文件校验，服务端回传校验结果
- **零配置直连**：同一局域网 mDNS 自动发现设备；接收端二维码 / `quix://` 链接扫码即连
- **跨网络传输**：IPv6 直连、UPnP 自动端口映射、ZeroTier 虚拟局域网（内嵌核心，无需安装官方客户端）
- **安全**：TLS（rustls）+ 自签名证书 TOFU 与握手期证书固定、连接码鉴权、信任设备
- **不止文件**：文件夹整体传输、文本消息互发
- **传输记录**：历史记录持久化 + 收发统计
- **断开同步**：任一方主动断开，对端立即收到通知并更新状态

## 产品定位

**一个程序，两种模式**：`我发送`（客户端）/ `我接收`（服务端），统一入口。

核心场景：手机 ↔ 电脑、电脑 ↔ 电脑。

## 架构

```
Flutter 客户端（统一程序，桌面 + 移动）
  ├── 发送模式：QUIC 客户端（vendored flutter_quic）
  └── 接收模式：调用 Rust 服务端动态库（dart:ffi）

Rust 服务端（quix_core 动态库）
  ├── quinn（QUIC）+ rustls（TOFU + 证书固定）
  ├── SessionManager（会话 + 断点续传位图）
  ├── 多流并发传输 / 文本消息 / 速率测试
  ├── UPnP 端口映射 / ZeroTier 内嵌管理
  └── mDNS 设备发现
```

- 服务端以 `cdylib`（`quix_core.dll` / `.so`）形式提供，通过 `dart:ffi` 调用。
- 状态管理使用 `provider`（`AppProvider` / `TransferProvider` / `ReceiveProvider`）。
- 传输参数（分块大小、并发流数）由**发送端**决定并通过文件元数据告知接收端，接收端仅按元数据写盘。

## 目录结构

```
QuiX/
├── quix-client/          # Flutter 统一程序（发送 + 接收）
│   ├── lib/              # screens / providers / services / models / widgets
│   ├── android/          # Android 平台配置（含 zerotiercore JNI 模块）
│   ├── windows/          # Windows 平台配置
│   ├── test/             # 协议与工具单元测试
│   └── third_party/      # vendored 插件（含本地修复，见下文）
├── quix-server/          # Rust 服务端核心（cdylib + CLI）
│   ├── src/              # lib.rs(FFI) / server / session / stream_handler / ztembed / ...
│   ├── native/wintun/    # Wintun 虚拟网卡（Windows）
│   └── build.rs          # 编译 ZeroTier 核心静态库
├── build_windows.ps1     # Windows 一键构建脚本
├── quix_installer.iss    # Inno Setup 安装包脚本
├── LICENSE               # MIT 许可证
└── NOTICE                # 第三方组件与许可声明
```

## 构建

### 环境要求

- Flutter SDK 3.47.2 stable（Dart 3.13.2）
- Rust stable + `rustup target add aarch64-linux-android`
- Visual Studio 2022 Build Tools（「使用 C++ 的桌面开发」，含 CMake 与 MSVC 链接器）
- JDK 17、Android SDK（platforms;android-36 / build-tools;35.0.0 / ndk;28.2.13676358）
- Inno Setup 6（打包 Windows 安装包，可选）

### Windows

```powershell
.\build_windows.ps1            # Debug 构建
.\build_windows.ps1 -Release   # Release 构建
```

脚本依次执行：`cargo build` → `flutter build windows` → 拷贝 `quix_core.dll` 到运行目录。

Release 产物：`quix-client\build\windows\x64\runner\Release\quix_client.exe`

打包安装包：

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /DAppVersion=1.6.3 quix_installer.iss
```

产物：`dist\QuiX-Setup-1.6.3.exe`

### Android

```powershell
cd quix-client
flutter build apk --release    # arm64 release APK
```

产物：`quix-client\build\app\outputs\flutter-apk\app-release.apk`

## third_party 说明

以下插件因需要兼容性修复而 vendored 到仓库内（path 依赖）：

| 插件 | 修复内容 |
|---|---|
| `third_party/flutter_quic` | QUIC 客户端：修复运行时/空闲超时；cargokit 兼容 Gradle 9；仅编译 arm64 |
| `third_party/qr_code_scanner` | 修复 AGP 9 兼容性（namespace / JVM target 17） |
| `third_party/file_picker` | 修复 compileSdk 36 |
| `third_party/desktop_drop` | 修复 compileSdk 33 → 36 |

各插件保留其原始许可证。

## 服务端配置

Rust 服务端（「我接收」模式）支持配置文件，模板见 `quix-server/config.toml.example`：

监听端口、接收目录、mDNS 开关、跨网络开关、ZeroTier 网络配置等。将 `.example` 复制为 `config.toml` 后按需修改（`config.toml` 不入库）。

## 使用说明

### 我发送（客户端）

1. 启动后选择「我发送」。
2. 通过以下方式之一建立连接：
   - 「智能输入框」粘贴 `quix://IP:端口?code=连接码` 自动填充；
   - 手动填写 IP / 端口 / 连接码后点「连接」；
   - mDNS 自动发现局域网接收端，点设备名即连；
   - 移动端扫码自动填充。
3. 选择文件或文件夹 → 发送；连接后可点「智能测速配置传输参数」实测链路并自动匹配最优参数。
4. 传输中显示进度与实时速度；中断后重新连接可断点续传。

### 我接收（服务端）

1. 启动后选择「我接收」。
2. 页面显示 IP / 端口 / 连接码 / 二维码，供对端连接。
3. 有设备连入后可互发文本消息。
4. 底部展示接收统计与接收记录；首次连接的设备可标记为信任设备。
5. 跨网络传输：开启开关后输入 ZeroTier 网络 ID，组网成功后显示跨网络 IP。

### 模式切换

右上角「接收 / 发送」滑块切换。若存在活动连接，切换前会弹窗确认（切换将断开连接）。

## 协议概览

协议基于大端序，当前消息类型：

| 类型 | 名称 | 方向 | 用途 |
| :- | :- | :- | :- |
| 1 | Metadata | 客户端→服务端 | 文件元数据（文件名/大小/块信息/哈希） |
| 2 | ChunkData | 客户端→服务端 | 分块数据 |
| 5/6 | ResumeRequest / ResumeResponse | 双向 | 断点续传（缺失块位图） |
| 7 | Ack | 双向 | 数据块确认 |
| 8 | ControlChannel | 客户端→服务端 | 控制流注册（存活监测） |
| 10 | Hello | 客户端→服务端 | 连接鉴权（连接码 + 设备类型） |
| 11 | TextMessage | 双向 | 文本消息 |
| 12 | SpeedTest | 客户端→服务端 | 链路速率测试 |
| 13 | DisconnectNotify | 双向 | 断开通知 |
| 14 | VerifyResult | 服务端→客户端 | BLAKE3 完整性校验结果 |

## 测试

```powershell
cd quix-client
flutter test

cd quix-server
cargo test
```

单元测试覆盖协议编解码（`test/protocol_test.dart`）、连接地址解析/格式化（`test/quix_url_test.dart`）及 Rust 服务端会话/校验逻辑。

## 许可证

本项目代码基于 [MIT License](LICENSE) 开源。

项目内嵌/引用的第三方组件具有不同许可，详见 [NOTICE](NOTICE)：

- **ZeroTier 核心**：Business Source License 1.1（BSL 1.1，非商业使用）
- **ZerotierFix**（Android VpnService 适配层）：GPL-2.0
- **Wintun**：WireGuard LLC 预编译二进制许可
- 其余 Rust / Dart 依赖为 MIT / Apache-2.0 / BSD 等宽松许可
