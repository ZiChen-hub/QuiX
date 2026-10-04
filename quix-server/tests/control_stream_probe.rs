//! 断开连接同步端到端测试：
//! 1. 服务端主动断开（disconnect_all）→ 客户端控制流先收到 DisconnectNotify(13) 再断开
//! 2. 客户端主动断开（发送 DisconnectNotify(13)）→ 服务端连接计数同步下降

use quinn::{ClientConfig, Connection, Endpoint};
use quix_core::config::Config;
use quix_core::server::ServerHandle;
use rustls::{Certificate, PrivateKey};
use std::sync::Arc;
use tokio::io::AsyncReadExt;

const CODE: &str = "ABCD1234";

struct SkipVerify;

impl rustls::client::ServerCertVerifier for SkipVerify {
    fn verify_server_cert(
        &self,
        _end_entity: &Certificate,
        _intermediates: &[Certificate],
        _server_name: &rustls::ServerName,
        _scts: &mut dyn Iterator<Item = &[u8]>,
        _ocsp_response: &[u8],
        _now: std::time::SystemTime,
    ) -> Result<rustls::client::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::ServerCertVerified::assertion())
    }
}

async fn connect(port: u16) -> Connection {
    let mut transport = quinn::TransportConfig::default();
    transport.max_idle_timeout(None);
    let client_crypto = rustls::ClientConfig::builder()
        .with_safe_defaults()
        .with_custom_certificate_verifier(Arc::new(SkipVerify))
        .with_no_client_auth();
    let mut client_config = ClientConfig::new(Arc::new(client_crypto));
    client_config.transport_config(Arc::new(transport));
    let mut endpoint = Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
    endpoint.set_default_client_config(client_config);
    let conn = endpoint
        .connect(format!("127.0.0.1:{port}").parse().unwrap(), "localhost")
        .unwrap()
        .await
        .unwrap();
    // Hello 鉴权：[10:4][len:4][code][len:4]["desktop"]
    let (mut send, mut recv) = conn.open_bi().await.unwrap();
    let mut msg = Vec::new();
    msg.extend_from_slice(&10u32.to_be_bytes());
    msg.extend_from_slice(&(CODE.len() as u32).to_be_bytes());
    msg.extend_from_slice(CODE.as_bytes());
    msg.extend_from_slice(&("desktop".len() as u32).to_be_bytes());
    msg.extend_from_slice(b"desktop");
    send.write_all(&msg).await.unwrap();
    let mut ok = [0u8; 1];
    recv.read_exact(&mut ok).await.unwrap();
    assert_eq!(ok[0], 1, "Hello 鉴权应通过");
    conn
}

/// 注册控制流：仅写 4 字节类型 8，不 finish（与 QuicService 一致）
async fn register_control(conn: &Connection) -> quinn::RecvStream {
    let (mut send, recv) = conn.open_bi().await.unwrap();
    send.write_all(&8u32.to_be_bytes()).await.unwrap();
    // send 故意不 finish、不 drop（保持存活），仅存入 slot 等待服务端推送
    std::mem::forget(send);
    recv
}

async fn start_server(port: u16) -> ServerHandle {
    let tmp = std::env::temp_dir().join("quix_disconnect_test");
    std::fs::create_dir_all(&tmp).unwrap();
    let config = Config {
        port,
        output_dir: tmp.to_string_lossy().to_string(),
        max_concurrent_streams: 8,
        chunk_size: 4 * 1024 * 1024,
        enable_mdns: false,
        enable_cross_network: false,
        zerotier_network_id: String::new(),
        zerotier_api_token: String::new(),
        connection_timeout: 30,
        code: Some(CODE.into()),
    };
    ServerHandle::start(config, CODE.into(), "127.0.0.1".into())
        .await
        .unwrap()
}

#[tokio::test]
async fn server_disconnect_notifies_client() {
    let handle = start_server(45991).await;
    let conn = connect(45991).await;
    let mut ctrl = register_control(&conn).await;
    // 等待服务端接受流并注册
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    assert_eq!(handle.connected_count(), 1, "服务端应记录 1 个连接");

    // 服务端主动断开：客户端应先收到 4 字节 DisconnectNotify(13)
    handle.disconnect_all().await;
    let mut buf = [0u8; 4];
    tokio::time::timeout(std::time::Duration::from_secs(5), ctrl.read_exact(&mut buf))
        .await
        .expect("5 秒内应收到断开通知")
        .expect("读取断开通知失败");
    assert_eq!(
        u32::from_be_bytes(buf),
        13,
        "收到的应为 DisconnectNotify(13)"
    );
    handle.stop();
}

#[tokio::test]
async fn client_disconnect_drops_server_count() {
    let handle = start_server(45993).await;
    let conn = connect(45993).await;
    let _ctrl = register_control(&conn).await;
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    assert_eq!(handle.connected_count(), 1, "服务端应记录 1 个连接");

    // 客户端主动断开：新开流发送 DisconnectNotify(13) 后 finish
    let (mut send, _recv) = conn.open_bi().await.unwrap();
    send.write_all(&13u32.to_be_bytes()).await.unwrap();
    let _ = send.finish().await;

    // 服务端应关闭该连接，计数同步下降
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        while handle.connected_count() > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
    })
    .await
    .expect("服务端应在 5 秒内移除该连接");
    handle.stop();
}
