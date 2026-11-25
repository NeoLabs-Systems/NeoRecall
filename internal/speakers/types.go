package speakers

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
)

const ModelName = "wespeaker_en_voxceleb_CAM++_LM"

type VoiceprintRow struct {
	ID                  string  `json:"id"`
	UserID              string  `json:"user_id"`
	ExternalKey         *string `json:"external_key,omitempty"`
	EntityID            *string `json:"entity_id,omitempty"`
	DisplayName         *string `json:"display_name"`
	DisplayNameSource   *string `json:"display_name_source,omitempty"`
	CentroidEmbedding   []byte  `json:"-"`
	EmbeddingModel      string  `json:"embedding_model"`
	EmbeddingDimensions int     `json:"-"`
	SampleCount         int     `json:"sample_count"`
	MatchingEnabled     bool    `json:"matching_enabled"`
	CreatedAt           string  `json:"created_at"`
	UpdatedAt           string  `json:"updated_at"`
}

type ClusterRow struct {
	ID                  string
	UserID              string
	SessionID           string
	LocalOrdinal        int
	CentroidEmbedding   []byte
	EmbeddingModel      string
	EmbeddingDimensions int
	SampleCount         int
	CreatedAt           string
	UpdatedAt           string
}

const voiceprintCols = `id, user_id, external_key, entity_id, display_name, display_name_source,
	centroid_embedding, embedding_model, embedding_dimensions, sample_count, matching_enabled, created_at, updated_at`

func scanVoiceprint(q interface{ Scan(...any) error }) (VoiceprintRow, error) {
	var r VoiceprintRow
	var ek, eid, dn, dns sql.NullString
	var me int
	err := q.Scan(&r.ID, &r.UserID, &ek, &eid, &dn, &dns, &r.CentroidEmbedding,
		&r.EmbeddingModel, &r.EmbeddingDimensions, &r.SampleCount, &me, &r.CreatedAt, &r.UpdatedAt)
	if err != nil {
		return VoiceprintRow{}, err
	}
	if ek.Valid {
		r.ExternalKey = &ek.String
	}
	if eid.Valid {
		r.EntityID = &eid.String
	}
	if dn.Valid {
		r.DisplayName = &dn.String
	}
	if dns.Valid {
		r.DisplayNameSource = &dns.String
	}
	r.MatchingEnabled = me != 0
	return r, nil
}

const clusterCols = `id, user_id, session_id, local_ordinal, centroid_embedding, embedding_model, embedding_dimensions, sample_count, created_at, updated_at`

func scanCluster(q interface{ Scan(...any) error }) (ClusterRow, error) {
	var c ClusterRow
	err := q.Scan(&c.ID, &c.UserID, &c.SessionID, &c.LocalOrdinal, &c.CentroidEmbedding,
		&c.EmbeddingModel, &c.EmbeddingDimensions, &c.SampleCount, &c.CreatedAt, &c.UpdatedAt)
	return c, err
}

type DBRunner = dbx.DB

// sqlExecQueryer accepts *sql.Tx, *sql.DB, or sqlx handles inside/outside transactions.
type SQLExecQueryer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// RebuildConversationSpeakers rebuilds per-conversation local speaker labels
// ("Speaker 1", "Speaker 2", ...) collapsing clusters resolved to the same voiceprint.
func RebuildConversationSpeakers(ctx context.Context, db SQLExecQueryer, userID, conversationID string) error {
	if _, err := db.ExecContext(ctx, `DELETE FROM conversation_speakers WHERE conversation_id=?`, conversationID); err != nil {
		return err
	}
	rows, err := db.QueryContext(ctx, `SELECT t.speaker_cluster_id AS cluster_id,
		(SELECT st.voiceprint_id FROM speaker_turns st
			WHERE st.cluster_id=t.speaker_cluster_id AND st.user_id=t.user_id AND st.voiceprint_id IS NOT NULL
			GROUP BY st.voiceprint_id ORDER BY COUNT(*) DESC, MAX(st.created_at) DESC LIMIT 1) AS voiceprint_id,
		MIN(t.started_at) AS first_seen_at
		FROM transcript_segments t
		WHERE t.conversation_id=? AND t.user_id=? AND t.speaker_cluster_id IS NOT NULL
		GROUP BY t.speaker_cluster_id
		ORDER BY first_seen_at`, conversationID, userID)
	if err != nil {
		return err
	}
	type item struct {
		clusterID    string
		voiceprintID sql.NullString
	}
	var items []item
	for rows.Next() {
		var it item
		var firstSeen sql.NullString
		if err := rows.Scan(&it.clusterID, &it.voiceprintID, &firstSeen); err != nil {
			rows.Close()
			return err
		}
		items = append(items, it)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	labels := make(map[string]string)
	for _, spk := range items {
		ident := "cluster:" + spk.clusterID
		if spk.voiceprintID.Valid && spk.voiceprintID.String != "" {
			ident = "voiceprint:" + spk.voiceprintID.String
		}
		if _, ok := labels[ident]; !ok {
			labels[ident] = fmt.Sprintf("Speaker %d", len(labels)+1)
		}
		if _, err := db.ExecContext(ctx, `INSERT INTO conversation_speakers (conversation_id, cluster_id, voiceprint_id, local_label)
			VALUES (?, ?, ?, ?)`, conversationID, spk.clusterID, spk.voiceprintID, labels[ident]); err != nil {
			return err
		}
	}
	return nil
}
