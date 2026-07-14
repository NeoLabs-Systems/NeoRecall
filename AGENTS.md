# Agent instructions

- Always expect the application to run on another server. Logs supplied by a user may not match files on this computer.
- Do not hardcode scenario-specific behavior. Centralize configurable thresholds and limits.
- Do not add fake implementations or unfinished placeholder behavior.
- Never use phrase-based filters in AI or language-processing code.
- Preserve the reliability invariant: a client may release audio only after a terminal receipt proves transcript persistence and server-side audio deletion.
