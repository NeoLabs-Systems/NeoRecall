package speakers

import (
	"context"
	"database/sql"
	"math"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

const MaximumMeasurements = 32

type TimeSpan struct {
	StartMs  int64
	EndMs    int64
	SourceID string
}

type ClusterEvidence struct {
	ID            string
	SessionID     string
	Embeddings    [][]float32
	Spans         []TimeSpan
	SpeechMs      int
	VoiceprintIDs map[string]bool
	DeclaredKeys  map[string]bool
}

func sampleEmbeddings(embs [][]float32) [][]float32 {
	if len(embs) <= MaximumMeasurements {
		return embs
	}
	step := float64(len(embs)) / float64(MaximumMeasurements)
	picked := make([][]float32, 0, MaximumMeasurements)
	for i := range MaximumMeasurements {
		idx := min(len(embs)-1, int(math.Floor(float64(i)*step)))
		picked = append(picked, embs[idx])
	}
	return picked
}

const turnsForConversationSQL = `SELECT DISTINCT st.id, st.cluster_id, st.embedding, st.voiceprint_id,
	st.start_ms, st.end_ms, st.overlapping_speech,
	c.session_id, c.source_id, c.monotonic_offset_ms,
	r.corrected_started_at,
	json_extract(rs.metadata_json, '$.speaker.key') AS declared_key
	FROM transcript_segments t
	JOIN speaker_turns st ON st.chunk_id=t.chunk_id AND st.cluster_id=t.speaker_cluster_id
		AND st.start_ms<=t.chunk_start_ms AND st.end_ms>=t.chunk_end_ms
	JOIN audio_chunks c ON c.id=t.chunk_id
	JOIN recording_sessions r ON r.id=c.session_id
	JOIN recording_sources rs ON rs.id=c.source_id
	WHERE t.conversation_id=? AND t.user_id=? AND t.speaker_cluster_id IS NOT NULL`

func CollectEvidence(ctx context.Context, db *dbx.DB, userID, conversationID string) ([]*ClusterEvidence, error) {
	rows, err := db.R.QueryContext(ctx, turnsForConversationSQL, conversationID, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var order []*ClusterEvidence
	byCluster := make(map[string]*ClusterEvidence)
	for rows.Next() {
		var turnID, clusterID, sessionID, sourceID, corrStartedAt string
		var emb []byte
		var vpID, declKey sql.NullString
		var startMs, endMs int
		var overlapInt int
		var monoOffMs int64
		if err := rows.Scan(&turnID, &clusterID, &emb, &vpID, &startMs, &endMs, &overlapInt,
			&sessionID, &sourceID, &monoOffMs, &corrStartedAt, &declKey); err != nil {
			return nil, err
		}
		item, ok := byCluster[clusterID]
		if !ok {
			item = &ClusterEvidence{
				ID:            clusterID,
				SessionID:     sessionID,
				VoiceprintIDs: make(map[string]bool),
				DeclaredKeys:  make(map[string]bool),
			}
			byCluster[clusterID] = item
			order = append(order, item)
		}
		var baseMs int64
		if parsed, err := timeutil.ParseISO(corrStartedAt); err == nil {
			baseMs = parsed.UnixMilli()
		}
		baseMs += monoOffMs
		item.Spans = append(item.Spans, TimeSpan{
			StartMs:  baseMs + int64(startMs),
			EndMs:    baseMs + int64(endMs),
			SourceID: sourceID,
		})
		if endMs > startMs {
			item.SpeechMs += endMs - startMs
		}
		if vpID.Valid && vpID.String != "" {
			item.VoiceprintIDs[vpID.String] = true
		}
		if declKey.Valid && declKey.String != "" {
			item.DeclaredKeys[declKey.String] = true
		}
		if overlapInt != 0 || len(emb) == 0 {
			continue
		}
		vec := transcription.VectorFromBytes(emb)
		dup := false
		for _, ex := range item.Embeddings {
			if transcription.Cosine(ex, vec) > 0.999999 {
				dup = true
				break
			}
		}
		if !dup {
			item.Embeddings = append(item.Embeddings, vec)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, it := range order {
		it.Embeddings = sampleEmbeddings(it.Embeddings)
	}
	return order, nil
}

func Overlaps(first, second *ClusterEvidence, minimumMs int) bool {
	for _, l := range first.Spans {
		for _, r := range second.Spans {
			if l.SourceID != r.SourceID {
				continue
			}
			shared := min(l.EndMs, r.EndMs) - max(l.StartMs, r.StartMs)
			if shared > int64(minimumMs) {
				return true
			}
		}
	}
	return false
}

func DeclaredDifferently(first, second *ClusterEvidence) bool {
	if len(first.DeclaredKeys) == 0 || len(second.DeclaredKeys) == 0 {
		return false
	}
	for k := range first.DeclaredKeys {
		if !second.DeclaredKeys[k] {
			return true
		}
	}
	return false
}

func DeclaredSame(first, second *ClusterEvidence) bool {
	if len(first.DeclaredKeys) != 1 || len(second.DeclaredKeys) != 1 {
		return false
	}
	for k := range first.DeclaredKeys {
		return second.DeclaredKeys[k]
	}
	return false
}
