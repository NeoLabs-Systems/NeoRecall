package speakers

import (
	"context"
	"database/sql"
	"errors"
	"sort"

	"github.com/NeoLabs-Systems/neorecall/internal/processing"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
	"github.com/google/uuid"
)

func StickyVoiceprintForCluster(ctx context.Context, db SQLExecQueryer, userID, clusterID string) (*VoiceprintRow, error) {
	vp, err := scanVoiceprint(db.QueryRowContext(ctx, `SELECT v.id, v.user_id, v.external_key, v.entity_id,
		v.display_name, v.display_name_source, v.centroid_embedding, v.embedding_model,
		v.embedding_dimensions, v.sample_count, v.matching_enabled, v.created_at, v.updated_at
		FROM speaker_turns st JOIN voiceprints v ON v.id=st.voiceprint_id
		WHERE st.cluster_id=? AND st.user_id=? AND v.matching_enabled=1
		GROUP BY v.id ORDER BY COUNT(*) DESC, MAX(st.created_at) DESC LIMIT 1`, clusterID, userID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &vp, nil
}

func MergeClusters(ctx context.Context, db SQLExecQueryer, userID string, target, source ClusterRow) (ClusterRow, error) {
	rows, err := db.QueryContext(ctx, `SELECT DISTINCT conversation_id FROM transcript_segments
		WHERE user_id=? AND conversation_id IS NOT NULL AND speaker_cluster_id IN (?, ?)`,
		userID, target.ID, source.ID)
	if err != nil {
		return ClusterRow{}, err
	}
	var affected []string
	for rows.Next() {
		var cid string
		if rows.Scan(&cid) == nil {
			affected = append(affected, cid)
		}
	}
	rows.Close()

	tc := transcription.NormalizeVector(transcription.VectorFromBytes(target.CentroidEmbedding))
	sc := transcription.NormalizeVector(transcription.VectorFromBytes(source.CentroidEmbedding))
	total := target.SampleCount + source.SampleCount
	var mergedBytes []byte
	if len(tc) > 0 && len(tc) == len(sc) && total > 0 {
		merged := make([]float32, len(tc))
		for i := range tc {
			merged[i] = (tc[i]*float32(target.SampleCount) + sc[i]*float32(source.SampleCount)) / float32(total)
		}
		mergedBytes = transcription.VectorToBytes(transcription.NormalizeVector(merged))
	} else {
		mergedBytes = target.CentroidEmbedding
	}

	if _, err := db.ExecContext(ctx, `UPDATE transcript_segments SET speaker_cluster_id=? WHERE speaker_cluster_id=? AND user_id=?`,
		target.ID, source.ID, userID); err != nil {
		return ClusterRow{}, err
	}
	if _, err := db.ExecContext(ctx, `UPDATE speaker_turns SET cluster_id=? WHERE cluster_id=? AND user_id=?`,
		target.ID, source.ID, userID); err != nil {
		return ClusterRow{}, err
	}
	if _, err := db.ExecContext(ctx, `UPDATE OR REPLACE conversation_speakers SET cluster_id=? WHERE cluster_id=?`,
		target.ID, source.ID); err != nil {
		return ClusterRow{}, err
	}
	if _, err := db.ExecContext(ctx, `UPDATE speaker_clusters SET centroid_embedding=?, sample_count=?,
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, mergedBytes, total, target.ID); err != nil {
		return ClusterRow{}, err
	}
	if _, err := db.ExecContext(ctx, `DELETE FROM speaker_clusters WHERE id=? AND user_id=?`, source.ID, userID); err != nil {
		return ClusterRow{}, err
	}
	for _, cid := range affected {
		if err := RebuildConversationSpeakers(ctx, db, userID, cid); err != nil {
			return ClusterRow{}, err
		}
	}
	return scanCluster(db.QueryRowContext(ctx, `SELECT `+clusterCols+` FROM speaker_clusters WHERE id=?`, target.ID))
}

func CollapseSessionClustersByVoiceprint(ctx context.Context, db SQLExecQueryer, userID, sessionID string) (int, error) {
	rows, err := db.QueryContext(ctx, `SELECT sc.id, sc.user_id, sc.session_id, sc.local_ordinal, sc.centroid_embedding,
		sc.embedding_model, sc.embedding_dimensions, sc.sample_count, sc.created_at, sc.updated_at,
		st.voiceprint_id, COUNT(*) AS assignment_count
		FROM speaker_clusters sc
		JOIN speaker_turns st ON st.cluster_id=sc.id AND st.user_id=sc.user_id
		JOIN voiceprints v ON v.id=st.voiceprint_id AND v.matching_enabled=1
		WHERE sc.user_id=? AND sc.session_id=? AND st.voiceprint_id IS NOT NULL
		GROUP BY sc.id, st.voiceprint_id
		ORDER BY sc.local_ordinal`, userID, sessionID)
	if err != nil {
		return 0, err
	}
	type entry struct {
		cluster      ClusterRow
		voiceprintID string
		count        int
	}
	sticky := make(map[string]entry)
	for rows.Next() {
		var c ClusterRow
		var vpID string
		var cnt int
		if err := rows.Scan(&c.ID, &c.UserID, &c.SessionID, &c.LocalOrdinal, &c.CentroidEmbedding,
			&c.EmbeddingModel, &c.EmbeddingDimensions, &c.SampleCount, &c.CreatedAt, &c.UpdatedAt, &vpID, &cnt); err != nil {
			rows.Close()
			return 0, err
		}
		if cur, ok := sticky[c.ID]; !ok || cnt > cur.count {
			sticky[c.ID] = entry{cluster: c, voiceprintID: vpID, count: cnt}
		}
	}
	rows.Close()

	byVP := make(map[string][]ClusterRow)
	for _, e := range sticky {
		byVP[e.voiceprintID] = append(byVP[e.voiceprintID], e.cluster)
	}
	merged := 0
	for _, group := range byVP {
		if len(group) < 2 {
			continue
		}
		sort.Slice(group, func(i, j int) bool { return group[i].LocalOrdinal < group[j].LocalOrdinal })
		target := group[0]
		for _, src := range group[1:] {
			curSrc, err := scanCluster(db.QueryRowContext(ctx, `SELECT `+clusterCols+` FROM speaker_clusters WHERE id=? AND user_id=?`, src.ID, userID))
			if err != nil {
				continue
			}
			target, err = MergeClusters(ctx, db, userID, target, curSrc)
			if err != nil {
				return merged, err
			}
			merged++
		}
	}
	return merged, nil
}

func CreateCluster(ctx context.Context, db SQLExecQueryer, userID, sessionID string, embedding []float32) (ClusterRow, error) {
	var ordinal int
	if err := db.QueryRowContext(ctx, `SELECT COALESCE(MAX(local_ordinal),0)+1 FROM speaker_clusters WHERE session_id=?`, sessionID).Scan(&ordinal); err != nil {
		return ClusterRow{}, err
	}
	id := uuid.NewString()
	if _, err := db.ExecContext(ctx, `INSERT INTO speaker_clusters
		(id, user_id, session_id, local_ordinal, centroid_embedding, embedding_model, embedding_dimensions, sample_count)
		VALUES (?, ?, ?, ?, ?, ?, ?, 1)`,
		id, userID, sessionID, ordinal, transcription.VectorToBytes(embedding), ModelName, len(embedding)); err != nil {
		return ClusterRow{}, err
	}
	return scanCluster(db.QueryRowContext(ctx, `SELECT `+clusterCols+` FROM speaker_clusters WHERE id=?`, id))
}

type ContinuityAnchor struct {
	ClusterID string
	GapMs     int
}

func ResolveCluster(ctx context.Context, db SQLExecQueryer, limits processing.Settings, userID, sessionID string, embedding []float32, continuity *ContinuityAnchor, durationMs *int) (*ClusterRow, error) {
	reliable := durationMs == nil || *durationMs >= limits.SpeakerMinimumTurnMs
	rows, err := db.QueryContext(ctx, `SELECT `+clusterCols+` FROM speaker_clusters WHERE user_id=? AND session_id=? AND centroid_embedding IS NOT NULL`, userID, sessionID)
	if err != nil {
		return nil, err
	}
	type scoredCluster struct {
		row   ClusterRow
		score float64
	}
	var ranked []scoredCluster
	for rows.Next() {
		c, err := scanCluster(rows)
		if err != nil {
			continue
		}
		sc := transcription.Cosine(embedding, transcription.VectorFromBytes(c.CentroidEmbedding))
		ranked = append(ranked, scoredCluster{row: c, score: sc})
	}
	rows.Close()
	sort.SliceStable(ranked, func(i, j int) bool { return ranked[i].score > ranked[j].score })

	var cluster *ClusterRow
	var best, runnerUp *scoredCluster
	if len(ranked) > 0 {
		best = &ranked[0]
	}
	if len(ranked) > 1 {
		runnerUp = &ranked[1]
	}

	if continuity != nil && continuity.ClusterID != "" && continuity.GapMs <= limits.SpeakerContinuityGapMs {
		for i := range ranked {
			if ranked[i].row.ID == continuity.ClusterID {
				anchor := ranked[i]
				if anchor.score >= limits.SpeakerClusterContinuityThreshold &&
					(best == nil || best.row.ID == anchor.row.ID || best.score-anchor.score <= limits.SpeakerClusterMargin) {
					cp := anchor.row
					cluster = &cp
				}
				break
			}
		}
	}
	if cluster == nil && best != nil && best.score >= limits.SpeakerClusterThreshold {
		contested := runnerUp != nil && runnerUp.score < limits.SpeakerClusterThreshold &&
			best.score-runnerUp.score < limits.SpeakerClusterMargin
		if !contested {
			cp := best.row
			cluster = &cp
		}
	}
	if cluster != nil && runnerUp != nil && runnerUp.score >= limits.SpeakerClusterThreshold && runnerUp.row.ID != cluster.ID {
		alike := transcription.Cosine(
			transcription.VectorFromBytes(cluster.CentroidEmbedding),
			transcription.VectorFromBytes(runnerUp.row.CentroidEmbedding),
		)
		if alike >= limits.SpeakerClusterMergeThreshold {
			merged, err := MergeClusters(ctx, db, userID, *cluster, runnerUp.row)
			if err != nil {
				return nil, err
			}
			cluster = &merged
		}
	}
	if cluster == nil {
		if !reliable {
			return nil, nil
		}
		c, err := CreateCluster(ctx, db, userID, sessionID, embedding)
		if err != nil {
			return nil, err
		}
		return &c, nil
	}
	if !reliable {
		return cluster, nil
	}
	updated := transcription.UpdateCentroid(transcription.VectorFromBytes(cluster.CentroidEmbedding), cluster.SampleCount, embedding)
	rawUpdated := transcription.VectorToBytes(updated)
	if _, err := db.ExecContext(ctx, `UPDATE speaker_clusters SET centroid_embedding=?, sample_count=sample_count+1,
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, rawUpdated, cluster.ID); err != nil {
		return nil, err
	}
	cluster.CentroidEmbedding = rawUpdated
	cluster.SampleCount++
	return cluster, nil
}

func ReinforceVoiceprint(ctx context.Context, db SQLExecQueryer, key []byte, vp VoiceprintRow, embedding []float32, minScore *float64) (VoiceprintRow, error) {
	cur, err := ReadCentroid(key, vp.CentroidEmbedding)
	if err != nil {
		return vp, err
	}
	if minScore != nil && transcription.Cosine(cur, embedding) < *minScore {
		return vp, nil
	}
	centroid := transcription.UpdateCentroid(cur, vp.SampleCount, embedding)
	sealed, err := SealCentroid(key, centroid)
	if err != nil {
		return vp, err
	}
	if _, err := db.ExecContext(ctx, `UPDATE voiceprints SET centroid_embedding=?, sample_count=sample_count+1,
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, sealed, vp.ID); err != nil {
		return vp, err
	}
	vp.CentroidEmbedding = sealed
	vp.SampleCount++
	return vp, nil
}

func ResolveVoiceprint(ctx context.Context, db SQLExecQueryer, key []byte, limits processing.Settings, userID, clusterID string, embedding []float32, enabled bool, speechMs *int, excluded map[string]bool) (*VoiceprintRow, error) {
	if !enabled {
		return nil, nil
	}
	if clusterID != "" {
		assigned, err := StickyVoiceprintForCluster(ctx, db, userID, clusterID)
		if err != nil {
			return nil, err
		}
		if assigned != nil && !excluded[assigned.ID] {
			minSc := limits.VoiceEnrollFloor
			vp, err := ReinforceVoiceprint(ctx, db, key, *assigned, embedding, &minSc)
			if err != nil {
				return nil, err
			}
			return &vp, nil
		}
	}
	rows, err := db.QueryContext(ctx, `SELECT `+voiceprintCols+` FROM voiceprints
		WHERE user_id=? AND matching_enabled=1 AND embedding_model=? AND embedding_dimensions=?`,
		userID, ModelName, len(embedding))
	if err != nil {
		return nil, err
	}
	var candidates []VoiceprintRow
	for rows.Next() {
		r, err := scanVoiceprint(rows)
		if err != nil || excluded[r.ID] {
			continue
		}
		candidates = append(candidates, r)
	}
	rows.Close()

	ranked := RankVoiceprints(key, embedding, candidates)
	if len(ranked) > 0 && ranked[0].Score >= limits.VoiceMatchThreshold {
		contested := len(ranked) > 1 && ranked[1].Score < limits.VoiceMatchThreshold &&
			ranked[0].Score-ranked[1].Score < limits.VoiceMatchMargin
		if contested {
			return nil, nil
		}
		vp, err := ReinforceVoiceprint(ctx, db, key, ranked[0].Row, embedding, nil)
		if err != nil {
			return nil, err
		}
		return &vp, nil
	}
	if len(ranked) > 0 && ranked[0].Score >= limits.VoiceEnrollFloor {
		return nil, nil
	}
	if speechMs != nil && *speechMs < limits.VoiceEnrollMinimumMs {
		return nil, nil
	}
	sealed, err := SealCentroid(key, transcription.NormalizeVector(embedding))
	if err != nil {
		return nil, err
	}
	id := uuid.NewString()
	if _, err := db.ExecContext(ctx, `INSERT INTO voiceprints
		(id, user_id, centroid_embedding, embedding_model, embedding_dimensions, sample_count)
		VALUES (?, ?, ?, ?, ?, 1)`, id, userID, sealed, ModelName, len(embedding)); err != nil {
		return nil, err
	}
	vp, err := scanVoiceprint(db.QueryRowContext(ctx, `SELECT `+voiceprintCols+` FROM voiceprints WHERE id=?`, id))
	if err != nil {
		return nil, err
	}
	return &vp, nil
}
