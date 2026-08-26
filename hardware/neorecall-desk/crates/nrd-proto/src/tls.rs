//! The trusted-HTTPS gate. `nrd-enroll` calls `validate_scheme` before
//! accepting any server URL and `probe` before accepting any credential, so
//! a bad certificate is caught before a password or TOTP code is ever typed
//! or sent.
//!
//! Certificate chain, expiry, and hostname verification themselves are
//! `rustls`'s job (via `reqwest`'s default TLS backend) and are not
//! reimplemented here — `ApiClient::new`'s `allow_insecure_tls` flag maps
//! directly to `danger_accept_invalid_certs`. What this module adds is the
//! product-level policy on top: HTTPS is mandatory regardless of that flag
//! (an operator accepting an unverified certificate is not the same as
//! accepting no encryption at all), and a clear surfaced error before any
//! credential entry.

use crate::client::ApiClient;
use crate::error::ApiError;

pub fn validate_scheme(base_url: &str) -> Result<(), ApiError> {
    if base_url.starts_with("https://") {
        Ok(())
    } else {
        Err(ApiError::Validation {
            code: "INSECURE_SCHEME".to_string(),
            message: format!("server URL must use https:// (got {base_url:?}); allow_insecure_tls only skips certificate verification, never transport encryption"),
        })
    }
}

/// Performs a lightweight authenticated-or-not request against `/api/v1/meta`
/// purely to force the TLS handshake. Any HTTP response (even 401, since
/// `/meta` requires auth) proves the handshake succeeded; a transport-level
/// failure is surfaced as a `Validation` error with the underlying TLS
/// library's message, since `reqwest`/`rustls` do not expose a stable,
/// matchable distinction between "invalid chain", "expired", and "hostname
/// mismatch" across versions -- this crate does not guess at that
/// classification instead of verifying it.
pub fn probe(client: &ApiClient) -> Result<(), ApiError> {
    match client.http.get(client.url("/meta")).send() {
        Ok(_response) => Ok(()),
        Err(err) => Err(ApiError::Validation {
            code: "TLS_REJECTED".to_string(),
            message: err.to_string(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plain_http_url_is_rejected_regardless_of_the_insecure_flag() {
        assert!(validate_scheme("http://example.com").is_err());
    }

    #[test]
    fn an_https_url_passes() {
        assert!(validate_scheme("https://example.com").is_ok());
    }

    #[test]
    fn a_scheme_less_host_is_rejected() {
        assert!(validate_scheme("example.com").is_err());
    }
}
