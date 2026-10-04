//! W3 数据面验证：cargo run --example zt_join -- <16位网络ID> [对端IP]
//! 流程：join → 授权 → 建立 Wintun TUN → （可选）ping 对端验证双向互通。
//! 注意：需要管理员权限运行（创建 Wintun 适配器 + netsh 配置 IP）。

use std::time::Duration;

use quix_core::ztembed;

fn main() {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::INFO)
        .init();

    let mut args = std::env::args().skip(1);
    let nwid = args.next().expect("用法: zt_join <16位网络ID> [对端IP]");
    let peer = args.next();

    println!("正在加入 ZeroTier 网络 {nwid} ...");
    match ztembed::join(&nwid, Duration::from_secs(180)) {
        Ok(r) => {
            println!(
                "成功！分配 IP: {}，节点地址: {:010x}，TUN 数据面已建立",
                r.ip, r.node_address
            );
        }
        Err(e) => {
            eprintln!("失败: {e:#}");
            eprintln!("提示：创建 Wintun 适配器需要管理员权限运行终端。");
            std::process::exit(1);
        }
    }

    // 可选：ping 对端验证数据面（如手机端 ZeroTier IP 10.182.18.149）
    if let Some(peer) = peer {
        println!("\n正在 ping 对端 {peer}（4 次）...");
        let out = std::process::Command::new("ping")
            .args([peer.as_str(), "-n", "4", "-w", "2000"])
            .status();
        match out {
            Ok(s) if s.success() => println!("ping 互通验证通过！"),
            Ok(_) => {
                eprintln!("ping 失败：请确认对端设备已在线并已授权，首次 ARP 可能丢包可重试");
                std::process::exit(1);
            }
            Err(e) => eprintln!("无法启动 ping: {e}"),
        }
    } else {
        println!("\nTUN 就绪。可从对端 ping 本机，或带第二参数重跑自动 ping 测试。");
        println!("按 Ctrl+C 退出（会清理 TUN 适配器）。");
        loop {
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    ztembed::leave();
    println!("已清理退出。");
}
