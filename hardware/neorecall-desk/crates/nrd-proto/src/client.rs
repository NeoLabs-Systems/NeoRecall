use std::time::Duration;

use crate::error::{classify, ApiError};

/// A thin wrapper over a blocking `reqwest` client. Blocking rather than
/// async: `nrd-core`'s upload pump runs these calls from a dedicated worker
/// (or via `tokio::task::spawn_blocking`), which keeps this crate's own
/// tests simple and dependency-light while still being genuinely usable from
/// an async caller.
pub struct ApiClient {
    pub(crate) http: reqwest::blocking::Client,
    pub(crate) base_url: String,
}

impl ApiClient {
    /// `base_url` should be the server origin without a path, e.g.
    /// `https://recall.example.com`. `/api/v1` is appended by each call.
    pub fn new(
        base_url: impl Into<String>,
        connect_timeout: Duration,
        request_timeout: Duration,
        allow_insecure_tls: bool,
    ) -> Result<ApiClient, ApiError> {
        let http = reqwest::blocking::Client::builder()
            .connect_timeout(connect_timeout)
            .timeout(request_timeout)
            .danger_accept_invalid_certs(allow_insecure_tls)
            .build()
            .map_err(ApiError::from)?;
        Ok(ApiClient {
            http,
            base_url: base_url.into().trim_end_matches('/').to_string(),
        })
    }

    pub(crate) fn url(&self, path: &str) -> String {
        format!("{}/api/v1{}", self.base_url, path)
    }

    pub(crate) fn auth_header(token: &str) -> String {
        format!("Bearer {token}")
    }
}

/// Reads a response body as text and, on a non-2xx status, classifies it
/// into an `ApiError`. On success, returns the body text for the caller to
/// deserialize (kept as a separate step so callers needing the raw status,
/// e.g. to distinguish 200 vs 202, still get every response uniformly).
pub(crate) fn read_body(response: reqwest::blocking::Response) -> Result<(u16, String), ApiError> {
    let status = response.status().as_u16();
    let text = response.text().map_err(ApiError::from)?;
    Ok((status, text))
}

pub(crate) fn ok_or_classify(status: u16, body: String) -> Result<String, ApiError> {
    if (200..300).contains(&status) {
        Ok(body)
    } else {
        Err(classify(status, &body))
    }
}
