//! Append-only, numbered schema migrations, gated on `PRAGMA user_version`
//! (mirroring the server's own append-only migration discipline in
//! `GUIDELINES.md`). Each migration is one transaction.

use rusqlite::Connection;

use crate::error::LedgerError;

const MIGRATIONS: &[(i64, &str)] = &[(1, include_str!("../migrations/0001_init.sql"))];

pub fn run_migrations(conn: &Connection) -> Result<(), LedgerError> {
    let current: i64 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    for (version, sql) in MIGRATIONS {
        if *version <= current {
            continue;
        }
        conn.execute_batch(&format!(
            "BEGIN; {sql} PRAGMA user_version = {version}; COMMIT;"
        ))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrations_are_idempotent_and_strictly_increasing() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        run_migrations(&conn).unwrap(); // second call must be a no-op, not an error
        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, MIGRATIONS.last().unwrap().0);

        let mut seen = 0i64;
        for (version, _) in MIGRATIONS {
            assert!(
                *version > seen,
                "migration versions must be strictly increasing"
            );
            seen = *version;
        }
    }

    #[test]
    fn the_expected_tables_exist_after_migration() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        for table in ["kv", "sessions", "sources", "chunks", "gaps"] {
            let count: i64 = conn
                .query_row(
                    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?1",
                    [table],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(count, 1, "expected table {table} to exist");
        }
    }
}
