# Security Policy

## Supported Versions

Security fixes are applied to the latest stable release and, when affected, the
current beta line. Older releases should be updated before a report is
validated.

## Report a Vulnerability Privately

Do not open a public issue for a suspected vulnerability.

Use GitHub's
[private vulnerability reporting](https://github.com/NeoLabs-Systems/NeoRecall/security/advisories/new)
to send the report to the maintainer.

Include:

- The affected version or commit.
- The affected component. Leave out real recordings and personal data.
- Reproduction steps or a minimal proof of concept.
- The impact you observed.
- Any known mitigations.

Do not include live credentials, personal data, or access to a production
system. Use test accounts and redact logs.

The maintainer will confirm receipt, investigate the report, coordinate a fix,
and credit the reporter when requested and appropriate. Please allow time for a
release before publishing technical details.

## Data Handling

Audio is transient server-side data and is sealed with AES-256-GCM while it waits on disk. The SQLite database is page-encrypted with the installation key in `NEORECALL_HOME/data/secret.key`, so transcripts, memories, and search indexes are not plaintext files. Voice embeddings are sensitive biometric-like data and are sealed again inside that database. Deployments should use TLS at the reverse proxy, restrictive permissions for `NEORECALL_HOME`, and a strong password (plus two-factor authentication) on every admin account. Admin is a role on a user account; admin routes accept only an interactive session, never an API key or OAuth token. Keep `secret.key` off backup media that already holds encrypted artifacts. NeoRecall sends audio to the configured transcription endpoint and transcript text to the configured language-model endpoint. Treat both endpoints and their credentials as part of the trusted deployment boundary; admin-supplied provider keys are encrypted at rest and never returned by the API.
