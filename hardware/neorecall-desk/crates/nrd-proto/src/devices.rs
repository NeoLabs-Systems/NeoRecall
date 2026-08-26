use reqwest::header::AUTHORIZATION;
use serde::{Deserialize, Serialize};

use crate::client::{ok_or_classify, read_body, ApiClient};
use crate::error::ApiError;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterDeviceRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub client_uuid: String,
    pub name: String,
    pub platform: String,
    pub kind: String,
    pub capabilities: serde_json::Value,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DeviceResponse {
    pub id: String,
    pub kind: String,
}

impl ApiClient {
    /// Registers (or re-registers) the device. `POST /devices` always
    /// returns 201, never 200 -- and the server may return a **different**
    /// `id` than the one requested for a known `clientUuid`. The caller must
    /// persist whatever `id` comes back, or every subsequent upload is
    /// blocked. Re-registration overwrites name/platform/kind/capabilities
    /// server-side, so always send the full current set, never a delta.
    pub fn register_device(
        &self,
        token: &str,
        request: &RegisterDeviceRequest,
    ) -> Result<DeviceResponse, ApiError> {
        let response = self
            .http
            .post(self.url("/devices"))
            .header(AUTHORIZATION, Self::auth_header(token))
            .json(request)
            .send()?;
        let (status, body) = read_body(response)?;
        let body = ok_or_classify(status, body)?;
        serde_json::from_str(&body).map_err(|e| ApiError::Transport(e.to_string()))
    }

    /// A 404 here means the device was deleted or revoked server-side; the
    /// caller must clear its local registration and re-register from
    /// scratch (mapped to `ApiError::NotFound` by `classify`).
    pub fn heartbeat(
        &self,
        token: &str,
        device_id: &str,
        client_sent_at: &str,
    ) -> Result<(), ApiError> {
        let body = serde_json::json!({ "clientSentAt": client_sent_at });
        let response = self
            .http
            .post(self.url(&format!("/devices/{device_id}/heartbeat")))
            .header(AUTHORIZATION, Self::auth_header(token))
            .json(&body)
            .send()?;
        let (status, body) = read_body(response)?;
        ok_or_classify(status, body).map(|_| ())
    }
}
