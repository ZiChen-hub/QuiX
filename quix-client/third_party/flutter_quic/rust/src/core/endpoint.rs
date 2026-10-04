//! Core Endpoint API - Direct Quinn endpoint wrapper

use flutter_rust_bridge::frb;
use crate::core::connection::QuicConnection;
use crate::errors::QuicError;
use sha2::{Digest, Sha256};
use std::net::{SocketAddr, Ipv4Addr};
use std::sync::{Arc, Mutex};

#[frb(opaque)]
pub struct QuicEndpoint {
    inner: quinn::Endpoint,
    last_fingerprint: Arc<Mutex<Option<String>>>,
}

impl QuicEndpoint {
    /// Create a new server endpoint with the given configuration
    pub fn server(config: crate::core::config::QuicServerConfig, addr: String) -> Result<Self, QuicError> {
        let rt = tokio::runtime::Runtime::new()
            .map_err(|e| QuicError::Endpoint(format!("Failed to create runtime: {:?}", e)))?;
        
        rt.block_on(async {
            let addr: SocketAddr = addr.parse()
                .map_err(|e| QuicError::Config(format!("Invalid address: {:?}", e)))?;
            
            let endpoint = quinn::Endpoint::server(config.into_inner(), addr)
                .map_err(|e| QuicError::Endpoint(format!("Failed to create server endpoint: {:?}", e)))?;
            
            Ok(Self { inner: endpoint, last_fingerprint: Arc::new(Mutex::new(None)) })
        })
    }

    /// Create a new client endpoint（可选期望证书指纹，用于握手期强 pinning）
    pub fn client(expected_fingerprint: Option<String>) -> Result<Self, QuicError> {
        // Ensure crypto provider is installed
        if rustls::crypto::CryptoProvider::get_default().is_none() {
            rustls::crypto::ring::default_provider()
                .install_default()
                .map_err(|_| QuicError::Config("Failed to install default crypto provider".to_string()))?;
        }
        
        // 记录服务端证书指纹（SHA256），供上层做 TOFU 校验
        let last_fingerprint: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

        // Create insecure client config（握手期强 pinning：期望指纹不匹配则拒绝连接）
        let crypto = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(FingerprintRecorder::new(last_fingerprint.clone(), expected_fingerprint))
            .with_no_client_auth();
            
        let mut config = quinn::ClientConfig::new(Arc::new(
            quinn::crypto::rustls::QuicClientConfig::try_from(crypto)
                .map_err(|e| QuicError::Config(format!("Failed to create QUIC client config: {:?}", e)))?
        ));
        
        // Configure transport parameters for better performance
        let mut transport = quinn::TransportConfig::default();
        transport.max_concurrent_bidi_streams(100u32.into());
        transport.max_concurrent_uni_streams(100u32.into());
        // 禁用空闲超时：否则客户端在选文件/计算哈希的间隙连接会被 10s 空闲超时断开
        transport.max_idle_timeout(None);
        config.transport_config(Arc::new(transport));
        
        // Create endpoint with default socket
        let mut endpoint = quinn::Endpoint::client(SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0))
            .map_err(|e| QuicError::Endpoint(format!("Failed to create client endpoint: {:?}", e)))?;
            
        endpoint.set_default_client_config(config);
        
        Ok(Self { inner: endpoint, last_fingerprint })
    }
    
    /// 获取最近一次成功连接的服务端证书指纹（SHA256 hex），用于 TOFU 校验
    pub fn last_server_cert_fingerprint(&self) -> Option<String> {
        self.last_fingerprint.lock().unwrap().clone()
    }
    
    /// Connect to a server
    pub async fn connect(&self, addr: String, server_name: String) -> Result<QuicConnection, QuicError> {
        let addr: SocketAddr = addr.parse()
            .map_err(|e| QuicError::Connection(format!("Invalid address: {:?}", e)))?;
        
        let connecting = self.inner.connect(addr, &server_name)
            .map_err(|e| QuicError::Connection(format!("Failed to initiate connection: {:?}", e)))?;
        
        let connection = connecting.await
            .map_err(|e| QuicError::Connection(format!("Failed to establish connection: {:?}", e)))?;
        
        Ok(QuicConnection::new(connection))
    }
    
    /// Get a reference to the inner Quinn endpoint
    pub(crate) fn inner(&self) -> &quinn::Endpoint {
        &self.inner
    }
}

/// 跳过服务端证书校验，但记录服务端证书指纹（SHA256），供上层做 TOFU（首次信任）
#[derive(Debug)]
struct FingerprintRecorder {
    fingerprint: Arc<Mutex<Option<String>>>,
    expected_fingerprint: Option<String>,
}

impl FingerprintRecorder {
    fn new(
        fingerprint: Arc<Mutex<Option<String>>>,
        expected_fingerprint: Option<String>,
    ) -> Arc<Self> {
        Arc::new(Self {
            fingerprint,
            expected_fingerprint,
        })
    }
}

impl rustls::client::danger::ServerCertVerifier for FingerprintRecorder {
    fn verify_server_cert(
        &self,
        end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        // 记录证书指纹（SHA256，hex）
        let fingerprint = Sha256::digest(end_entity.as_ref())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        if let Ok(mut guard) = self.fingerprint.lock() {
            *guard = Some(fingerprint.clone());
        }
        // 握手期强 pinning：期望指纹非空且不匹配则拒绝连接
        if let Some(expected) = &self.expected_fingerprint {
            if expected != &fingerprint {
                return Err(rustls::Error::General(
                    "证书指纹不匹配（疑似中间人攻击）".to_string(),
                ));
            }
        }
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::RSA_PKCS1_SHA1,
            rustls::SignatureScheme::ECDSA_SHA1_Legacy,
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
            rustls::SignatureScheme::ECDSA_NISTP521_SHA512,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::ED448,
        ]
    }
} 