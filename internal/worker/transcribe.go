package worker

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/cloud"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/events"
	"github.com/NeoLabs-Systems/neorecall/internal/ingest"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/processing"
	"github.com/NeoLabs-Systems/neorecall/internal/speakers"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
	"github.com/google/uuid"
)

type chunkRec struct {
	id, userID, sessionID, sourceID, channelLayout, state, deviceStartedAt string
	sequence                                                               int
	monotonicOffsetMs                                                      int64
	durationMs                                                             int
	temporaryPath                                                          sql.NullString
	transcriptSegCount                                                     sql.NullInt64
}

func (r *Runner) handleTranscribe(ctx context.Context, j *jobs.Job) error {
	var ck chunkRec
	err := r.DB.R.QueryRowContext(ctx, `SELECT id, user_id, session_id, source_id, sequence, channel_layout,
		device_started_at, monotonic_offset_ms, duration_ms, state, temporary_path, transcript_segment_count
		FROM audio_chunks WHERE id=? AND user_id=?`, j.ResourceID, j.UserID).
		Scan(&ck.id, &ck.userID, &ck.sessionID, &ck.sourceID, &ck.sequence, &ck.channelLayout,
			&ck.deviceStartedAt, &ck.monotonicOffsetMs, &ck.durationMs, &ck.state, &ck.temporaryPath, &ck.transcriptSegCount)
	if err == sql.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}
	if ingest.TerminalStates[ck.state] {
		return nil
	}
	if ck.state == "persisted_cleanup_pending" {
		segCnt := int(ck.transcriptSegCount.Int64)
		r.capturePreviews(ctx, ck, segCnt)
		return r.finishCleanup(ctx, ck.id, ck.userID, ck.sessionID, ck.sourceID, ck.sequence, ck.temporaryPath.String, segCnt)
	}
	if !ck.temporaryPath.Valid || ck.temporaryPath.String == "" {
		return &codedErr{code: "AUDIO_REUPLOAD_REQUIRED", msg: "Server audio is missing and must be uploaded again.", retryable: false}
	}

	var deviceID, corrStartedAt string
	if err := r.DB.R.QueryRowContext(ctx, `SELECT device_id, corrected_started_at FROM recording_sessions WHERE id=? AND user_id=?`,
		ck.sessionID, ck.userID).Scan(&deviceID, &corrStartedAt); err != nil {
		return &codedErr{code: "SESSION_MISSING", msg: "Recording session no longer exists.", retryable: false}
	}

	c := r.cfg()
	if transcription.IsCovered(ctx, r.DB, ck.userID, deviceID, ck.sourceID, ck.deviceStartedAt, ck.durationMs, c.SameDeviceCoverageRatio) {
		count, err := r.persistSegments(ctx, ck, corrStartedAt, nil)
		if err != nil {
			return err
		}
		return r.finishCleanup(ctx, ck.id, ck.userID, ck.sessionID, ck.sourceID, ck.sequence, ck.temporaryPath.String, count)
	}

	_, _ = r.DB.W.ExecContext(ctx, `UPDATE audio_chunks SET state='processing', updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, ck.id)

	var vocab []string
	var vocabCorr, recMatch, diarOn bool = true, true, c.DiarizationEnabled
	if r.Settings != nil {
		vocab = r.Settings.TranscriptionVocabulary(ctx, ck.userID)
		if st, err := r.Settings.Get(ctx, ck.userID); err == nil {
			if v, ok := st["vocabularyCorrectionEnabled"].(bool); ok {
				vocabCorr = v
			}
			if v, ok := st["recurringSpeakerMatching"].(bool); ok {
				recMatch = v
			}
			if v, ok := st["diarizationEnabled"].(bool); ok {
				diarOn = v
			}
		}
	}

	var inferred []transcription.Segment
	started := time.Now()
	var preprocessSec *float64

	if r.TestTranscribeFn != nil {
		var err error
		inferred, err = r.TestTranscribeFn(ctx, ck.id, ck.temporaryPath.String, ck.channelLayout, vocab, vocabCorr)
		if err != nil {
			return err
		}
	} else {
		prov, err := r.Providers.TranscriptionProvider(ctx)
		if err != nil || prov == nil || !prov.Ready() {
			reason := "Transcription provider is not configured."
			if prov != nil {
				reason = prov.NotReadyReason()
			}
			return &transcription.ProviderError{Code: "TRANSCRIPTION_NOT_CONFIGURED", Message: reason, Retryable: true}
		}
		if r.Usage != nil && prov.Metered() {
			secs := usage.TranscriptionSecondsFor(ck.durationMs)
			_, release, uerr := r.Usage.Enforce(ctx, ck.userID, "transcription", secs)
			if uerr != nil {
				return uerr
			}
			defer release()
		}
		key, err := r.MasterKey()
		if err != nil {
			return err
		}
		plainBytes, err := crypto.ReadSealedFile(key, ck.temporaryPath.String)
		if err != nil {
			return &codedErr{code: "AUDIO_REUPLOAD_REQUIRED", msg: "Audio file unreadable.", retryable: false}
		}
		ext := filepath.Ext(ck.temporaryPath.String)
		if ext == "" {
			ext = ".bin"
		}
		plainFile := filepath.Join(c.Paths.AudioWork, ck.id+ext)
		if err := os.WriteFile(plainFile, plainBytes, 0o600); err != nil {
			return err
		}
		defer os.Remove(plainFile)

		procCfg := r.Proc.Get(ctx)
		ff := transcription.ResolveFFmpegPath()
		prep := transcription.PreparePreprocess(ctx, ff, c, plainFile, ck.channelLayout, ck.durationMs, r.Log)
		if prep.Cleanup != nil {
			defer prep.Cleanup()
		}
		if prep.Seconds > 0 {
			sv := prep.Seconds
			preprocessSec = &sv
		}
		sttPath := plainFile
		if prep.Filename != "" {
			sttPath = prep.Filename
		}

		// Local VAD & Diarization when models are installed
		var analysis transcription.AnalysisResult
		if r.LocalAnalyzer != nil && r.LocalAnalyzer.Available() {
			anPath := plainFile
			if procCfg.AudioPreprocessEnabled && c.AudioPreprocessTarget == "stt+analysis" && prep.Filename != "" {
				anPath = prep.Filename
			}
			if aRes, aerr := r.LocalAnalyzer.Analyze(ctx, anPath); aerr == nil {
				analysis = aRes
			}
		}
		if analysis.Analyzed && !analysis.HasSpeech {
			inferred = nil
		} else {
			inferred, err = prov.Transcribe(ctx, transcription.TranscribeInput{
				Filename:                    sttPath,
				ChannelLayout:               ck.channelLayout,
				Vocabulary:                  vocab,
				VocabularyCorrectionEnabled: vocabCorr,
			})
			if err != nil {
				return err
			}
			if diarOn && analysis.Analyzed && len(analysis.Turns) > 0 {
				inferred = transcription.AlignSegments(inferred, analysis.Turns)
			}
		}
		if r.Usage != nil && prov.Metered() {
			_ = r.Usage.RecordTranscription(ctx, ck.userID, ck.id, ck.durationMs)
		}
	}

	procCfg := r.Proc.Get(ctx)
	compacted := transcription.CompactSegments(inferred, transcription.QualityOptions{
		MinimumRepeats:        procCfg.TranscriptRepetitionMinimumRepeats,
		MaximumPatternWords:   procCfg.TranscriptRepetitionMaxPatternWords,
		MinimumCoverage:       procCfg.TranscriptRepetitionMinimumCoverage,
		MaximumWordsPerSecond: procCfg.TranscriptMaximumWordsPerSecond,
	})
	segments := compacted.Segments

	infSecs := time.Since(started).Seconds()
	if ck.durationMs > 0 {
		_, _ = r.DB.W.ExecContext(ctx, `INSERT INTO processing_metrics (job_id, user_id, metric, value, unit) VALUES (?, ?, 'transcription_pipeline_rtf', ?, 'ratio')`,
			j.ID, ck.userID, infSecs/(float64(ck.durationMs)/1000.0))
		if preprocessSec != nil {
			_, _ = r.DB.W.ExecContext(ctx, `INSERT INTO processing_metrics (job_id, user_id, metric, value, unit) VALUES (?, ?, 'audio_preprocess_rtf', ?, 'ratio')`,
				j.ID, ck.userID, *preprocessSec/(float64(ck.durationMs)/1000.0))
		}
	}

	count, err := r.persistSegments(ctx, ck, corrStartedAt, segments)
	if err != nil {
		return err
	}
	r.capturePreviews(ctx, ck, count)
	if count > 0 && recMatch && r.Jobs != nil {
		_, _ = r.Jobs.Enqueue(ctx, jobs.EnqueueInput{
			UserID: ck.userID, ResourceType: "user", ResourceID: ck.userID,
			Type: "reconcile_speakers", Priority: 5,
		})
	}
	return r.finishCleanup(ctx, ck.id, ck.userID, ck.sessionID, ck.sourceID, ck.sequence, ck.temporaryPath.String, count)
}

func (r *Runner) capturePreviews(ctx context.Context, ck chunkRec, count int) {
	if count == 0 || r.Speakers == nil || !ck.temporaryPath.Valid || ck.temporaryPath.String == "" {
		return
	}
	_, _ = r.Speakers.CapturePreviewsFromChunk(ctx, ck.userID, ck.id, ck.temporaryPath.String, ck.channelLayout)
}

func (r *Runner) persistSegments(ctx context.Context, ck chunkRec, corrStartedAt string, inferred []transcription.Segment) (int, error) {
	c := r.cfg()
	procCfg := r.Proc.Get(ctx)
	tSess, err := timeutil.ParseISO(corrStartedAt)
	if err != nil {
		return 0, err
	}
	baseT := timeutil.AddMillis(tSess, ck.monotonicOffsetMs)

	norm := make([]transcription.Segment, len(inferred))
	for i, s := range inferred {
		s.StartMs = int(baseT.UnixMilli()) + s.StartMs // temp holder? Wait: keep ms relative or use EpochMs cleanly!
		norm[i] = s
	}

	// Fetch previous segments in same source for token deduping using epoch ms
	tx, err := r.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	prevSegs := r.previousSourceSegs(ctx, tx, ck, baseT)
	within := transcription.Dedupe(inferred, prevSegs, procCfg.DedupeTokenSimilarity, procCfg.DedupeTimeToleranceMs)

	// Convert surviving StartMs/EndMs into absolute epoch ms for cross-stream dedupe cleanly.
	absSegs := make([]transcription.Segment, len(within))
	var minMs, maxMs int64
	for i, s := range within {
		s.StartMs = int(baseT.UnixMilli()) + s.StartMs
		s.EndMs = int(baseT.UnixMilli()) + s.EndMs
		if i == 0 || int64(s.StartMs) < minMs {
			minMs = int64(s.StartMs)
		}
		if i == 0 || int64(s.EndMs) > maxMs {
			maxMs = int64(s.EndMs)
		}
		absSegs[i] = s
	}
	cross := r.crossStreamSegs(ctx, tx, ck, minMs, maxMs, int64(procCfg.DedupeTimeToleranceMs))
	cleanAbs := transcription.DedupeExactCrossStream(absSegs, cross, procCfg.DedupeTimeToleranceMs, 2)

	type canonicalRow struct {
		Start int    `json:"start"`
		End   int    `json:"end"`
		Text  string `json:"text"`
		Lang  string `json:"language,omitempty"`
	}
	canon := make([]canonicalRow, len(cleanAbs))
	for i, s := range cleanAbs {
		canon[i] = canonicalRow{Start: s.StartMs, End: s.EndMs, Text: s.Text, Lang: s.Language}
	}
	checksum := sha256JSON(canon)

	_, _ = tx.ExecContext(ctx, `UPDATE audio_chunks SET state='processing', updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, ck.id)

	recMatch := true
	if r.Settings != nil {
		if st, err := r.Settings.Get(ctx, ck.userID); err == nil {
			if v, ok := st["recurringSpeakerMatching"].(bool); ok {
				recMatch = v
			}
		}
	}
	key, _ := r.MasterKey()

	declared := speakers.ReadDeclaredSpeaker(ctx, tx, ck.sourceID)
	spkSet := make(map[int]bool)
	for _, s := range cleanAbs {
		if s.DiarizationSpeaker != nil {
			spkSet[*s.DiarizationSpeaker] = true
		}
	}
	exclusive := len(spkSet) <= 1

	continuity := make(map[string]struct {
		clusterID string
		endedAtMs int64
	})
	if ck.sequence > 0 {
		arows, _ := tx.QueryContext(ctx, `SELECT source_component, speaker_cluster_id, ended_at FROM transcript_segments
			WHERE chunk_id=(SELECT id FROM audio_chunks WHERE source_id=? AND sequence=? AND user_id=?)
			  AND speaker_cluster_id IS NOT NULL ORDER BY chunk_end_ms DESC`, ck.sourceID, ck.sequence-1, ck.userID)
		if arows != nil {
			for arows.Next() {
				var sc, cl, ea string
				if arows.Scan(&sc, &cl, &ea) == nil {
					if _, exists := continuity[sc]; !exists {
						if t, err := timeutil.ParseISO(ea); err == nil {
							continuity[sc] = struct {
								clusterID string
								endedAtMs int64
							}{cl, t.UnixMilli()}
						}
					}
				}
			}
			arows.Close()
		}
	}

	type resolvedSpk struct {
		clusterID    string
		voiceprintID string
	}
	spkCache := make(map[string]resolvedSpk)

	for _, s := range cleanAbs {
		comp := s.SourceComponent
		if comp == "" {
			comp = "combined"
		}
		var clusterPtr, vpPtr *string
		if len(s.SpeakerEmbedding) > 0 && key != nil {
			spkKey := comp + ":"
			if s.DiarizationSpeaker != nil {
				spkKey += fmt.Sprintf("%d", *s.DiarizationSpeaker)
			}
			res, ok := spkCache[spkKey]
			if !ok {
				if declared != nil {
					vp, verr := speakers.VoiceprintForDeclaredKey(ctx, tx, key, ck.userID, declared.Key, declared.Name)
					if verr == nil {
						vp, _ = speakers.ReinforceDeclared(ctx, tx, key, vp, s.SpeakerEmbedding, exclusive)
						cl, cerr := speakers.ClusterForDeclared(ctx, tx, ck.userID, ck.sessionID, vp.ID, s.SpeakerEmbedding)
						if cerr == nil {
							res = resolvedSpk{clusterID: cl.ID, voiceprintID: vp.ID}
						}
					}
				} else {
					var anch *speakers.ContinuityAnchor
					if a, exists := continuity[comp]; exists {
						anch = &speakers.ContinuityAnchor{ClusterID: a.clusterID, GapMs: max(0, s.StartMs-int(a.endedAtMs))}
					}
					durMs := max(0, s.EndMs-s.StartMs)
					if s.SpeakerSpeechMs != nil {
						durMs = *s.SpeakerSpeechMs
					}
					cl, _ := speakers.ResolveCluster(ctx, tx, procCfg, ck.userID, ck.sessionID, s.SpeakerEmbedding, anch, &durMs)
					if cl != nil {
						res.clusterID = cl.ID
						vp, _ := speakers.ResolveVoiceprint(ctx, tx, key, procCfg, ck.userID, cl.ID, s.SpeakerEmbedding, recMatch, &durMs, nil)
						if vp != nil {
							res.voiceprintID = vp.ID
						}
					}
				}
				spkCache[spkKey] = res
			}
			if res.clusterID != "" {
				cCopy := res.clusterID
				clusterPtr = &cCopy
			}
			if res.voiceprintID != "" {
				vCopy := res.voiceprintID
				vpPtr = &vCopy
			}
		}

		pubID := uuid.NewString()
		relStart := max(0, int64(s.StartMs)-baseT.UnixMilli())
		relEnd := max(relStart, int64(s.EndMs)-baseT.UnixMilli())
		startISO := timeutil.FormatISO(time.UnixMilli(int64(s.StartMs)).UTC())
		endISO := timeutil.FormatISO(time.UnixMilli(int64(s.EndMs)).UTC())
		var langNull any
		if s.Language != "" {
			langNull = s.Language
		}
		ov := 0
		if s.OverlappingSpeech {
			ov = 1
		}

		insRes, err := tx.ExecContext(ctx, `INSERT INTO transcript_segments
			(public_id, user_id, chunk_id, speaker_cluster_id, source_component, started_at, ended_at,
			 chunk_start_ms, chunk_end_ms, text, language, asr_confidence, speaker_confidence, overlapping_speech)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			pubID, ck.userID, ck.id, clusterPtr, comp, startISO, endISO, relStart, relEnd, s.Text, langNull,
			s.ASRConfidence, s.SpeakerConfidence, ov)
		if err != nil {
			return 0, err
		}
		segRowID, _ := insRes.LastInsertId()

		if clusterPtr != nil && len(s.SpeakerEmbedding) > 0 {
			qual := 1.0
			if s.OverlappingSpeech {
				qual = 0.5
			}
			_, _ = tx.ExecContext(ctx, `INSERT INTO speaker_turns
				(id, user_id, chunk_id, cluster_id, voiceprint_id, start_ms, end_ms, embedding, embedding_model, embedding_dimensions, confidence, quality, overlapping_speech)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				uuid.NewString(), ck.userID, ck.id, *clusterPtr, vpPtr, relStart, relEnd,
				transcription.VectorToBytes(s.SpeakerEmbedding), "sherpa-cam++", len(s.SpeakerEmbedding),
				s.SpeakerConfidence, qual, ov)
		}
		_, _ = embeddings.UpsertDocumentExec(ctx, tx, c.JobMaxAttempts, ck.userID, "segment", fmt.Sprintf("%d", segRowID), nil, s.Text, startISO, 0)
	}

	if recMatch {
		_, _ = speakers.CollapseSessionClustersByVoiceprint(ctx, tx, ck.userID, ck.sessionID)
	}
	_, err = tx.ExecContext(ctx, `UPDATE audio_chunks SET state='persisted_cleanup_pending', transcript_sha256=?,
		transcript_segment_count=?, persisted_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),
		error_code=NULL, error_message=NULL, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`,
		checksum, len(cleanAbs), ck.id)
	if err != nil {
		return 0, err
	}
	_ = events.EmitExec(ctx, tx, ck.userID, "chunk.persisted", "audio_chunk", ck.id, map[string]any{
		"chunkId": ck.id, "state": "persisted_cleanup_pending", "segmentCount": len(cleanAbs),
	})
	_ = norm
	return len(cleanAbs), tx.Commit()
}

func (r *Runner) previousSourceSegs(ctx context.Context, tx *sql.Tx, ck chunkRec, baseT time.Time) []transcription.Segment {
	minSeq := max(0, ck.sequence-2)
	rows, err := tx.QueryContext(ctx, `SELECT t.text, t.asr_confidence, t.started_at, t.ended_at
		FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id
		WHERE c.source_id=? AND c.sequence<? AND c.sequence>=? ORDER BY t.started_at`,
		ck.sourceID, ck.sequence, minSeq)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []transcription.Segment
	for rows.Next() {
		var txt, sa, ea string
		var conf sql.NullFloat64
		if rows.Scan(&txt, &conf, &sa, &ea) == nil {
			ts, _ := timeutil.ParseISO(sa)
			te, _ := timeutil.ParseISO(ea)
			var cPtr *float64
			if conf.Valid {
				v := conf.Float64
				cPtr = &v
			}
			out = append(out, transcription.Segment{
				Text:          txt,
				ASRConfidence: cPtr,
				StartMs:       int(ts.UnixMilli() - baseT.UnixMilli()),
				EndMs:         int(te.UnixMilli() - baseT.UnixMilli()),
			})
		}
	}
	return out
}

func (r *Runner) crossStreamSegs(ctx context.Context, tx *sql.Tx, ck chunkRec, minMs, maxMs, tolMs int64) []transcription.Segment {
	if minMs == 0 && maxMs == 0 {
		return nil
	}
	earliest := timeutil.FormatISO(time.UnixMilli(minMs - tolMs).UTC())
	latest := timeutil.FormatISO(time.UnixMilli(maxMs + tolMs).UTC())
	rows, err := tx.QueryContext(ctx, `SELECT t.text, t.started_at, t.ended_at
		FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id
		WHERE t.user_id=? AND c.source_id<>? AND t.started_at<=? AND t.ended_at>=?
		ORDER BY t.started_at`, ck.userID, ck.sourceID, latest, earliest)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []transcription.Segment
	for rows.Next() {
		var txt, sa, ea string
		if rows.Scan(&txt, &sa, &ea) == nil {
			ts, _ := timeutil.ParseISO(sa)
			te, _ := timeutil.ParseISO(ea)
			out = append(out, transcription.Segment{
				Text:    txt,
				StartMs: int(ts.UnixMilli()),
				EndMs:   int(te.UnixMilli()),
			})
		}
	}
	return out
}

func (r *Runner) finishCleanup(ctx context.Context, chunkID, userID, sessionID, sourceID string, seq int, tempPath string, segCount int) error {
	if r.Cloud != nil && tempPath != "" {
		_ = r.Cloud.StageAudio(ctx, cloud.AudioChunkInfo{
			ID: chunkID, UserID: userID, SessionID: sessionID, SourceID: sourceID,
			Sequence: seq, TemporaryPath: tempPath,
		})
	}
	if tempPath != "" {
		if err := ingest.UnlinkStrict(tempPath); err != nil {
			_, _ = r.Jobs.Enqueue(ctx, jobs.EnqueueInput{
				UserID: userID, ResourceType: "audio_chunk", ResourceID: chunkID,
				Type: "cleanup_chunk_audio", Priority: 110,
			})
			return nil
		}
	}

	tx, err := r.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, _ = tx.ExecContext(ctx, `UPDATE audio_chunks SET temporary_path=NULL WHERE id=?`, chunkID)
	termState := "silent"
	if segCount > 0 {
		termState = "transcribed"
	}
	receipt, err := ingest.CompleteTerminalTx(ctx, tx, chunkID, termState, timeutil.NowISO())
	if err != nil {
		return err
	}
	updateContiguousTx(ctx, tx, sourceID)
	_ = events.EmitExec(ctx, tx, userID, "chunk.terminal", "audio_chunk", chunkID, receipt)
	if segCount > 0 {
		_, _ = jobs.EnqueueTx(ctx, tx, jobs.EnqueueInput{
			UserID: userID, ResourceType: "user", ResourceID: userID,
			Type: "detect_boundaries", Priority: 10,
		}, r.cfg().JobMaxAttempts)
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	if r.Imports != nil {
		_, _ = r.Imports.ReconcileProcessing(ctx)
	}
	return nil
}

func updateContiguousTx(ctx context.Context, tx *sql.Tx, sourceID string) {
	term := make(map[int]bool)
	maxSeq := -1
	rows, _ := tx.QueryContext(ctx, `SELECT sequence, state FROM audio_chunks WHERE source_id=?`, sourceID)
	if rows != nil {
		for rows.Next() {
			var seq int
			var st string
			if rows.Scan(&seq, &st) == nil {
				term[seq] = ingest.TerminalStates[st]
				if seq > maxSeq {
					maxSeq = seq
				}
			}
		}
		rows.Close()
	}
	type gap struct{ s, e int }
	var gaps []gap
	grows, _ := tx.QueryContext(ctx, `SELECT start_sequence, end_sequence FROM recording_gaps WHERE source_id=? AND start_sequence IS NOT NULL`, sourceID)
	if grows != nil {
		for grows.Next() {
			var g gap
			if grows.Scan(&g.s, &g.e) == nil {
				gaps = append(gaps, g)
				if g.e > maxSeq {
					maxSeq = g.e
				}
			}
		}
		grows.Close()
	}
	contiguous := -1
	for s := 0; s <= maxSeq; s++ {
		ok := term[s]
		if !ok {
			for _, g := range gaps {
				if s >= g.s && s <= g.e {
					ok = true
					break
				}
			}
		}
		if !ok {
			break
		}
		contiguous = s
	}
	_, _ = tx.ExecContext(ctx, `UPDATE recording_sources SET contiguous_terminal_sequence=? WHERE id=?`, contiguous, sourceID)
	_ = processing.Settings{}
	_ = strings.TrimSpace
	_ = json.Marshal
}
