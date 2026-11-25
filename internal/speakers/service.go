package speakers

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/processing"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

const resolutionBatch = 200

type Service struct {
	DB         *dbx.DB
	Cfg        func() config.Config
	MasterKey  func() ([]byte, error)
	Proc       *processing.Service
	Jobs       *jobs.Service
	FFmpegPath string
	Log        *slog.Logger
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func (s *Service) userRecurringMatching(ctx context.Context, userID string) bool {
	var v sql.NullInt64
	if err := s.DB.R.QueryRowContext(ctx, `SELECT recurring_speaker_matching FROM user_settings WHERE user_id=?`, userID).Scan(&v); err == nil && v.Valid {
		return v.Int64 != 0
	}
	return true
}

type ListedSpeaker struct {
	ID                string  `json:"id"`
	DisplayName       *string `json:"display_name"`
	EmbeddingModel    string  `json:"embedding_model"`
	SampleCount       int     `json:"sample_count"`
	MatchingEnabled   int     `json:"matching_enabled"`
	CreatedAt         string  `json:"created_at"`
	UpdatedAt         string  `json:"updated_at"`
	OccurrenceCount   int     `json:"occurrence_count"`
	TotalDurationMs   *int64  `json:"total_duration_ms"`
	PreviewDurationMs *int    `json:"preview_duration_ms"`
}

func (s *Service) List(ctx context.Context, userID string) ([]ListedSpeaker, error) {
	minPreview := s.cfg().SpeakerDisplayMinPreviewMs
	rows, err := s.DB.R.QueryContext(ctx, `SELECT v.id, v.display_name, v.embedding_model, v.sample_count,
		v.matching_enabled, v.created_at, v.updated_at,
		(SELECT COUNT(*) FROM speaker_turns st WHERE st.voiceprint_id=v.id) AS occurrence_count,
		(SELECT SUM(end_ms - start_ms) FROM speaker_turns st WHERE st.voiceprint_id=v.id) AS total_duration_ms,
		CASE WHEN p.duration_ms>=? THEN p.duration_ms END AS preview_duration_ms
		FROM voiceprints v
		LEFT JOIN speaker_previews p ON p.voiceprint_id=v.id
		WHERE v.user_id=? AND (p.duration_ms>=? OR v.external_key IS NOT NULL)
		ORDER BY COALESCE(v.display_name,''), v.created_at`, minPreview, userID, minPreview)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ListedSpeaker{}
	for rows.Next() {
		var sp ListedSpeaker
		if err := rows.Scan(&sp.ID, &sp.DisplayName, &sp.EmbeddingModel, &sp.SampleCount,
			&sp.MatchingEnabled, &sp.CreatedAt, &sp.UpdatedAt, &sp.OccurrenceCount, &sp.TotalDurationMs, &sp.PreviewDurationMs); err != nil {
			return nil, err
		}
		out = append(out, sp)
	}
	return out, rows.Err()
}

func (s *Service) getOwned(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, userID, id string) (VoiceprintRow, error) {
	vp, err := scanVoiceprint(q.QueryRowContext(ctx, `SELECT `+voiceprintCols+` FROM voiceprints WHERE id=? AND user_id=?`, id, userID))
	if errors.Is(err, sql.ErrNoRows) {
		return VoiceprintRow{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Speaker not found.")
	}
	return vp, err
}

func (s *Service) Update(ctx context.Context, userID, id string, hasDisplayName bool, displayName *string, matchingEnabled *bool) (VoiceprintRow, error) {
	cur, err := s.getOwned(ctx, s.DB.R, userID, id)
	if err != nil {
		return VoiceprintRow{}, err
	}
	nextDN := cur.DisplayName
	nextDNS := cur.DisplayNameSource
	if hasDisplayName {
		if displayName == nil {
			nextDN = nil
			nextDNS = nil
		} else {
			cp := *displayName
			src := "manual"
			nextDN = &cp
			nextDNS = &src
		}
	}
	var meNull sql.NullInt64
	if matchingEnabled != nil {
		v := int64(0)
		if *matchingEnabled {
			v = 1
		}
		meNull = sql.NullInt64{Int64: v, Valid: true}
	}
	if _, err := s.DB.W.ExecContext(ctx, `UPDATE voiceprints SET display_name=?, display_name_source=?,
		matching_enabled=COALESCE(?, matching_enabled), updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE id=? AND user_id=?`, nextDN, nextDNS, meNull, id, userID); err != nil {
		return VoiceprintRow{}, err
	}
	return s.getOwned(ctx, s.DB.R, userID, id)
}

func mergeTx(ctx context.Context, tx SQLExecQueryer, key []byte, minPreviewMs int, userID, targetID, sourceID string) error {
	if targetID == sourceID {
		return httperr.New(http.StatusBadRequest, "INVALID_MERGE", "A speaker cannot be merged with itself.")
	}
	readOwned := func(id string) (VoiceprintRow, error) {
		vp, err := scanVoiceprint(tx.QueryRowContext(ctx, `SELECT `+voiceprintCols+` FROM voiceprints WHERE id=? AND user_id=?`, id, userID))
		if errors.Is(err, sql.ErrNoRows) {
			return VoiceprintRow{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Speaker not found.")
		}
		return vp, err
	}
	target, err := readOwned(targetID)
	if err != nil {
		return err
	}
	source, err := readOwned(sourceID)
	if err != nil {
		return err
	}
	if target.EmbeddingModel != source.EmbeddingModel || target.EmbeddingDimensions != source.EmbeddingDimensions {
		return httperr.New(http.StatusConflict, "MODEL_MISMATCH", "Speaker profiles use incompatible embedding models.")
	}
	left, err := ReadCentroid(key, target.CentroidEmbedding)
	if err != nil {
		return err
	}
	right, err := ReadCentroid(key, source.CentroidEmbedding)
	if err != nil {
		return err
	}
	left = transcription.NormalizeVector(left)
	right = transcription.NormalizeVector(right)
	if len(left) != len(right) {
		return httperr.New(http.StatusConflict, "MODEL_MISMATCH", "Speaker profiles use incompatible embedding models.")
	}
	total := target.SampleCount + source.SampleCount
	outVec := make([]float32, len(left))
	if total > 0 {
		for i := range left {
			outVec[i] = (left[i]*float32(target.SampleCount) + right[i]*float32(source.SampleCount)) / float32(total)
		}
	}
	sealedCentroid, err := SealCentroid(key, transcription.NormalizeVector(outVec))
	if err != nil {
		return err
	}

	rows, err := tx.QueryContext(ctx, `SELECT DISTINCT conversation_id FROM transcript_segments WHERE user_id=? AND conversation_id IS NOT NULL AND speaker_cluster_id IN (SELECT cluster_id FROM conversation_speakers WHERE voiceprint_id IN (?,?))
		UNION SELECT DISTINCT conversation_id FROM conversation_speakers WHERE voiceprint_id IN (?,?)`, targetID, sourceID, targetID, sourceID)
	if err != nil {
		return err
	}
	var affected []string
	for rows.Next() {
		var cid string
		if rows.Scan(&cid) == nil {
			affected = append(affected, cid)
		}
	}
	rows.Close()

	var tDur int
	var tQual float64
	tErr := tx.QueryRowContext(ctx, `SELECT duration_ms, quality FROM speaker_previews WHERE voiceprint_id=?`, targetID).Scan(&tDur, &tQual)
	var sAudio []byte
	var sCT, sCreated, sUpdated string
	var sDur int
	var sQual float64
	sErr := tx.QueryRowContext(ctx, `SELECT audio, content_type, duration_ms, quality, created_at, updated_at FROM speaker_previews WHERE voiceprint_id=?`, sourceID).
		Scan(&sAudio, &sCT, &sDur, &sQual, &sCreated, &sUpdated)
	if sErr == nil {
		replace := errors.Is(tErr, sql.ErrNoRows) || (tErr == nil && ShouldReplacePreview(tDur, tQual, sDur, sQual, minPreviewMs))
		if replace {
			if _, err := tx.ExecContext(ctx, `INSERT INTO speaker_previews
				(voiceprint_id, user_id, audio, content_type, duration_ms, quality, created_at, updated_at)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?)
				ON CONFLICT(voiceprint_id) DO UPDATE SET
					audio=excluded.audio, content_type=excluded.content_type, duration_ms=excluded.duration_ms,
					quality=excluded.quality, updated_at=excluded.updated_at`,
				targetID, userID, sAudio, sCT, sDur, sQual, sCreated, sUpdated); err != nil {
				return err
			}
		}
	}

	if _, err := tx.ExecContext(ctx, `UPDATE speaker_turns SET voiceprint_id=? WHERE voiceprint_id=? AND user_id=?`, targetID, sourceID, userID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE conversation_speakers SET voiceprint_id=? WHERE voiceprint_id=?`, targetID, sourceID); err != nil {
		return err
	}
	mergedName := target.DisplayName
	mergedSource := target.DisplayNameSource
	if mergedName == nil && source.DisplayName != nil {
		mergedName = source.DisplayName
		mergedSource = source.DisplayNameSource
	}
	var srcEID sql.NullString
	if source.EntityID != nil {
		srcEID = sql.NullString{String: *source.EntityID, Valid: true}
	}
	if _, err := tx.ExecContext(ctx, `UPDATE voiceprints SET centroid_embedding=?, sample_count=?, display_name=?, display_name_source=?,
		entity_id=COALESCE(entity_id, ?), updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`,
		sealedCentroid, total, mergedName, mergedSource, srcEID, targetID, userID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM voiceprints WHERE id=? AND user_id=?`, sourceID, userID); err != nil {
		return err
	}
	for _, cid := range affected {
		if err := RebuildConversationSpeakers(ctx, tx, userID, cid); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) Merge(ctx context.Context, userID, targetID, sourceID string) (VoiceprintRow, error) {
	key, err := s.MasterKey()
	if err != nil {
		return VoiceprintRow{}, err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return VoiceprintRow{}, err
	}
	defer tx.Rollback()
	if err := mergeTx(ctx, tx, key, s.cfg().SpeakerDisplayMinPreviewMs, userID, targetID, sourceID); err != nil {
		return VoiceprintRow{}, err
	}
	if err := tx.Commit(); err != nil {
		return VoiceprintRow{}, err
	}
	return s.getOwned(ctx, s.DB.R, userID, targetID)
}

func (s *Service) MergeMany(ctx context.Context, userID, targetID string, sourceIDs []string) (VoiceprintRow, error) {
	seen := map[string]bool{targetID: true}
	var unique []string
	for _, sid := range sourceIDs {
		if !seen[sid] {
			seen[sid] = true
			unique = append(unique, sid)
		}
	}
	if len(unique) == 0 {
		return VoiceprintRow{}, httperr.New(http.StatusBadRequest, "INVALID_MERGE", "Select at least one other speaker to combine.")
	}
	var out VoiceprintRow
	var err error
	for _, sid := range unique {
		out, err = s.Merge(ctx, userID, targetID, sid)
		if err != nil {
			return VoiceprintRow{}, err
		}
	}
	return out, nil
}

type MergeRecord struct {
	TargetID   string  `json:"targetId"`
	SourceID   string  `json:"sourceId"`
	Similarity float64 `json:"similarity"`
}

type ReevaluateResult struct {
	MergedCount    int           `json:"mergedCount"`
	RemainingCount int           `json:"remainingCount"`
	Merges         []MergeRecord `json:"merges"`
}

func sameExplicitIdentity(a, b VoiceprintRow) bool {
	if a.EntityID != nil && b.EntityID != nil && *a.EntityID != *b.EntityID {
		return false
	}
	var an, bn string
	if a.DisplayName != nil {
		an = strings.TrimSpace(*a.DisplayName)
	}
	if b.DisplayName != nil {
		bn = strings.TrimSpace(*b.DisplayName)
	}
	return an == "" || bn == "" || an == bn
}

type peerPair struct {
	first  VoiceprintRow
	second VoiceprintRow
	score  float64
}

func reevaluationPairs(key []byte, rows []VoiceprintRow, limits processing.Settings, repair bool) []peerPair {
	floor := limits.VoiceMatchThreshold
	if repair {
		floor = min(limits.VoiceRepairThreshold, limits.VoiceMatchThreshold)
	}
	isolated := make(map[string]bool)
	matches := make(map[string]VoiceprintScore)
	for _, r := range rows {
		c, err := ReadCentroid(key, r.CentroidEmbedding)
		if err != nil || len(c) == 0 {
			continue
		}
		var peerRows []VoiceprintRow
		for _, cand := range rows {
			if cand.ID != r.ID && cand.EmbeddingModel == r.EmbeddingModel && cand.EmbeddingDimensions == r.EmbeddingDimensions {
				peerRows = append(peerRows, cand)
			}
		}
		ranked := RankVoiceprints(key, c, peerRows)
		if len(ranked) == 0 || !sameExplicitIdentity(r, ranked[0].Row) || ranked[0].Score < floor {
			continue
		}
		isIso := len(ranked) < 2 || ranked[0].Score-ranked[1].Score >= limits.VoiceMatchMargin
		isolated[r.ID] = isIso
		if ranked[0].Score >= limits.VoiceMatchThreshold || isIso {
			matches[r.ID] = ranked[0]
		}
	}
	var pairs []peerPair
	for _, r := range rows {
		m, ok := matches[r.ID]
		if !ok {
			continue
		}
		rev, okRev := matches[m.Row.ID]
		if !okRev || rev.Row.ID != r.ID || r.ID > m.Row.ID {
			continue
		}
		if m.Score < limits.VoiceMatchThreshold && !(isolated[r.ID] && isolated[m.Row.ID]) {
			continue
		}
		pairs = append(pairs, peerPair{first: r, second: m.Row, score: m.Score})
	}
	return pairs
}

func preferredMergeTarget(a, b VoiceprintRow) VoiceprintRow {
	aNamed := a.DisplayName != nil && strings.TrimSpace(*a.DisplayName) != ""
	bNamed := b.DisplayName != nil && strings.TrimSpace(*b.DisplayName) != ""
	if aNamed != bNamed {
		if aNamed {
			return a
		}
		return b
	}
	if a.SampleCount != b.SampleCount {
		if a.SampleCount > b.SampleCount {
			return a
		}
		return b
	}
	if a.CreatedAt <= b.CreatedAt {
		return a
	}
	return b
}

func (s *Service) Reevaluate(ctx context.Context, userID string, repair bool) (ReevaluateResult, error) {
	key, err := s.MasterKey()
	if err != nil {
		return ReevaluateResult{}, err
	}
	limits := s.Proc.Get(ctx)
	minPreview := s.cfg().SpeakerDisplayMinPreviewMs

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return ReevaluateResult{}, err
	}
	defer tx.Rollback()

	merges := []MergeRecord{}
	for {
		rows, err := tx.QueryContext(ctx, `SELECT `+voiceprintCols+` FROM voiceprints
			WHERE user_id=? AND matching_enabled=1 AND centroid_embedding IS NOT NULL`, userID)
		if err != nil {
			return ReevaluateResult{}, err
		}
		var vps []VoiceprintRow
		for rows.Next() {
			if vp, err := scanVoiceprint(rows); err == nil {
				vps = append(vps, vp)
			}
		}
		rows.Close()
		pairs := reevaluationPairs(key, vps, limits, repair)
		if len(pairs) == 0 {
			break
		}
		for _, p := range pairs {
			target := preferredMergeTarget(p.first, p.second)
			source := p.second
			if target.ID != p.first.ID {
				source = p.first
			}
			if err := mergeTx(ctx, tx, key, minPreview, userID, target.ID, source.ID); err != nil {
				return ReevaluateResult{}, err
			}
			merges = append(merges, MergeRecord{TargetID: target.ID, SourceID: source.ID, Similarity: p.score})
		}
	}
	var rem int
	_ = tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM voiceprints WHERE user_id=?`, userID).Scan(&rem)
	if err := tx.Commit(); err != nil {
		return ReevaluateResult{}, err
	}
	return ReevaluateResult{MergedCount: len(merges), RemainingCount: rem, Merges: merges}, nil
}

func (s *Service) queueResolution(ctx context.Context, userID string, convIDs []string) int {
	if s.Jobs == nil {
		return 0
	}
	queued := 0
	for _, cid := range convIDs {
		if _, err := s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
			UserID: userID, ResourceType: "conversation", ResourceID: cid, Type: "resolve_speakers", Priority: 30,
		}); err == nil {
			queued++
		}
	}
	return queued
}

func (s *Service) RequestConversationResolution(ctx context.Context, userID string) int {
	since := timeutil.FormatISO(time.Now().Add(-time.Duration(max(1, s.cfg().SpeakerRedetectDays)) * 24 * time.Hour))
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id FROM conversations
		WHERE user_id=? AND state<>'open' AND ended_at>=? ORDER BY ended_at DESC LIMIT ?`, userID, since, resolutionBatch)
	if err != nil {
		return 0
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	return s.queueResolution(ctx, userID, ids)
}

func (s *Service) SweepUnresolvedConversations(ctx context.Context, userID string) int {
	since := timeutil.FormatISO(time.Now().Add(-time.Duration(max(1, s.cfg().SpeakerRedetectDays)) * 24 * time.Hour))
	limits := s.Proc.Get(ctx)
	sig, err := WorldSignature(ctx, s.DB.R, limits, s.userRecurringMatching(ctx, userID), userID)
	if err != nil {
		return 0
	}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT c.id FROM conversations c
		WHERE c.user_id=? AND c.state<>'open' AND c.ended_at>=?
		  AND EXISTS (SELECT 1 FROM transcript_segments t JOIN speaker_turns st
			ON st.chunk_id=t.chunk_id AND st.cluster_id=t.speaker_cluster_id
			WHERE t.conversation_id=c.id AND st.voiceprint_id IS NULL)
		  AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.type='resolve_speakers' AND j.resource_id=c.id
			AND j.status IN ('queued','leased'))
		  AND NOT EXISTS (SELECT 1 FROM conversation_speaker_resolutions r
			WHERE r.conversation_id=c.id AND r.world_signature=?
			  AND r.evidence_turns=(`+EvidenceTurnsSQL("c.id")+`)
			  AND r.unresolved_turns=(`+UnresolvedTurnsSQL("c.id")+`))
		ORDER BY c.ended_at DESC LIMIT ?`, userID, since, sig, resolutionBatch)
	if err != nil {
		return 0
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	return s.queueResolution(ctx, userID, ids)
}

func (s *Service) BulkRemove(ctx context.Context, userID string, ids []string) (map[string]any, error) {
	seen := make(map[string]bool)
	var unique []string
	var args []any
	args = append(args, userID)
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			unique = append(unique, id)
			args = append(args, id)
		}
	}
	var cnt int
	if err := s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM voiceprints WHERE user_id=? AND id IN (`+placeholders(len(unique))+`)`, args...).Scan(&cnt); err != nil {
		return nil, err
	}
	if cnt != len(unique) {
		return nil, httperr.New(http.StatusNotFound, "NOT_FOUND", "One or more speakers were not found.")
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	for _, id := range unique {
		if _, err := tx.ExecContext(ctx, `DELETE FROM voiceprints WHERE id=? AND user_id=?`, id, userID); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return map[string]any{"action": "delete", "count": len(unique), "ids": unique}, nil
}

func (s *Service) Assign(ctx context.Context, userID, voiceprintID string, turnIDs []string) (int, error) {
	if _, err := s.getOwned(ctx, s.DB.R, userID, voiceprintID); err != nil {
		return 0, err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	changed := 0
	for _, tid := range turnIDs {
		res, err := tx.ExecContext(ctx, `UPDATE speaker_turns SET voiceprint_id=? WHERE id=? AND user_id=?`, voiceprintID, tid, userID)
		if err != nil {
			return 0, err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			changed += int(n)
		}
	}
	if changed != len(turnIDs) {
		return 0, httperr.New(http.StatusNotFound, "NOT_FOUND", "One or more speaker turns were not found.")
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return changed, nil
}

func (s *Service) Remove(ctx context.Context, userID, id string) error {
	res, err := s.DB.W.ExecContext(ctx, `DELETE FROM voiceprints WHERE id=? AND user_id=?`, id, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httperr.New(http.StatusNotFound, "NOT_FOUND", "Speaker not found.")
	}
	return nil
}

// RebuildAffectedVoiceprints recalculates voiceprint centroids excluding a deleted session.
func (s *Service) RebuildAffectedVoiceprints(ctx context.Context, tx SQLExecQueryer, key []byte, userID, sessionID string) error {
	rows, err := tx.QueryContext(ctx, `SELECT DISTINCT st.voiceprint_id FROM speaker_turns st JOIN audio_chunks c ON c.id=st.chunk_id
		WHERE c.session_id=? AND st.user_id=? AND st.voiceprint_id IS NOT NULL`, sessionID, userID)
	if err != nil {
		return err
	}
	var vpIDs []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			vpIDs = append(vpIDs, id)
		}
	}
	rows.Close()

	for _, vpID := range vpIDs {
		erows, err := tx.QueryContext(ctx, `SELECT st.embedding FROM speaker_turns st JOIN audio_chunks c ON c.id=st.chunk_id
			WHERE st.voiceprint_id=? AND st.user_id=? AND c.session_id<>? AND st.embedding IS NOT NULL`, vpID, userID, sessionID)
		if err != nil {
			return err
		}
		var vecs [][]float32
		for erows.Next() {
			var b []byte
			if erows.Scan(&b) == nil && len(b) > 0 {
				if v := transcription.VectorFromBytes(b); len(v) > 0 {
					vecs = append(vecs, v)
				}
			}
		}
		erows.Close()

		if len(vecs) == 0 {
			if _, err := tx.ExecContext(ctx, `DELETE FROM voiceprints WHERE id=? AND user_id=?`, vpID, userID); err != nil {
				return err
			}
			continue
		}
		dim := len(vecs[0])
		mean := make([]float32, dim)
		cnt := 0
		for _, v := range vecs {
			if len(v) != dim {
				continue
			}
			cnt++
			for i := range dim {
				mean[i] += v[i]
			}
		}
		if cnt == 0 {
			if _, err := tx.ExecContext(ctx, `DELETE FROM voiceprints WHERE id=? AND user_id=?`, vpID, userID); err != nil {
				return err
			}
			continue
		}
		for i := range dim {
			mean[i] /= float32(cnt)
		}
		sealed, err := SealCentroid(key, mean)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE voiceprints SET centroid_embedding=?, sample_count=?,
			updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`, sealed, cnt, vpID, userID); err != nil {
			return err
		}
	}
	return nil
}
