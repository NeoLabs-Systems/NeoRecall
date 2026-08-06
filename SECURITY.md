# Security policy

Please report vulnerabilities privately to the NeoLabs-Systems security contact rather than opening a public issue. Include the affected version and a minimal reproduction without real recordings or personal data.

Audio is transient server-side data. Voice embeddings are sensitive biometric-like data. Deployments should use TLS at the reverse proxy, restrictive permissions for `NEORECALL_HOME`, and a strong admin API key. Transcription and generation run on the host by default and need no credential; a deployment that points `AI_PROVIDER=openai_compatible` at an external endpoint is sending transcript text there and should treat that endpoint and its key accordingly.
