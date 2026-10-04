# QuiX embedded ZeroTier core — Windows (MSVC) static library.
# 核心源码位于 ../../quix-client/third_party/ZeroTierOne（BSL 1.1）。
# 本文件不改动子模块工作树，仅以 MSVC 编译核心为静态库，
# 由 quix-server 的 build.rs 调用 cmake crate 构建并链接进 quix_core.dll。
cmake_minimum_required(VERSION 3.15)
project(quix_ztcore LANGUAGES CXX)

set(ZT_CORE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../quix-client/third_party/ZeroTierOne)

file(GLOB zt_core_src ${ZT_CORE_DIR}/node/*.cpp)

add_library(quix_ztcore STATIC
    ${zt_core_src}
    ${ZT_CORE_DIR}/osdep/OSUtils.cpp
)

target_include_directories(quix_ztcore PRIVATE
    ${ZT_CORE_DIR}/include
    ${ZT_CORE_DIR}/node
    ${ZT_CORE_DIR}/ext
    ${ZT_CORE_DIR}/ext/prometheus-cpp-lite-1.0/core/include
    ${ZT_CORE_DIR}/ext/prometheus-cpp-lite-1.0/simpleapi/include
)

# 与 Rust MSVC target 对齐：始终使用动态 release CRT（/MD），
# 避免与 Rust 自身的 CRT 选择混用造成双份 CRT；不使用官方独立 exe 的 /MT。
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

# /EHsc C++ 异常，/utf-8 源码字符集，/MP 并行；警告级别 /W1 先抑制上游噪声
target_compile_options(quix_ztcore PRIVATE /EHsc /utf-8 /MP /W1)

# MSVC 必需定义（对照官方根 CMakeLists 的 Windows 分支）：
# - ZT_SALSA20_SSE：MSVC 无法编译 GNU .s 加密汇编，SSE 内联路径替代
# - NOMINMAX / _CRT_SECURE_NO_WARNINGS / FD_SETSIZE：Windows 头兼容
# - STATICLIB / ZT_EXPORT：走核心内建分支，抑制头文件自动链接预建 SDK 库
# - ZT_BUILD_PLATFORM/ARCHITECTURE：版本上报（Windows x64 = 2/2）
# - ZT_SOFTWARE_UPDATE_DEFAULT：禁用自更新（嵌入库不应触发升级逻辑）
target_compile_definitions(quix_ztcore PRIVATE
    WIN32
    ZT_SALSA20_SSE
    NOMINMAX
    FD_SETSIZE=1024
    _CRT_SECURE_NO_WARNINGS
    STATICLIB
    ZT_EXPORT
    ZT_BUILD_PLATFORM=2
    ZT_BUILD_ARCHITECTURE=2
    ZT_SOFTWARE_UPDATE_DEFAULT=disable
)

# Windows 系统库（对照官方 vcxproj / 根 CMakeLists L643-647）
target_link_libraries(quix_ztcore PUBLIC
    ws2_32 wsock32 Iphlpapi Rpcrt4 bcrypt crypt32 ncrypt ntdll secur32 userenv wbemuuid
)

# cmake crate 默认构建 install target，提供安装规则（静态库 → lib/）
install(TARGETS quix_ztcore ARCHIVE DESTINATION lib)
