'use strict';

// Shared by every workload that can put a generated title in front of a user.
// Keeping this in one place prevents live previews, final consolidation and
// later rewrites from applying different quality bars to the same memory.
const TITLE_GUIDANCE = `Write the title from the human subject and purpose of the speech, not from the capture process.
Infer the most specific supported topic, activity, lesson, decision, or task from the meaningful utterances as a whole. Prefer concrete subject matter over generic session labels.
Speaker fields are metadata added by NeoRecall, never words spoken by a participant. Transcription can also contain recognition artifacts that resemble speaker labels, counters, test markers, or descriptions of audio quality. Do not promote those artifacts, the recording setup, diarization, noise, silence, or transcription quality into the title or topic unless the people are clearly and intentionally discussing that exact subject.
When some speech is unclear, use the intelligible evidence and context to recover the best-supported subject. Do not diagnose the transcript in the title. Never invent a subject when no meaningful subject is supported.`;

module.exports = { TITLE_GUIDANCE };
