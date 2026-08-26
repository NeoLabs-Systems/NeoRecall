//! The NeoRecall Desk wire client.
//!
//! Desk deliberately **never gzips uploads**: the server's idempotency
//! comparison includes `byte_size` of the *uploaded* file
//! (`server/services/ingest/ingest_service.js::metadataMatches`), so gzip
//! would add a byte-identical-retry invariant for a marginal size win on
//! 16 kHz PCM. Every chunk PUT here sends `X-Audio-Content-Encoding:
//! identity`.
//!
//! Every retry of a chunk must be header-for-header and byte-for-byte
//! identical to the original attempt (see `chunks::PutChunkRequest`'s
//! doc) -- values are read back from `nrd-ledger`'s row by the caller, never
//! recomputed here.

mod auth;
mod chunks;
mod client;
mod devices;
mod error;
mod meta;
mod receipt;
mod sessions;
mod tls;

pub use auth::{
    CreateApiKeyRequest, CreateApiKeyResponse, LoginRequest, LoginResponse, Secret, SessionInfo,
};
pub use chunks::{ChunkReleasedResponse, ChunkStatusResponse, PutChunkRequest, PutChunkResponse};
pub use client::ApiClient;
pub use devices::{DeviceResponse, RegisterDeviceRequest};
pub use error::ApiError;
pub use meta::{MetaLimits, MetaResponse, UserSettingsChunkOverride};
pub use receipt::Receipt;
pub use sessions::{
    CloseSessionRequest, CloseSourceRef, CreateSessionRequest, CreateSessionResponse,
    GapDeclaration, SourceDeclaration,
};
pub use tls::{probe as tls_probe, validate_scheme as tls_validate_scheme};

#[cfg(test)]
mod integration_tests {
    use super::*;
    use std::sync::Arc;
    use std::time::Duration;
    use tiny_http::{Response, Server};

    fn spawn_server() -> (Arc<Server>, String) {
        let server = Arc::new(Server::http("127.0.0.1:0").unwrap());
        let addr = server.server_addr();
        (server, format!("http://{addr}"))
    }

    fn client(base_url: &str) -> ApiClient {
        ApiClient::new(
            base_url,
            Duration::from_secs(2),
            Duration::from_secs(5),
            false,
        )
        .unwrap()
    }

    #[test]
    fn register_device_parses_a_reconciled_id_different_from_the_request() {
        let (server, base_url) = spawn_server();
        let handle = std::thread::spawn(move || {
            let request = server.recv().unwrap();
            assert_eq!(request.url(), "/api/v1/devices");
            request
                .respond(
                    Response::from_string(r#"{"id":"server-assigned-id","kind":"appliance"}"#)
                        .with_status_code(201),
                )
                .unwrap();
        });

        let response = client(&base_url)
            .register_device(
                "token",
                &RegisterDeviceRequest {
                    id: Some("local-guess-id".to_string()),
                    client_uuid: "desk-client-uuid-0001".to_string(),
                    name: "NeoRecall Desk".to_string(),
                    platform: "raspberrypi-zero2w".to_string(),
                    kind: "appliance".to_string(),
                    capabilities: serde_json::json!({"usbAudio": "output-only"}),
                },
            )
            .unwrap();

        assert_eq!(response.id, "server-assigned-id");
        assert_ne!(response.id, "local-guess-id");
        handle.join().unwrap();
    }

    #[test]
    fn get_meta_parses_the_limits_object() {
        let (server, base_url) = spawn_server();
        let handle = std::thread::spawn(move || {
            let request = server.recv().unwrap();
            assert_eq!(request.url(), "/api/v1/meta");
            let body = r#"{
                "product": "NeoRecall", "version": "0.1.0-beta.38",
                "limits": {"maxUploadBytes":33554432,"chunkMinMs":15000,"chunkMaxMs":120000,
                           "chunkTargetMs":30000,"chunkOverlapMs":2000,"chunkReceiptBatch":500}
            }"#;
            request
                .respond(Response::from_string(body).with_status_code(200))
                .unwrap();
        });

        let meta = client(&base_url).get_meta("token").unwrap();
        assert_eq!(meta.limits.chunk_target_ms, 30_000);
        assert_eq!(meta.limits.chunk_receipt_batch, 500);
        handle.join().unwrap();
    }

    #[test]
    fn put_chunk_sends_every_required_header_and_the_audio_field_name() {
        let (server, base_url) = spawn_server();
        let handle = std::thread::spawn(move || {
            let mut request = server.recv().unwrap();
            assert_eq!(
                request.url(),
                "/api/v1/ingest/sessions/sess-1/sources/src-1/chunks/0"
            );
            assert_eq!(request.method(), &tiny_http::Method::Put);

            let headers: Vec<(String, String)> = request
                .headers()
                .iter()
                .map(|h| {
                    (
                        h.field.as_str().as_str().to_string(),
                        h.value.as_str().to_string(),
                    )
                })
                .collect();
            let get = |name: &str| {
                headers
                    .iter()
                    .find(|(k, _)| k.eq_ignore_ascii_case(name))
                    .map(|(_, v)| v.clone())
            };

            assert_eq!(get("Idempotency-Key").as_deref(), Some("chunk-local-id-1"));
            assert_eq!(get("X-Chunk-Sha256").as_deref(), Some("deadbeef"));
            assert_eq!(get("X-Chunk-Duration-Ms").as_deref(), Some("30000"));
            assert_eq!(get("X-Chunk-Overlap-Ms").as_deref(), Some("2000"));
            assert_eq!(get("X-Channel-Layout").as_deref(), Some("mono"));
            assert_eq!(get("X-Monotonic-Offset-Ms").as_deref(), Some("0"));
            assert_eq!(get("X-Audio-Container").as_deref(), Some("wav"));
            assert_eq!(get("X-Audio-Codec").as_deref(), Some("pcm_s16le"));
            assert_eq!(get("X-Audio-Content-Encoding").as_deref(), Some("identity"));
            assert_eq!(get("X-Final-Chunk").as_deref(), Some("false"));

            let mut body = Vec::new();
            request.as_reader().read_to_end(&mut body).unwrap();
            let body_text = String::from_utf8_lossy(&body);
            assert!(
                body_text.contains("name=\"audio\""),
                "multipart body must use field name \"audio\": {body_text}"
            );
            assert!(body_text.contains("chunk-local-id-1.wav"));

            let receipt = r#"{"receipt":{"chunkId":"server-chunk-1","sourceId":"src-1","sequence":0,"state":"uploaded","receiptVersion":0}}"#;
            request
                .respond(Response::from_string(receipt).with_status_code(202))
                .unwrap();
        });

        let response = client(&base_url)
            .put_chunk(
                "token",
                "sess-1",
                "src-1",
                0,
                &PutChunkRequest {
                    idempotency_key: "chunk-local-id-1".to_string(),
                    sha256: "deadbeef".to_string(),
                    duration_ms: 30_000,
                    overlap_ms: 2_000,
                    channel_layout: "mono".to_string(),
                    monotonic_offset_ms: 0,
                    device_started_at: "2026-08-25T00:00:00.000Z".to_string(),
                    container: "wav".to_string(),
                    codec: "pcm_s16le".to_string(),
                    content_encoding: "identity".to_string(),
                    is_final: false,
                    audio_bytes: vec![0u8; 16],
                    filename: "chunk-local-id-1.wav".to_string(),
                },
            )
            .unwrap();

        assert_eq!(response.status, 202);
        assert_eq!(response.receipt.chunk_id, "server-chunk-1");
        assert!(!response.receipt.proves_safe_audio_release());
        handle.join().unwrap();
    }

    #[test]
    fn a_409_conflict_response_is_classified_not_silently_retried() {
        let (server, base_url) = spawn_server();
        let handle = std::thread::spawn(move || {
            let request = server.recv().unwrap();
            let body = r#"{"error":{"code":"IDEMPOTENCY_CONFLICT","message":"metadata mismatch"}}"#;
            request
                .respond(Response::from_string(body).with_status_code(409))
                .unwrap();
        });

        let result = client(&base_url).chunk_status("token", &["chunk-1".to_string()]);
        match result {
            Err(ApiError::Conflict { code, .. }) => assert_eq!(code, "IDEMPOTENCY_CONFLICT"),
            other => panic!("expected Conflict, got {other:?}"),
        }
        handle.join().unwrap();
    }

    #[test]
    fn a_401_two_factor_required_is_surfaced_distinctly_from_a_login_failure() {
        let (server, base_url) = spawn_server();
        let handle = std::thread::spawn(move || {
            let mut request = server.recv().unwrap();
            let mut body = String::new();
            request.as_reader().read_to_string(&mut body).unwrap();
            // The raw password/2FA values must actually be in the JSON body
            // sent to the server, not some placeholder.
            assert!(body.contains("hunter2"));
            assert!(body.contains("654321"));
            let response_body =
                r#"{"error":{"code":"TWO_FACTOR_REQUIRED","message":"2FA required"}}"#;
            request
                .respond(Response::from_string(response_body).with_status_code(401))
                .unwrap();
        });

        let result = client(&base_url).login(&LoginRequest {
            account: "frank".to_string(),
            password: Secret::new("hunter2"),
            two_factor_code: Some(Secret::new("654321")),
        });
        assert!(matches!(result, Err(ApiError::TwoFactorRequired)));
        handle.join().unwrap();
    }

    #[test]
    fn chunk_released_reports_the_count_the_server_actually_changed() {
        let (server, base_url) = spawn_server();
        let handle = std::thread::spawn(move || {
            let request = server.recv().unwrap();
            request
                .respond(Response::from_string(r#"{"released":1}"#).with_status_code(200))
                .unwrap();
        });
        let response = client(&base_url)
            .chunk_released("token", &["chunk-1".to_string()])
            .unwrap();
        assert_eq!(response.released, 1);
        handle.join().unwrap();
    }
}
