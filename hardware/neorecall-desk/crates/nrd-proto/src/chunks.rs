use reqwest::blocking::multipart::{Form, Part};
use reqwest::header::AUTHORIZATION;
use serde::Deserialize;

use crate::client::{ok_or_classify, read_body, ApiClient};
use crate::error::ApiError;
use crate::receipt::Receipt;

/// Every field the server's idempotency comparison checks
/// (`metadataMatches` in `server/services/ingest/ingest_service.js`) is read
/// straight from the ledger row by the caller and passed here verbatim, so a
/// retry of the same chunk is byte-for-byte and header-for-header identical
/// to the original -- never recomputed at call time.
pub struct PutChunkRequest {
    pub idempotency_key: String,
    pub sha256: String,
    pub duration_ms: i64,
    pub overlap_ms: i64,
    pub channel_layout: String,
    pub monotonic_offset_ms: i64,
    pub device_started_at: String,
    pub container: String,
    pub codec: String,
    /// Always "identity" -- Desk deliberately never gzips uploads; see the
    /// crate root docs.
    pub content_encoding: String,
    pub is_final: bool,
    pub audio_bytes: Vec<u8>,
    pub filename: String,
}

/// `status` distinguishes a first accept (202) from a duplicate replay
/// (200) -- the receipt body is otherwise the same shape either way.
pub struct PutChunkResponse {
    pub status: u16,
    pub receipt: Receipt,
}

#[derive(Debug, Deserialize)]
struct ReceiptEnvelope {
    receipt: Receipt,
}

#[derive(Debug, Deserialize)]
pub struct ChunkStatusResponse {
    pub receipts: Vec<Receipt>,
}

#[derive(Debug, Deserialize)]
pub struct ChunkReleasedResponse {
    pub released: u32,
}

impl ApiClient {
    pub fn put_chunk(
        &self,
        token: &str,
        session_id: &str,
        source_id: &str,
        sequence: i64,
        request: &PutChunkRequest,
    ) -> Result<PutChunkResponse, ApiError> {
        let part = Part::bytes(request.audio_bytes.clone())
            .file_name(request.filename.clone())
            .mime_str("audio/wav")
            .map_err(ApiError::from)?;
        let form = Form::new().part("audio", part);

        let response = self
            .http
            .put(self.url(&format!(
                "/ingest/sessions/{session_id}/sources/{source_id}/chunks/{sequence}"
            )))
            .header(AUTHORIZATION, Self::auth_header(token))
            .header("Idempotency-Key", &request.idempotency_key)
            .header("X-Chunk-Sha256", &request.sha256)
            .header("X-Chunk-Duration-Ms", request.duration_ms.to_string())
            .header("X-Chunk-Overlap-Ms", request.overlap_ms.to_string())
            .header("X-Channel-Layout", &request.channel_layout)
            .header(
                "X-Monotonic-Offset-Ms",
                request.monotonic_offset_ms.to_string(),
            )
            .header("X-Device-Started-At", &request.device_started_at)
            .header("X-Audio-Container", &request.container)
            .header("X-Audio-Codec", &request.codec)
            .header("X-Audio-Content-Encoding", &request.content_encoding)
            .header(
                "X-Final-Chunk",
                if request.is_final { "true" } else { "false" },
            )
            .multipart(form)
            .send()?;

        let (status, body) = read_body(response)?;
        let body = ok_or_classify(status, body)?;
        let envelope: ReceiptEnvelope =
            serde_json::from_str(&body).map_err(|e| ApiError::Transport(e.to_string()))?;
        Ok(PutChunkResponse {
            status,
            receipt: envelope.receipt,
        })
    }

    /// `chunk_ids` must already be batched to the server-advertised
    /// `chunkReceiptBatch` limit (from `/meta`) by the caller.
    pub fn chunk_status(
        &self,
        token: &str,
        chunk_ids: &[String],
    ) -> Result<ChunkStatusResponse, ApiError> {
        let body = serde_json::json!({ "chunkIds": chunk_ids });
        let response = self
            .http
            .post(self.url("/ingest/chunks/status"))
            .header(AUTHORIZATION, Self::auth_header(token))
            .json(&body)
            .send()?;
        let (status, body) = read_body(response)?;
        let body = ok_or_classify(status, body)?;
        serde_json::from_str(&body).map_err(|e| ApiError::Transport(e.to_string()))
    }

    pub fn chunk_released(
        &self,
        token: &str,
        chunk_ids: &[String],
    ) -> Result<ChunkReleasedResponse, ApiError> {
        let body = serde_json::json!({ "chunkIds": chunk_ids });
        let response = self
            .http
            .post(self.url("/ingest/chunks/released"))
            .header(AUTHORIZATION, Self::auth_header(token))
            .json(&body)
            .send()?;
        let (status, body) = read_body(response)?;
        let body = ok_or_classify(status, body)?;
        serde_json::from_str(&body).map_err(|e| ApiError::Transport(e.to_string()))
    }
}
