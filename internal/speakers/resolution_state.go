package speakers

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"

	"github.com/NeoLabs-Systems/neorecall/internal/processing"
)

const ResolutionVersion = 1

const (
	evidenceTurnsTemplate = `SELECT COUNT(*) FROM transcript_segments t JOIN speaker_turns st
		ON st.chunk_id=t.chunk_id AND st.cluster_id=t.speaker_cluster_id
		WHERE t.conversation_id=%s`
	unresolvedTurnsTemplate = `SELECT COUNT(*) FROM transcript_segments t JOIN speaker_turns st
		ON st.chunk_id=t.chunk_id AND st.cluster_id=t.speaker_cluster_id
		WHERE t.conversation_id=%s AND st.voiceprint_id IS NULL`
)

func EvidenceTurnsSQL(convRef string) string {
	return strings.ReplaceAll(evidenceTurnsTemplate, "%s", convRef)
}

func UnresolvedTurnsSQL(convRef string) string {
	return strings.ReplaceAll(unresolvedTurnsTemplate, "%s", convRef)
}

func WorldSignature(ctx context.Context, db SQLExecQueryer, limits processing.Settings, recurringSpeakerMatching bool, userID string) (string, error) {
	rows, err := db.QueryContext(ctx, `SELECT id, display_name, display_name_source, entity_id,
		matching_enabled, embedding_model, embedding_dimensions FROM voiceprints WHERE user_id=? ORDER BY id`, userID)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	var vps [][]any
	for rows.Next() {
		var id, em string
		var dn, dns, eid *string
		var me, dims int
		if err := rows.Scan(&id, &dn, &dns, &eid, &me, &em, &dims); err != nil {
			return "", err
		}
		vps = append(vps, []any{id, dn, dns, eid, me, em, dims})
	}
	if err := rows.Err(); err != nil {
		return "", err
	}
	if vps == nil {
		vps = [][]any{}
	}
	payload := struct {
		Version                  int     `json:"version"`
		RecurringSpeakerMatching bool    `json:"recurringSpeakerMatching"`
		Tunables                 []any   `json:"tunables"`
		Voiceprints              [][]any `json:"voiceprints"`
	}{
		Version:                  ResolutionVersion,
		RecurringSpeakerMatching: recurringSpeakerMatching,
		Tunables: []any{
			limits.SpeakerMinimumTurnMs,
			limits.SpeakerClusterMergeThreshold,
			limits.SpeakerClusterMargin,
			limits.VoiceMatchThreshold,
			limits.VoiceMatchMargin,
			limits.VoiceEnrollFloor,
			limits.VoiceEnrollMinimumMs,
		},
		Voiceprints: vps,
	}
	b, _ := json.Marshal(payload)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}

func RecordResolutionOutcome(ctx context.Context, db SQLExecQueryer, limits processing.Settings, recurring bool, userID, conversationID, outcome string) error {
	var turns, unresolved int
	if err := db.QueryRowContext(ctx,
		`SELECT (`+EvidenceTurnsSQL("?")+`), (`+UnresolvedTurnsSQL("?")+`)`,
		conversationID, conversationID).Scan(&turns, &unresolved); err != nil {
		return err
	}
	sig, err := WorldSignature(ctx, db, limits, recurring, userID)
	if err != nil {
		return err
	}
	_, err = db.ExecContext(ctx, `INSERT INTO conversation_speaker_resolutions
		(conversation_id, user_id, world_signature, evidence_turns, unresolved_turns, outcome)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(conversation_id) DO UPDATE SET
			user_id=excluded.user_id,
			world_signature=excluded.world_signature,
			evidence_turns=excluded.evidence_turns,
			unresolved_turns=excluded.unresolved_turns,
			outcome=excluded.outcome,
			resolved_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
		conversationID, userID, sig, turns, unresolved, outcome)
	return err
}
