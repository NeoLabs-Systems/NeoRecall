//! Content-on-disk handling for chunk audio. Writes go through a temp file
//! plus atomic rename plus directory fsync, per `AGENTS.md`'s reliability
//! invariant — a crash must never be able to produce a chunk row that points
//! at a half-written file.

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::error::LedgerError;

fn io_err(path: &Path, source: std::io::Error) -> LedgerError {
    LedgerError::Io {
        path: path.display().to_string(),
        source,
    }
}

/// Writes `data` to `<dir>/<local_id>.wav` via a same-directory temp file,
/// fsyncing the file and then the directory before returning. Returns the
/// final path, the sha256 hex digest, and the byte length.
pub fn write_atomic(
    dir: &Path,
    local_id: &str,
    data: &[u8],
) -> Result<(PathBuf, String, u64), LedgerError> {
    fs::create_dir_all(dir).map_err(|e| io_err(dir, e))?;
    let final_path = dir.join(format!("{local_id}.wav"));
    let temp_path = dir.join(format!("{local_id}.partial"));

    {
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&temp_path)
            .map_err(|e| io_err(&temp_path, e))?;
        file.write_all(data).map_err(|e| io_err(&temp_path, e))?;
        file.sync_all().map_err(|e| io_err(&temp_path, e))?;
    }
    fs::rename(&temp_path, &final_path).map_err(|e| io_err(&final_path, e))?;
    fsync_dir(dir)?;

    let sha256 = hex::encode(Sha256::digest(data));
    Ok((final_path, sha256, data.len() as u64))
}

fn fsync_dir(dir: &Path) -> Result<(), LedgerError> {
    let dir_handle = File::open(dir).map_err(|e| io_err(dir, e))?;
    dir_handle.sync_all().map_err(|e| io_err(dir, e))
}

pub fn read(path: &Path) -> Result<Vec<u8>, LedgerError> {
    fs::read(path).map_err(|e| io_err(path, e))
}

pub fn sha256_hex(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

/// Re-hashes the file on disk and compares it against `expected_sha256_hex`.
/// This is the integrity check the upload pump runs before every PUT (and
/// before every reupload) so a corrupted or truncated file is caught locally
/// rather than producing a 422 HASH_MISMATCH or, worse, silently uploading
/// wrong audio.
pub fn verify_sha256(path: &Path, expected_sha256_hex: &str) -> Result<bool, LedgerError> {
    let data = read(path)?;
    Ok(sha256_hex(&data) == expected_sha256_hex)
}

/// Idempotent: a missing file is not an error (the recovery boundary "row
/// released, file present" re-runs this safely after a partial prior run).
pub fn unlink_if_present(path: &Path) -> Result<(), LedgerError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(io_err(path, e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_atomic_leaves_no_temp_file_behind_and_returns_a_correct_hash() {
        let dir = tempfile::tempdir().unwrap();
        let (path, sha256, size) = write_atomic(dir.path(), "abc", b"hello world").unwrap();
        assert!(path.exists());
        assert!(!dir.path().join("abc.partial").exists());
        assert_eq!(size, 11);
        assert_eq!(sha256, sha256_hex(b"hello world"));
    }

    #[test]
    fn verify_sha256_detects_a_mismatch() {
        let dir = tempfile::tempdir().unwrap();
        let (path, sha256, _) = write_atomic(dir.path(), "abc", b"hello world").unwrap();
        assert!(verify_sha256(&path, &sha256).unwrap());
        fs::write(&path, b"tampered").unwrap();
        assert!(!verify_sha256(&path, &sha256).unwrap());
    }

    #[test]
    fn unlink_if_present_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let (path, _, _) = write_atomic(dir.path(), "abc", b"data").unwrap();
        unlink_if_present(&path).unwrap();
        assert!(!path.exists());
        // Second call on an already-missing file must not error.
        unlink_if_present(&path).unwrap();
    }

    #[test]
    fn write_atomic_creates_the_directory_if_missing() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("audio");
        write_atomic(&nested, "abc", b"data").unwrap();
        assert!(nested.join("abc.wav").exists());
    }
}
