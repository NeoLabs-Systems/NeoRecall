# Security policy

Please report vulnerabilities privately to the NeoLabs-Systems security contact rather than opening a public issue. Include the affected version and a minimal reproduction without real recordings or personal data.

Audio is transient server-side data. Voice embeddings are sensitive biometric-like data. Deployments should use TLS at the reverse proxy, restrictive permissions for `NEORECALL_HOME`, a strong admin API key, and a private OpenRouter key.
