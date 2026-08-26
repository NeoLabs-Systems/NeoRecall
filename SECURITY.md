# Security policy

Please report vulnerabilities privately to the NeoLabs-Systems security contact rather than opening a public issue. Include the affected version and a minimal reproduction without real recordings or personal data.

Audio is transient server-side data. Voice embeddings are sensitive biometric-like data. Deployments should use TLS at the reverse proxy, restrictive permissions for `NEORECALL_HOME`, and a strong admin API key. NeoRecall sends audio to the configured transcription endpoint and transcript text to the configured language-model endpoint. Treat both endpoints and their credentials as part of the trusted deployment boundary; admin-supplied provider keys are encrypted at rest and never returned by the API.
