//! TLS supplies confidentiality. Pinned Ed25519 identities authenticate the TLS
//! exporter before dictionary data is exchanged; pairing uses a one-use SPAKE2
//! password, also bound to that exporter. No unverified peer receives user rows.
use crate::model::MAX_FRAME;
use anyhow::{ensure, Context, Result};
use rustls::{
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime},
    DigitallySignedStruct, SignatureScheme,
};
use serde::{de::DeserializeOwned, Serialize};
use std::{
    net::{IpAddr, SocketAddr},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::TcpStream,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};

pub async fn read<T: DeserializeOwned, S: AsyncRead + Unpin>(stream: &mut S) -> Result<T> {
    tokio::time::timeout(Duration::from_secs(10), read_limit(stream, MAX_FRAME)).await?
}
pub async fn read_limit<T: DeserializeOwned, S: AsyncRead + Unpin>(
    stream: &mut S,
    limit: usize,
) -> Result<T> {
    let size = stream.read_u32().await? as usize;
    ensure!(size > 0 && size <= limit, "invalid frame size");
    let mut bytes = vec![0; size];
    stream.read_exact(&mut bytes).await?;
    Ok(serde_json::from_slice(&bytes)?)
}
pub async fn write<T: Serialize, S: AsyncWrite + Unpin>(stream: &mut S, value: &T) -> Result<()> {
    tokio::time::timeout(
        Duration::from_secs(10),
        write_limit(stream, value, MAX_FRAME),
    )
    .await?
}
pub async fn write_limit<T: Serialize, S: AsyncWrite + Unpin>(
    stream: &mut S,
    value: &T,
    limit: usize,
) -> Result<()> {
    let bytes = serde_json::to_vec(value)?;
    ensure!(bytes.len() <= limit, "frame capacity exceeded");
    stream.write_u32(bytes.len().try_into()?).await?;
    stream.write_all(&bytes).await?;
    stream.flush().await?;
    Ok(())
}
pub fn address(text: &str, isolated: bool) -> Result<SocketAddr> {
    let a: SocketAddr = text.parse().context("enter a local IP address and port")?;
    ensure!(a.port() != 0, "invalid port");
    ensure!(
        lan(a.ip(), isolated),
        "only local network addresses are allowed"
    );
    Ok(a)
}
pub fn lan(ip: IpAddr, isolated: bool) -> bool {
    match ip {
        IpAddr::V4(v) => v.is_private() || v.is_link_local() || isolated && v.is_loopback(),
        IpAddr::V6(v) => {
            v.is_unique_local() || v.is_unicast_link_local() || isolated && v.is_loopback()
        }
    }
}

#[derive(Debug)]
struct ApplicationIdentityVerifier;
impl ServerCertVerifier for ApplicationIdentityVerifier {
    fn verify_server_cert(
        &self,
        _: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        // Self-signed certificates are ephemeral. The stable pinned application
        // key must prove possession on this exact TLS channel in service.rs.
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}
pub fn acceptor() -> Result<TlsAcceptor> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let cert = rcgen::generate_simple_self_signed(vec!["rimeq.local".into()])?;
    let key = PrivateKeyDer::Pkcs8(cert.key_pair.serialize_der().into());
    let config = rustls::ServerConfig::builder_with_protocol_versions(&[&rustls::version::TLS13])
        .with_no_client_auth()
        .with_single_cert(vec![cert.cert.der().clone()], key)?;
    Ok(TlsAcceptor::from(Arc::new(config)))
}
pub async fn connect(address: SocketAddr) -> Result<tokio_rustls::client::TlsStream<TcpStream>> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let config = rustls::ClientConfig::builder_with_protocol_versions(&[&rustls::version::TLS13])
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(ApplicationIdentityVerifier))
        .with_no_client_auth();
    let tcp = tokio::time::timeout(Duration::from_secs(3), TcpStream::connect(address)).await??;
    tcp.set_nodelay(true)?;
    Ok(tokio::time::timeout(
        Duration::from_secs(5),
        TlsConnector::from(Arc::new(config)).connect(ServerName::try_from("rimeq.local")?, tcp),
    )
    .await??)
}
