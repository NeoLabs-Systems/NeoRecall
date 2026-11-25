package speakers

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"

	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
	"github.com/google/uuid"
)

type DeclaredSpeaker struct {
	Key  string
	Name string
}

func ReadDeclaredSpeaker(ctx context.Context, db SQLExecQueryer, sourceID string) *DeclaredSpeaker {
	if sourceID == "" {
		return nil
	}
	var raw string
	if err := db.QueryRowContext(ctx, `SELECT metadata_json FROM recording_sources WHERE id=?`, sourceID).Scan(&raw); err != nil || raw == "" {
		return nil
	}
	var meta struct {
		Speaker *struct {
			Key  string `json:"key"`
			Name string `json:"name"`
		} `json:"speaker"`
	}
	if json.Unmarshal([]byte(raw), &meta) != nil || meta.Speaker == nil {
		return nil
	}
	k := strings.TrimSpace(meta.Speaker.Key)
	if k == "" {
		return nil
	}
	if len(k) > 200 {
		k = k[:200]
	}
	n := strings.TrimSpace(meta.Speaker.Name)
	if len(n) > 120 {
		n = n[:120]
	}
	return &DeclaredSpeaker{Key: k, Name: n}
}

func VoiceprintForDeclaredKey(ctx context.Context, db SQLExecQueryer, key []byte, userID, extKey, name string) (VoiceprintRow, error) {
	empty, err := SealCentroid(key, make([]float32, 1))
	if err != nil {
		return VoiceprintRow{}, err
	}
	var nameNull, sourceNull sql.NullString
	if name != "" {
		nameNull = sql.NullString{String: name, Valid: true}
		sourceNull = sql.NullString{String: "inferred", Valid: true}
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO voiceprints
		(id, user_id, external_key, display_name, display_name_source, centroid_embedding, embedding_model, embedding_dimensions, sample_count)
		VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0)
		ON CONFLICT(user_id, external_key) WHERE external_key IS NOT NULL DO NOTHING`,
		uuid.NewString(), userID, extKey, nameNull, sourceNull, empty, ModelName); err != nil {
		return VoiceprintRow{}, err
	}
	vp, err := scanVoiceprint(db.QueryRowContext(ctx, `SELECT `+voiceprintCols+` FROM voiceprints WHERE user_id=? AND external_key=?`, userID, extKey))
	if err != nil {
		return VoiceprintRow{}, err
	}
	if name != "" && (vp.DisplayName == nil || *vp.DisplayName == "") {
		_, _ = db.ExecContext(ctx, `UPDATE voiceprints SET display_name=?, display_name_source='inferred',
			updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND display_name IS NULL`, name, vp.ID)
		vp, _ = scanVoiceprint(db.QueryRowContext(ctx, `SELECT `+voiceprintCols+` FROM voiceprints WHERE id=?`, vp.ID))
	}
	return vp, nil
}

func ReinforceDeclared(ctx context.Context, db SQLExecQueryer, key []byte, vp VoiceprintRow, embedding []float32, exclusive bool) (VoiceprintRow, error) {
	if !exclusive || len(embedding) == 0 {
		return vp, nil
	}
	stored, _ := ReadCentroid(key, vp.CentroidEmbedding)
	known := len(stored) == len(embedding) && vp.SampleCount > 0
	var centroid []float32
	if known {
		centroid = transcription.UpdateCentroid(stored, vp.SampleCount, embedding)
	} else {
		centroid = transcription.NormalizeVector(embedding)
	}
	sealed, err := SealCentroid(key, centroid)
	if err != nil {
		return vp, err
	}
	if _, err := db.ExecContext(ctx, `UPDATE voiceprints SET centroid_embedding=?, embedding_model=?, embedding_dimensions=?,
		sample_count=sample_count+1, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`,
		sealed, ModelName, len(embedding), vp.ID); err != nil {
		return vp, err
	}
	return scanVoiceprint(db.QueryRowContext(ctx, `SELECT `+voiceprintCols+` FROM voiceprints WHERE id=?`, vp.ID))
}

func ClusterForDeclared(ctx context.Context, db SQLExecQueryer, userID, sessionID, voiceprintID string, embedding []float32) (ClusterRow, error) {
	c, err := scanCluster(db.QueryRowContext(ctx, `SELECT sc.id, sc.user_id, sc.session_id, sc.local_ordinal,
		sc.centroid_embedding, sc.embedding_model, sc.embedding_dimensions, sc.sample_count, sc.created_at, sc.updated_at
		FROM speaker_clusters sc
		JOIN speaker_turns st ON st.cluster_id=sc.id AND st.user_id=sc.user_id
		WHERE sc.user_id=? AND sc.session_id=? AND st.voiceprint_id=?
		GROUP BY sc.id ORDER BY COUNT(*) DESC, sc.local_ordinal LIMIT 1`, userID, sessionID, voiceprintID))
	if err == nil {
		return c, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return ClusterRow{}, err
	}
	return CreateCluster(ctx, db, userID, sessionID, embedding)
}
