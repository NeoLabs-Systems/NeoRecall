use thiserror::Error;

/// Classifies a failed API call so `nrd-core`'s upload pump can decide
/// retry policy without re-deriving it from raw status codes at every call
/// site. Mirrors the reference firmware's status handling in
/// `nr_ingest.c` (401 -> re-auth + requeue; 404 -> re-declare; 400/409/422
/// -> not worth blindly retrying; 408/429/5xx -> transient).
#[derive(Debug, Error)]
pub enum ApiError {
    #[error("transient failure ({status:?}): {message}")]
    Transient {
        status: Option<u16>,
        message: String,
    },
    #[error("authentication required or expired: {message}")]
    AuthExpired { message: String },
    #[error("not found: {message}")]
    NotFound { message: String },
    #[error("conflict ({code}): {message}")]
    Conflict { code: String, message: String },
    #[error("validation error ({code}): {message}")]
    Validation { code: String, message: String },
    #[error("two-factor authentication required")]
    TwoFactorRequired,
    #[error("invalid two-factor code")]
    InvalidTwoFactor,
    #[error("two-factor authentication temporarily locked")]
    TwoFactorLocked,
    #[error("request error: {0}")]
    Transport(String),
}

/// The shape of `{"error": {"code", "message", ...}}` from
/// `server/middleware/error_handler.js`.
#[derive(Debug, serde::Deserialize)]
struct ErrorBody {
    error: ErrorDetail,
}

#[derive(Debug, serde::Deserialize)]
struct ErrorDetail {
    code: String,
    message: String,
}

/// Classifies an HTTP response into an `ApiError` from its status and (if
/// present) the standard `{error:{code,message}}` body.
pub fn classify(status: u16, body_text: &str) -> ApiError {
    let parsed: Option<ErrorBody> = serde_json::from_str(body_text).ok();
    let code = parsed
        .as_ref()
        .map(|b| b.error.code.clone())
        .unwrap_or_default();
    let message = parsed
        .as_ref()
        .map(|b| b.error.message.clone())
        .unwrap_or_else(|| body_text.to_string());

    match status {
        401 => match code.as_str() {
            "TWO_FACTOR_REQUIRED" => ApiError::TwoFactorRequired,
            "INVALID_TWO_FACTOR" => ApiError::InvalidTwoFactor,
            _ => ApiError::AuthExpired { message },
        },
        429 if code == "TWO_FACTOR_LOCKED" => ApiError::TwoFactorLocked,
        429 => ApiError::Transient {
            status: Some(status),
            message,
        },
        404 => ApiError::NotFound { message },
        409 => ApiError::Conflict { code, message },
        400 | 422 => ApiError::Validation { code, message },
        408 | 500..=599 => ApiError::Transient {
            status: Some(status),
            message,
        },
        _ => ApiError::Transient {
            status: Some(status),
            message,
        },
    }
}

impl From<reqwest::Error> for ApiError {
    fn from(err: reqwest::Error) -> Self {
        ApiError::Transport(err.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_401_with_two_factor_required_is_distinguished_from_a_plain_auth_failure() {
        let err = classify(
            401,
            r#"{"error":{"code":"TWO_FACTOR_REQUIRED","message":"2FA needed"}}"#,
        );
        assert!(matches!(err, ApiError::TwoFactorRequired));
    }

    #[test]
    fn a_401_without_a_two_factor_code_is_a_plain_auth_expiry() {
        let err = classify(
            401,
            r#"{"error":{"code":"AUTHENTICATION_REQUIRED","message":"bad token"}}"#,
        );
        assert!(matches!(err, ApiError::AuthExpired { .. }));
    }

    #[test]
    fn a_409_is_a_conflict_carrying_the_server_code() {
        let err = classify(
            409,
            r#"{"error":{"code":"IDEMPOTENCY_CONFLICT","message":"mismatch"}}"#,
        );
        match err {
            ApiError::Conflict { code, .. } => assert_eq!(code, "IDEMPOTENCY_CONFLICT"),
            other => panic!("expected Conflict, got {other:?}"),
        }
    }

    #[test]
    fn server_errors_and_408_are_transient() {
        assert!(matches!(classify(500, "{}"), ApiError::Transient { .. }));
        assert!(matches!(classify(503, "{}"), ApiError::Transient { .. }));
        assert!(matches!(classify(408, "{}"), ApiError::Transient { .. }));
    }

    #[test]
    fn a_malformed_body_still_classifies_by_status_without_panicking() {
        let err = classify(500, "not json at all");
        assert!(matches!(err, ApiError::Transient { .. }));
    }
}
