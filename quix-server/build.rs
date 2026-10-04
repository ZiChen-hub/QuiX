//! 构建脚本：
//! - Windows：用 CMake 编译内嵌 ZeroTier 核心静态库（native/CMakeLists.txt），
//!   链接进本 cdylib；并将 wintun.dll 复制到 cargo 输出目录与 Flutter runner bundle。
//! - 其他平台：空操作（Android 走 JNI + VpnService，桌面非 Windows 走外部 CLI）。

#[cfg(windows)]
fn main() {
    use std::path::PathBuf;

    // 运行时判断真实目标平台：build script 总按 host（Windows）编译运行，
    // 交叉编译到 Android 时必须跳过 Windows 原生构建
    let target = std::env::var("TARGET").unwrap_or_default();
    if !target.contains("windows") {
        return;
    }

    // 探测 cmake 可执行文件（PATH 之外补充 Android SDK 自带 CMake）
    if std::env::var_os("CMAKE").is_none() {
        let candidates = [
            r"D:\DevTools\android-sdk\cmake\3.22.1\bin\cmake.exe",
            r"C:\Program Files\CMake\bin\cmake.exe",
        ];
        for c in candidates {
            if PathBuf::from(c).exists() {
                std::env::set_var("CMAKE", c);
                break;
            }
        }
    }

    // 仅在 native 相关文件变化时重新构建
    println!("cargo:rerun-if-changed=native/CMakeLists.txt");
    println!("cargo:rerun-if-changed=native/wintun/x64/wintun.dll");

    // 1. 编译 ZeroTier 核心静态库
    // 始终用 Release 配置（/MD release CRT，与 Rust MSVC target 对齐；
    // 避免 Debug 配置的 /MDd 造成 _CrtDbgReport 等 debug CRT 符号不匹配）
    let dst = cmake::Config::new("native")
        .profile("Release")
        .build_target("quix_ztcore")
        .define("CMAKE_GENERATOR_PLATFORM", "x64")
        .build();

    // cmake crate 已输出 profile 对应的 link-search，这里补充 VS 生成器产物路径
    println!(
        "cargo:rustc-link-search=native={}/build/Release",
        dst.display()
    );
    println!("cargo:rustc-link-lib=static=quix_ztcore");

    // 2. 复制 wintun.dll 到运行目录
    let dll_src = PathBuf::from("native/wintun/x64/wintun.dll");
    if !dll_src.exists() {
        panic!("未找到内嵌的 wintun.dll: {}", dll_src.display());
    }

    // 2a. cargo profile 输出目录（OUT_DIR = target/<profile>/build/<pkg-hash>/out，
    //    上溯三级即 target/<profile>）
    if let Ok(out_dir) = std::env::var("OUT_DIR") {
        let p = PathBuf::from(out_dir);
        if let Some(profile_dir) = p.join("../../../..").canonicalize().ok() {
            copy_dll(&dll_src, &profile_dir.join("wintun.dll"));
        }
    }

    // 2b. Flutter Windows runner bundle 目录
    //     quix-client/build/windows/x64/runner/{Debug|Release}/
    let profile = std::env::var("PROFILE").unwrap_or_else(|_| "debug".to_string());
    let bundle_profile = if profile == "release" { "Release" } else { "Debug" };
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let bundle_dir = manifest_dir
        .join("../quix-client/build/windows/x64/runner")
        .join(bundle_profile);
    if bundle_dir.exists() {
        copy_dll(&dll_src, &bundle_dir.join("wintun.dll"));
    } else {
        println!(
            "cargo:warning=Flutter runner bundle 目录尚不存在，跳过 wintun.dll 复制: {}",
            bundle_dir.display()
        );
    }
}

#[cfg(windows)]
fn copy_dll(src: &std::path::Path, dst: &std::path::Path) {
    if let Err(e) = std::fs::copy(src, dst) {
        println!("cargo:warning=复制 wintun.dll 到 {} 失败: {e}", dst.display());
    }
}

#[cfg(not(windows))]
fn main() {
    // 非 Windows 平台无需原生构建
}
