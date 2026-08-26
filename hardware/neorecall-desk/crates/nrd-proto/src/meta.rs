use reqwest::header::AUTHORIZATION;
use serde::Deserialize;

use crate::client::{ok_or_classify, read_body, ApiClient};
use crate::error::ApiError;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetaLimits {
    pub max_upload_bytes: u64,
    pub chunk_min_ms: u32,
    pub chunk_max_ms: u32,
    pub chunk_target_ms: u32,
    pub chunk_overlap_ms: u32,
    pub chunk_receipt_batch: u32,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MetaResponse {
    pub limits: MetaLimits,
}

/// The subset of `GET /api/v1/settings` this crate consumes -- a signed-in
/// user's own chunk preference override. `/meta` reports process config
/// only, never this; a device that wants it needs the optional
/// `settings:read` scope.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserSettingsChunkOverride {
    #[serde(default)]
    pub chunk_target_ms: Option<u32>,
    #[serde(default)]
    pub chunk_overlap_ms: Option<u32>,
}

impl ApiClient {
    pub fn get_meta(&self, token: &str) -> Result<MetaResponse, ApiError> {
        let response = self
            .http
            .get(self.url("/meta"))
            .header(AUTHORIZATION, Self::auth_header(token))
            .send()?;
        let (status, body) = read_body(response)?;
        let body = ok_or_classify(status, body)?;
        serde_json::from_str(&body).map_err(|e| ApiError::Transport(e.to_string()))
    }

    /// Returns `Ok(None)` on a 403 (the `settings:read` scope was not
    /// granted) rather than an error -- it is documented as optional.
    pub fn get_user_chunk_overrides(
        &self,
        token: &str,
    ) -> Result<Option<UserSettingsChunkOverride>, ApiError> {
        let response = self
            .http
            .get(self.url("/settings"))
            .header(AUTHORIZATION, Self::auth_header(token))
            .send()?;
        let (status, body) = read_body(response)?;
        if status == 403 {
            return Ok(None);
        }
        let body = ok_or_classify(status, body)?;
        serde_json::from_str(&body)
            .map(Some)
            .map_err(|e| ApiError::Transport(e.to_string()))
    }
}
