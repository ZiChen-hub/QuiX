//! 生成 ASCII 二维码，供手机扫码连接（含 IP、端口、连接码）

use crate::config::Config;
use anyhow::Result;

/// 生成包含连接地址与连接码的 ASCII 二维码文本
pub fn generate_qr_ascii(config: &Config, code: &str, ip: &str) -> Result<String> {
    // 连接地址格式：quix://<ip>:<port>?code=<6位连接码>
    let payload = format!("quix://{}:{}?code={}", ip, config.port, code);

    let qr = qrcode::QrCode::new(payload.as_bytes())?;
    let rendered = qr
        .render::<qrcode::render::unicode::Dense1x2>()
        .quiet_zone(false)
        .module_dimensions(1, 1)
        .build();

    Ok(format!(
        "{}\n连接地址: {}\n连接码: {}\n监听端口: {}",
        rendered, payload, code, config.port
    ))
}
