//! QuiX 服务端 CLI 入口（用于命令行测试；统一程序版通过 FFI 调用动态库）

use anyhow::Result;
use clap::Parser;
use quix_core::{config, network, qr_gen, server, utils};
use tracing::info;

/// 命令行参数定义
#[derive(Parser, Debug)]
#[command(name = "quix-server", version, about = "QuiX 极速文件传输服务端")]
struct Cli {
    /// 配置文件路径
    #[arg(short, long, default_value = "config.toml")]
    config: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    // 初始化日志（生产环境可通过环境变量 RUST_LOG 控制）
    tracing_subscriber::fmt::init();

    let cli = Cli::parse();
    let config = config::Config::load(&cli.config)?;

    info!("QuiX 服务端启动，监听端口 {}", config.port);

    // 生成 6 位连接码（用于二维码展示与连接校验）
    let connection_code = utils::generate_connection_code();

    // 确定可达地址：启用跨网络时按 IPv6 → UPnP → ZeroTier 顺序组网，否则用局域网 IP
    let reachable_ip = if config.enable_cross_network {
        match network::establish_cross_network(config.port, &config.zerotier_network_id).await {
            Ok(Some(ip)) => ip,
            Ok(None) => utils::get_local_ip().unwrap_or_else(|| "127.0.0.1".to_string()),
            Err(e) => {
                tracing::warn!("跨网络组网失败: {:#}", e);
                utils::get_local_ip().unwrap_or_else(|| "127.0.0.1".to_string())
            }
        }
    } else {
        utils::get_local_ip().unwrap_or_else(|| "127.0.0.1".to_string())
    };

    // 打印连接二维码（含连接码），方便手机扫码
    let qr = qr_gen::generate_qr_ascii(&config, &connection_code, &reachable_ip)?;
    println!("{}", qr);
    // 机器可读的连接码输出（供参考客户端等自动化测试解析）
    println!("code={}", connection_code);
    info!("连接码: {}", connection_code);

    // 启动服务端（后台运行接受循环）
    let handle = server::ServerHandle::start(config, connection_code.clone(), reachable_ip).await?;

    // 命令行循环：`quit` 退出
    use tokio::io::AsyncBufReadExt;
    let mut lines = tokio::io::BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim();
        if line == "quit" || line == "exit" {
            break;
        }
    }

    handle.stop();
    Ok(())
}
