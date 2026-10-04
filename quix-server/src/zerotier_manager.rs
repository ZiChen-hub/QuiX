//! ZeroTier 跨网络自动组网管理
//! 说明：CLI 调用遵循开发案「std::process」，安装地址与 Central API 以 ZeroTier 官方为准。

use anyhow::{bail, Context, Result};
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

/// ZeroTier 发布版本（安装时需按当前发布调整）
const ZEROTIER_VERSION: &str = "1.14.0";
/// ZeroTier 下载基地址
const ZEROTIER_BASE: &str = "https://download.zerotier.com/RELEASES";
/// Windows MSI（OLE 复合文档）magic bytes
const MSI_MAGIC: &[u8] = &[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
/// macOS PKG（xar 归档）magic bytes
const PKG_MAGIC: &[u8] = b"xar!";

/// ZeroTier 组网管理器（无状态，仅封装 zerotier-cli 命令调用）
pub struct ZeroTierManager;

impl ZeroTierManager {
    /// 创建管理器实例
    pub fn new() -> Self {
        Self
    }

    /// 检测 zerotier-cli 是否已安装（检查各平台常见路径）
    pub fn is_installed(&self) -> bool {
        let candidates = [
            PathBuf::from(r"C:\Program Files\ZeroTier\One\zerotier-cli.bat"),
            PathBuf::from(r"C:\Program Files\ZeroTier\One\zerotier-cli.exe"),
            PathBuf::from(r"C:\Program Files (x86)\ZeroTier\One\zerotier-cli.exe"),
            PathBuf::from("/usr/local/bin/zerotier-cli"),
            PathBuf::from("/usr/bin/zerotier-cli"),
        ];
        if candidates.iter().any(|p| p.exists()) {
            return true;
        }
        // 回退：尝试 which / where
        Command::new("which")
            .arg("zerotier-cli")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
            || Command::new("where")
                .arg("zerotier-cli")
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false)
    }

    /// 自动下载安装 ZeroTier（按平台分发，需要管理员权限）
    pub async fn install(&self) -> Result<()> {
        tracing::info!("正在安装 ZeroTier（平台: {}）", std::env::consts::OS);
        match std::env::consts::OS {
            "windows" => self.install_windows().await,
            "macos" => self.install_macos().await,
            "linux" => self.install_linux().await,
            other => bail!("不支持的操作系统: {}", other),
        }
    }

    async fn install_windows(&self) -> Result<()> {
        let url = format!("{}/{}/dist/ZeroTierOne.msi", ZEROTIER_BASE, ZEROTIER_VERSION);
        let tmp = std::env::temp_dir().join("zerotier-one.msi");
        download_file(&url, &tmp, MSI_MAGIC).await?;
        let status = Command::new("msiexec")
            .args(["/i", tmp.to_str().unwrap_or(""), "/quiet", "/norestart"])
            .status()
            .context("执行 msiexec 安装失败")?;
        if !status.success() {
            bail!("ZeroTier 安装失败（请以管理员身份运行）");
        }
        Ok(())
    }

    async fn install_macos(&self) -> Result<()> {
        let url = format!("{}/{}/dist/ZeroTierOne.pkg", ZEROTIER_BASE, ZEROTIER_VERSION);
        let tmp = std::env::temp_dir().join("zerotier-one.pkg");
        download_file(&url, &tmp, PKG_MAGIC).await?;
        let status = Command::new("installer")
            .args(["-pkg", tmp.to_str().unwrap_or(""), "-target", "/"])
            .status()
            .context("执行 installer 安装失败")?;
        if !status.success() {
            bail!("ZeroTier 安装失败");
        }
        Ok(())
    }

    async fn install_linux(&self) -> Result<()> {
        // 官方安装脚本：curl -s https://install.zerotier.com | sudo bash
        let status = Command::new("sh")
            .arg("-c")
            .arg("curl -s https://install.zerotier.com | sudo bash")
            .status()
            .context("执行 ZeroTier 安装脚本失败")?;
        if !status.success() {
            bail!("ZeroTier 安装失败");
        }
        Ok(())
    }

    /// 加入指定网络
    pub async fn join_network(&self, network_id: &str) -> Result<()> {
        let output = Command::new("zerotier-cli")
            .args(["join", network_id])
            .output()
            .context("执行 zerotier-cli join 失败")?;
        if !output.status.success() {
            bail!("join 失败: {}", String::from_utf8_lossy(&output.stderr));
        }
        Ok(())
    }

    /// 获取分配的虚拟 IP（解析 listnetworks 输出）
    pub async fn get_assigned_ip(&self, network_id: &str) -> Result<String> {
        let output = Command::new("zerotier-cli")
            .arg("listnetworks")
            .output()
            .context("执行 zerotier-cli listnetworks 失败")?;
        let text = String::from_utf8_lossy(&output.stdout);
        // 输出形如: 200 listnetworks <nwid> <name> <mac> <status> <type> <dev> <ips>
        for line in text.lines() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 9 && parts[2] == network_id {
                let ips = parts[8]; // 如 "10.147.17.1/24"
                if let Some(ip) = ips.split('/').next() {
                    if !ip.is_empty() {
                        return Ok(ip.to_string());
                    }
                }
            }
        }
        bail!("未获取到分配的 IP")
    }

    /// 加入网络并轮询等待分配 IP
    pub async fn join_and_get_ip(&self, network_id: &str, timeout: Duration) -> Result<String> {
        self.join_network(network_id).await?;
        let deadline = std::time::Instant::now() + timeout;
        while std::time::Instant::now() < deadline {
            if let Ok(ip) = self.get_assigned_ip(network_id).await {
                return Ok(ip);
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        bail!("等待 ZeroTier 分配 IP 超时")
    }
}

/// 下载文件到本地（reqwest，HTTPS 保证传输层完整性）
/// [magic] 为安装包格式的 magic bytes，用于校验下载内容（纵深防御，防止下载到错误内容）
async fn download_file(url: &str, path: &std::path::Path, magic: &[u8]) -> Result<()> {
    let bytes = reqwest::get(url)
        .await
        .context("下载失败")?
        .error_for_status()
        .context("下载返回错误状态")?
        .bytes()
        .await
        .context("读取下载内容失败")?;
    if bytes.len() < magic.len() || &bytes[..magic.len()] != magic {
        bail!("下载内容校验失败（非预期的安装包格式）");
    }
    tokio::fs::write(path, &bytes).await.context("写入临时文件失败")?;
    Ok(())
}
