# NeoRecall engineering guidelines

NeoRecall is a Go server with Flutter clients. Shared building blocks come from
`neolabs-go` and `neolabs-flutter`; search them before writing a helper. Keep
packages small, use parameterized SQL only, and add schema changes as new ordered
steps.

Reliability and privacy outrank throughput. No transcript receipt may become
terminal until derived rows are durably committed and the temporary server audio
file has been unlinked, and a client may release audio only after that receipt.
No server feature stores or serves audio after processing.

Language behavior must be model-driven and multilingual. Do not add phrase lists
or scenario-specific filters. Put tunable numeric thresholds in validated
configuration.

Do not add fake implementations or unfinished placeholder behavior. Assume the
server runs on another machine: logs a user supplies may not match files here.
