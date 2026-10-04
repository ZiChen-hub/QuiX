//! 服务端配置结构体与读取逻辑

use anyhow::{Context, Result};
use serde::Deserialize;
use std::path::Path;

/// QuiX 服务端配置（与 config.toml 一一对应）
#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// 监听端口
    pub port: u16,
    /// 文件接收目录
    #[serde(default = "default_output_dir")]
    pub output_dir: String,
    /// 最大并发流数
    #[serde(default = "default_max_concurrent_streams")]
    pub max_concurrent_streams: usize,
    /// 每块大小（字节）
    #[serde(default = "default_chunk_size")]
    pub chunk_size: u64,
    /// 是否启用 mDNS 设备发现
    #[serde(default = "default_true")]
    pub enable_mdns: bool,
    /// 是否启用跨网络传输
    #[serde(default)]
    pub enable_cross_network: bool,
    /// ZeroTier 网络 ID
    #[serde(default)]
    pub zerotier_network_id: String,
    /// ZeroTier Central API Token
    #[serde(default)]
    pub zerotier_api_token: String,
    /// 连接超时（秒）
    #[serde(default = "default_connection_timeout")]
    pub connection_timeout: u64,
    /// 自定义连接码（可选；为 None 时启动时自动生成）
    #[serde(default)]
    pub code: Option<String>,
}

fn default_output_dir() -> String {
    "./received".to_string()
}

fn default_max_concurrent_streams() -> usize {
    8
}

fn default_chunk_size() -> u64 {
    4 * 1024 * 1024
}

fn default_true() -> bool {
    true
}

fn default_connection_timeout() -> u64 {
    30
}

impl Config {
    /// 从指定路径加载并解析配置文件
    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let content = std::fs::read_to_string(path.as_ref())
            .with_context(|| format!("读取配置文件失败: {}", path.as_ref().display()))?;
        let config: Config = toml::from_str(&content).context("解析配置文件失败")?;
        Ok(config)
    }
}
