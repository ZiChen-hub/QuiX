# QuiX embedded ZeroTier core — Android NDK build.
# 核心源码位于 ../../../../third_party/ZeroTierOne（BSL 1.1），
# 本文件不改动子模块工作树，仅以 NDK 工具链编译核心 + JNI 桥接层。
cmake_minimum_required(VERSION 3.22.1)
project(ZeroTierOneJNI LANGUAGES CXX)

set(ZT_CORE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/ZeroTierOne)

file(GLOB zt_core_src ${ZT_CORE_DIR}/node/*.cpp)

set(zt_src_files
    ${ZT_CORE_DIR}/osdep/OSUtils.cpp
    ${ZT_CORE_DIR}/java/jni/com_zerotierone_sdk_Node.cpp
    ${ZT_CORE_DIR}/java/jni/ZT_jniutils.cpp
    ${ZT_CORE_DIR}/java/jni/ZT_jnicache.cpp
)

add_library(ZeroTierOneJNI SHARED ${zt_src_files} ${zt_core_src})

target_include_directories(ZeroTierOneJNI PRIVATE
    ${ZT_CORE_DIR}/include
    ${ZT_CORE_DIR}/node
    ${ZT_CORE_DIR}/ext
    ${ZT_CORE_DIR}/ext/prometheus-cpp-lite-1.0/core/include
    ${ZT_CORE_DIR}/ext/prometheus-cpp-lite-1.0/simpleapi/include
)

# 关闭部分上游在新 NDK 下的噪声警告（沿用 ZerotierFix-Build 修正思路）
target_compile_options(ZeroTierOneJNI PRIVATE
    -Wno-unused-command-line-argument
    -Wno-unused-parameter
)

find_library(zt_log log)
target_link_libraries(ZeroTierOneJNI ${zt_log})
