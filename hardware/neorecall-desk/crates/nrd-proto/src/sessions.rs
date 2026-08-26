use reqwest::header::AUTHORIZATION;
use serde::{Deserialize, Serialize};

use crate::client::{ok_or_classify, read_body, ApiClient};
use crate::error::ApiError;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceDeclaration {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub client_uuid: String,
    pub kind: String,
    pub channel_layout: String,
    pub sample_rate: u32,
    pub sample_format: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateSessionRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub device_id: String,
    pub client_uuid: String,
    pub started_at: String,
    pub timezone: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub clock_offset_ms: Option<f64>,
    pub consent_attested_at: String,
    pub sources: Vec<SourceDeclaration>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateSessionResponse {
    pub session: serde_json::Value,
    pub sources: Vec<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CloseSourceRef {
    pub id: String,
    #[serde(rename = "finalSequence")]
    pub final_sequence: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CloseSessionRequest {
    pub ended_at: String,
    pub status: String,
    pub sources: Vec<CloseSourceRef>,
}

#[derive(Debug, Clone, Serialize)]
pub struct GapDeclaration {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(rename = "sourceId")]
    pub source_id: String,
    #[serde(rename = "startOffsetMs")]
    pub start_offset_ms: i64,
    #[serde(rename = "endOffsetMs")]
    pub end_offset_ms: i64,
    #[serde(rename = "startSequence", skip_serializing_if = "Option::is_none")]
    pub start_sequence: Option<i64>,
    #[serde(rename = "endSequence", skip_serializing_if = "Option::is_none")]
    pub end_sequence: Option<i64>,
    pub reason: String,
}

impl ApiClient {
    pub fn create_session(
        &self,
        token: &str,
        request: &CreateSessionRequest,
    ) -> Result<CreateSessionResponse, ApiError> {
        let response = self
            .http
            .post(self.url("/ingest/sessions"))
            .header(AUTHORIZATION, Self::auth_header(token))
            .json(request)
            .send()?;
        let (status, body) = read_body(response)?;
        let body = ok_or_classify(status, body)?;
        serde_json::from_str(&body).map_err(|e| ApiError::Transport(e.to_string()))
    }

    pub fn close_session(
        &self,
        token: &str,
        session_id: &str,
        request: &CloseSessionRequest,
    ) -> Result<(), ApiError> {
        let response = self
            .http
            .patch(self.url(&format!("/ingest/sessions/{session_id}")))
            .header(AUTHORIZATION, Self::auth_header(token))
            .json(request)
            .send()?;
        let (status, body) = read_body(response)?;
        ok_or_classify(status, body).map(|_| ())
    }

    pub fn close_source(
        &self,
        token: &str,
        session_id: &str,
        source_id: &str,
        final_sequence: i64,
    ) -> Result<(), ApiError> {
        let body = serde_json::json!({ "finalSequence": final_sequence });
        let response = self
            .http
            .patch(self.url(&format!(
                "/ingest/sessions/{session_id}/sources/{source_id}"
            )))
            .header(AUTHORIZATION, Self::auth_header(token))
            .json(&body)
            .send()?;
        let (status, body) = read_body(response)?;
        ok_or_classify(status, body).map(|_| ())
    }

    /// `gaps` must already be chunked to at most 1000 per call by the
    /// caller (the server's own limit on `POST .../gaps`).
    pub fn post_gaps(
        &self,
        token: &str,
        session_id: &str,
        gaps: &[GapDeclaration],
    ) -> Result<(), ApiError> {
        let body = serde_json::json!({ "gaps": gaps });
        let response = self
            .http
            .post(self.url(&format!("/ingest/sessions/{session_id}/gaps")))
            .header(AUTHORIZATION, Self::auth_header(token))
            .json(&body)
            .send()?;
        let (status, body) = read_body(response)?;
        ok_or_classify(status, body).map(|_| ())
    }
}
