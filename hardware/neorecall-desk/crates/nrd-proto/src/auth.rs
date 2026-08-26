use reqwest::header::AUTHORIZATION;
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::client::{ok_or_classify, read_body, ApiClient};
use crate::error::ApiError;

/// Holds a password or TOTP code only as long as the login call needs it,
/// then zeroes the backing memory. Never implements `Debug` -- accidentally
/// logging a `LoginRequest` must not be possible.
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct Secret(String);

impl Secret {
    pub fn new(value: impl Into<String>) -> Self {
        Secret(value.into())
    }
}

pub struct LoginRequest {
    pub account: String,
    pub password: Secret,
    pub two_factor_code: Option<Secret>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SessionInfo {
    pub token: String,
    #[serde(rename = "expiresAt")]
    pub expires_at: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LoginResponse {
    pub user: serde_json::Value,
    pub session: SessionInfo,
}

#[derive(Debug, Clone, Serialize)]
pub struct CreateApiKeyRequest {
    pub name: String,
    pub scopes: Vec<String>,
    #[serde(rename = "expiresAt")]
    pub expires_at: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateApiKeyResponse {
    pub id: String,
    pub scopes: Vec<String>,
    /// The plaintext key, e.g. `nrk_...`. Returned exactly once; nothing in
    /// this crate persists it -- that is `nrd-enroll::secret_store`'s job,
    /// and it must never be logged.
    pub token: String,
}

impl ApiClient {
    /// On a 401 with `TWO_FACTOR_REQUIRED`, retry with
    /// `two_factor_code` set; `INVALID_TWO_FACTOR` and
    /// `TWO_FACTOR_LOCKED` (via `ApiError`) must be shown to the operator,
    /// not silently retried.
    pub fn login(&self, request: &LoginRequest) -> Result<LoginResponse, ApiError> {
        let body = serde_json::json!({
            "account": request.account,
            "password": request.password.0,
            "twoFactorCode": request.two_factor_code.as_ref().map(|s| s.0.clone()),
        });
        let response = self.http.post(self.url("/auth/login")).json(&body).send()?;
        let (status, body) = read_body(response)?;
        let body = ok_or_classify(status, body)?;
        serde_json::from_str(&body).map_err(|e| ApiError::Transport(e.to_string()))
    }

    pub fn create_api_key(
        &self,
        session_token: &str,
        request: &CreateApiKeyRequest,
    ) -> Result<CreateApiKeyResponse, ApiError> {
        let response = self
            .http
            .post(self.url("/api-keys"))
            .header(AUTHORIZATION, Self::auth_header(session_token))
            .json(request)
            .send()?;
        let (status, body) = read_body(response)?;
        let body = ok_or_classify(status, body)?;
        serde_json::from_str(&body).map_err(|e| ApiError::Transport(e.to_string()))
    }

    pub fn logout(&self, session_token: &str) -> Result<(), ApiError> {
        let response = self
            .http
            .post(self.url("/auth/logout"))
            .header(AUTHORIZATION, Self::auth_header(session_token))
            .send()?;
        let (status, body) = read_body(response)?;
        ok_or_classify(status, body).map(|_| ())
    }

    /// Lets the appliance revoke its own device API key during on-device
    /// sign-out, without needing an interactive session
    /// (`DELETE /api/v1/api-keys/self`).
    pub fn revoke_self(&self, api_key_token: &str) -> Result<(), ApiError> {
        let response = self
            .http
            .delete(self.url("/api-keys/self"))
            .header(AUTHORIZATION, Self::auth_header(api_key_token))
            .send()?;
        let (status, body) = read_body(response)?;
        ok_or_classify(status, body).map(|_| ())
    }
}
