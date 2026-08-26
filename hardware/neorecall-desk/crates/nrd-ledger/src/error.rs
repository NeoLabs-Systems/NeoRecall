use thiserror::Error;

#[derive(Debug, Error)]
pub enum LedgerError {
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("io error at {path}: {source}")]
    Io {
        path: String,
        source: std::io::Error,
    },
    #[error("illegal chunk state transition: {0}")]
    IllegalTransition(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("integrity check failed: {0}")]
    Integrity(String),
}
