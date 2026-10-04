//! 文件操作：预分配、随机写入、BLAKE3 校验

use anyhow::{Context, Result};
use std::path::Path;
use tokio::io::AsyncReadExt;

/// 创建并预分配文件大小（set_len），返回可随机写入的文件句柄
pub async fn create_and_preallocate(path: &Path, size: u64) -> Result<tokio::fs::File> {
    let file = tokio::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(path)
        .await
        .context("创建文件失败")?;
    file.set_len(size).await.context("预分配文件大小失败")?;
    Ok(file)
}

/// 计算文件 BLAKE3 哈希（流式计算，避免大文件整体读入内存）
pub async fn hash_file(path: &Path) -> Result<String> {
    let mut file = tokio::fs::File::open(path).await.context("打开文件失败")?;
    let mut hasher = blake3::Hasher::new();
    let mut buf = vec![0u8; 64 * 1024]; // 64KB 缓冲
    loop {
        let n = file.read(&mut buf).await.context("读取文件失败")?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().to_hex().to_string())
}

/// 校验文件 BLAKE3 哈希是否与预期一致
pub async fn verify_hash(path: &Path, expected: &str) -> Result<bool> {
    let actual = hash_file(path).await?;
    Ok(actual == expected)
}
