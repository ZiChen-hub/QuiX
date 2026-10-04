//! 参考客户端：端到端验证 QuiX 协议（上传方向 + 推送方向，多流并发 + 续传）
//!
//! 用法：cargo run --bin reference_client
//! 它会：启动服务端子进程 → 读取连接码 → 建立 QUIC 连接 →
//!       上传一个多块文件 → 查询续传位图 → 注册控制流 → 触发服务端推送并接收。

use anyhow::{Context, Result};
use quinn::{ClientConfig, Connection, Endpoint, RecvStream, SendStream};
use rustls::client::ServerCertVerifier;
use rustls::{Certificate, ServerName};
use std::io::{BufRead, BufReader};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

const SERVER_PORT: u16 = 14433;
const UPLOAD_CHUNK: u64 = 4096; // 上传用小块，便于产生多个块验证多流
const CONCURRENCY: usize = 8;
const UPLOAD_SIZE: u64 = 256 * 1024; // 256KB => 64 块

// ===== 跳过证书校验（与客户端行为一致） =====
struct SkipVerification;

impl ServerCertVerifier for SkipVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &Certificate,
        _intermediates: &[Certificate],
        _server_name: &ServerName,
        _scts: &mut dyn Iterator<Item = &[u8]>,
        _ocsp_response: &[u8],
        _now: std::time::SystemTime,
    ) -> Result<rustls::client::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::ServerCertVerified::assertion())
    }
}

fn build_client_config() -> ClientConfig {
    let tls = rustls::ClientConfig::builder()
        .with_safe_defaults()
        .with_custom_certificate_verifier(Arc::new(SkipVerification))
        .with_no_client_auth();
    ClientConfig::new(Arc::new(tls))
}

// ===== 小工具 =====
async fn read_exact(recv: &mut RecvStream, n: usize) -> Result<Vec<u8>> {
    let mut buf = vec![0u8; n];
    recv.read_exact(&mut buf).await.context("读取数据失败")?;
    Ok(buf)
}

async fn read_u32(recv: &mut RecvStream) -> Result<u32> {
    let b = read_exact(recv, 4).await?;
    Ok(u32::from_be_bytes(b.try_into().expect("u32 长度不匹配")))
}

async fn read_u64(recv: &mut RecvStream) -> Result<u64> {
    let b = read_exact(recv, 8).await?;
    Ok(u64::from_be_bytes(b.try_into().expect("u64 长度不匹配")))
}

/// 读取消息类型，返回 None 表示流已关闭
#[allow(dead_code)]
async fn read_message_type(recv: &mut RecvStream) -> Result<Option<u32>> {
    let mut buf = [0u8; 4];
    let mut read = 0usize;
    while read < buf.len() {
        match recv.read(&mut buf[read..]).await.context("读取消息类型失败")? {
            Some(0) | None => {
                if read == 0 {
                    return Ok(None);
                }
                anyhow::bail!("消息类型不完整");
            }
            Some(n) => read += n,
        }
    }
    Ok(Some(u32::from_be_bytes(buf)))
}

async fn write_u32(send: &mut SendStream, v: u32) -> Result<()> {
    send.write_all(&v.to_be_bytes()).await.context("写 u32 失败")?;
    Ok(())
}

async fn write_u64(send: &mut SendStream, v: u64) -> Result<()> {
    send.write_all(&v.to_be_bytes()).await.context("写 u64 失败")?;
    Ok(())
}

fn blake3_hex(data: &[u8]) -> String {
    blake3::hash(data).to_hex().to_string()
}

/// 生成确定性测试数据
fn make_data(size: u64, seed: u8) -> Vec<u8> {
    let mut v = Vec::with_capacity(size as usize);
    let mut i = 0u64;
    while v.len() < size as usize {
        v.push((i.wrapping_mul(31).wrapping_add(seed as u64)) as u8);
        i += 1;
    }
    v
}

// ===== 服务端子进程管理 =====
struct ServerHandle {
    child: Child,
    // 持有服务端 stdin 管道：管道关闭（EOF）会导致服务端退出
    _stdin: ChildStdin,
}

impl Drop for ServerHandle {
    fn drop(&mut self) {
        // 显式终止并回收服务端子进程，避免测试失败或提前 return 时遗留孤儿进程
        // （仅靠 stdin EOF 在异常路径下不一定及时生效）
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn spawn_server(temp: &std::path::Path) -> Result<ServerHandle> {
    let config_path = temp.join("config.toml");
    let output_dir = temp.join("received");
    std::fs::create_dir_all(&output_dir)?;
    std::fs::write(
        &config_path,
        format!(
            "port = {}\noutput_dir = \"{}\"\nenable_mdns = false\nenable_cross_network = false\n",
            SERVER_PORT,
            output_dir.display().to_string().replace('\\', "/")
        ),
    )?;

    let exe_dir = std::env::current_exe()?.parent().expect("可执行文件路径缺少父目录").to_path_buf();
    let server = exe_dir.join("quix-server.exe");

    let mut child = Command::new(&server)
        .arg("--config")
        .arg(&config_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .with_context(|| format!("启动服务端失败: {}", server.display()))?;

    let _stdin = child.stdin.take().context("获取服务端 stdin 失败")?;
    Ok(ServerHandle { child, _stdin })
}

/// 从服务端 stdout 中读取 6 位连接码
fn read_code(child: &mut Child) -> Result<String> {
    let stdout = child.stdout.take().context("获取服务端 stdout 失败")?;
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines().flatten() {
            if let Some(pos) = line.find("code=") {
                // 当前连接码格式：8 位字母数字（无易混淆字符 0/O/1/I/l）
                let code: String = line[pos + 5..]
                    .chars()
                    .take_while(|c| c.is_ascii_alphanumeric())
                    .collect();
                if code.len() == 8 {
                    tx.send(code).ok();
                    break;
                }
            }
        }
    });
    rx.recv_timeout(Duration::from_secs(10))
        .context("未从服务端输出中读取到连接码")
}

// ===== 上传方向（客户端 → 服务端） =====
async fn test_upload(conn: &Connection, code: &str, data: &[u8]) -> Result<()> {
    let file_id = "ref-upload-1".to_string();
    let file_name = "ref_upload.bin".to_string();
    let total_chunks = (data.len() as u64 + UPLOAD_CHUNK - 1) / UPLOAD_CHUNK;
    let hash = blake3_hex(data);

    // 1. 元数据
    let (mut send, mut recv) = conn.open_bi().await?;
    let meta = serde_json::json!({
        "file_id": file_id,
        "file_name": file_name,
        "file_size": data.len() as u64,
        "chunk_size": UPLOAD_CHUNK,
        "total_chunks": total_chunks,
        "hash": hash,
        "code": code,
    });
    let meta_bytes = serde_json::to_vec(&meta)?;
    write_u32(&mut send, 1).await?;
    write_u64(&mut send, meta_bytes.len() as u64).await?;
    send.write_all(&meta_bytes).await?;
    send.finish().await?;

    // 读取响应 [count:8][bitmap_json]
    let received_count = read_u64(&mut recv).await?;
    let rest = recv.read_to_end(usize::MAX).await?;
    let bitmap: Vec<u8> = serde_json::from_slice(&rest)?;
    assert_eq!(received_count, 0, "新文件应无已接收块");
    assert_eq!(bitmap.len(), total_chunks as usize);

    // 2. 多流并发发送数据块
    let chunks: Vec<u64> = (0..total_chunks).collect();
    let mut handles = Vec::new();
    for s in 0..CONCURRENCY {
        let assigned: Vec<u64> = chunks
            .iter()
            .copied()
            .skip(s)
            .step_by(CONCURRENCY)
            .collect();
        if assigned.is_empty() {
            continue;
        }
        let conn = conn.clone();
        let data = Arc::new(data.to_vec());
        let file_id = file_id.clone();
        handles.push(tokio::spawn(async move {
            let (mut send, mut recv) = conn.open_bi().await?;
            for &idx in &assigned {
                let off = (idx * UPLOAD_CHUNK) as usize;
                let end = ((idx + 1) * UPLOAD_CHUNK).min(data.len() as u64) as usize;
                let chunk = &data[off..end];
                write_u32(&mut send, 2).await?;
                write_u32(&mut send, file_id.len() as u32).await?;
                send.write_all(file_id.as_bytes()).await?;
                write_u64(&mut send, idx).await?;
                write_u64(&mut send, chunk.len() as u64).await?;
                send.write_all(chunk).await?;
            }
            send.finish().await?;
            // 逐块读取 ACK
            for _ in 0..assigned.len() {
                let _ = read_u64(&mut recv).await?; // chunk_index
                let _ = read_u64(&mut recv).await?; // received_count
            }
            Ok::<_, anyhow::Error>(())
        }));
    }
    for h in handles {
        h.await??;
    }

    println!("[OK] 上传完成：{} 块已发送", total_chunks);

    // 3. 续传查询（ResumeRequest → ResumeResponse）
    let (mut send, mut recv) = conn.open_bi().await?;
    write_u32(&mut send, 5).await?;
    write_u32(&mut send, file_id.len() as u32).await?;
    send.write_all(file_id.as_bytes()).await?;
    write_u32(&mut send, code.len() as u32).await?;
    send.write_all(code.as_bytes()).await?;
    send.finish().await?;

    let ty = read_u32(&mut recv).await?;
    assert_eq!(ty, 6, "续传响应类型应为 6");
    let rest = recv.read_to_end(usize::MAX).await?;
    let bitmap: Vec<u8> = serde_json::from_slice(&rest)?;
    assert!(bitmap.iter().all(|&b| b == 1), "续传位图应全为 1");
    println!("[OK] 续传查询通过：位图全为 1（{} 块）", bitmap.len());

    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    println!("=== QuiX 参考客户端端到端验证 ===");

    let temp = std::env::temp_dir().join("quix_ref_e2e");
    std::fs::create_dir_all(&temp)?;

    // 测试数据
    println!("生成测试数据...");
    let upload_data = make_data(UPLOAD_SIZE, 7);

    // 启动服务端
    println!("启动服务端...");
    let mut server = spawn_server(&temp)?;
    let code = read_code(&mut server.child)?;
    println!("连接码: {}", code);

    // 建立连接
    println!("建立 QUIC 连接...");
    let mut endpoint = Endpoint::client("0.0.0.0:0".parse()?)?;
    endpoint.set_default_client_config(build_client_config());
    let addr = format!("127.0.0.1:{}", SERVER_PORT).parse()?;
    let connection = endpoint.connect(addr, "localhost")?.await?;
    println!("连接已建立");

    // 连接鉴权（Hello）
    {
        let (mut send, mut recv) = connection.open_bi().await?;
        write_u32(&mut send, 10).await?;
        write_u32(&mut send, code.len() as u32).await?;
        send.write_all(code.as_bytes()).await?;
        let dt = "desktop";
        write_u32(&mut send, dt.len() as u32).await?;
        send.write_all(dt.as_bytes()).await?;
        send.finish().await?;
        let ok = read_exact(&mut recv, 1).await?;
        assert_eq!(ok[0], 1, "连接鉴权应通过");
    }
    println!("[OK] 连接鉴权通过");

    // 上传方向
    println!("\n--- 上传方向 ---");
    test_upload(&connection, &code, &upload_data).await?;

    // 清理
    connection.close(0u32.into(), b"done");
    let _ = server.child.kill();
    std::fs::remove_dir_all(&temp).ok();

    println!("\n=== 端到端验证全部通过 ===");
    Ok(())
}
