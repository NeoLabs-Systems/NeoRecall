package speakers

import (
	"context"
	"database/sql"
	"sort"
	"strings"

	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

const MaximumVoices = 200

type claimedIdentity struct {
	id          string
	displayName string
	entityID    string
}

func placeholders(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.Repeat("?,", n-1) + "?"
}

func loadClaimedIdentities(ctx context.Context, s *Service, items []*ClusterEvidence) (map[string]claimedIdentity, error) {
	seen := make(map[string]bool)
	var ids []any
	for _, it := range items {
		for vpID := range it.VoiceprintIDs {
			if !seen[vpID] {
				seen[vpID] = true
				ids = append(ids, vpID)
			}
		}
	}
	out := make(map[string]claimedIdentity)
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, display_name, display_name_source, entity_id
		FROM voiceprints WHERE id IN (`+placeholders(len(ids))+`)`, ids...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var dn, dns, eid sql.NullString
		if err := rows.Scan(&id, &dn, &dns, &eid); err != nil {
			continue
		}
		if dns.String == "manual" || (eid.Valid && eid.String != "") {
			out[id] = claimedIdentity{id: id, displayName: dn.String, entityID: eid.String}
		}
	}
	return out, rows.Err()
}

func namedDifferently(claimed map[string]claimedIdentity, left, right *ClusterEvidence) bool {
	var lList, rList []claimedIdentity
	for id := range left.VoiceprintIDs {
		if c, ok := claimed[id]; ok {
			lList = append(lList, c)
		}
	}
	for id := range right.VoiceprintIDs {
		if c, ok := claimed[id]; ok {
			rList = append(rList, c)
		}
	}
	for _, a := range lList {
		for _, b := range rList {
			if a.entityID != "" && b.entityID != "" && a.entityID != b.entityID {
				return true
			}
			if a.displayName != "" && b.displayName != "" && a.displayName != b.displayName {
				return true
			}
		}
	}
	return false
}

func buildForbiddenPairs(ctx context.Context, s *Service, items []*ClusterEvidence, minOverlapMs int) (map[string]bool, error) {
	claimed, err := loadClaimedIdentities(ctx, s, items)
	if err != nil {
		return nil, err
	}
	pairs := make(map[string]bool)
	for i := 0; i < len(items); i++ {
		for j := i + 1; j < len(items); j++ {
			if DeclaredSame(items[i], items[j]) {
				continue
			}
			if DeclaredDifferently(items[i], items[j]) ||
				Overlaps(items[i], items[j], minOverlapMs) ||
				namedDifferently(claimed, items[i], items[j]) {
				pairs[items[i].ID+" "+items[j].ID] = true
				pairs[items[j].ID+" "+items[i].ID] = true
			}
		}
	}
	return pairs, nil
}

func groupByDeclaration(byID map[string]*ClusterEvidence, groups []ClusterGroup) []ClusterGroup {
	byKey := make(map[string]int)
	var merged []ClusterGroup
	for _, g := range groups {
		keys := make(map[string]bool)
		for _, id := range g.MemberIDs {
			if it, ok := byID[id]; ok {
				for k := range it.DeclaredKeys {
					keys[k] = true
				}
			}
		}
		if len(keys) != 1 {
			merged = append(merged, g)
			continue
		}
		var soleKey string
		for k := range keys {
			soleKey = k
		}
		if idx, ok := byKey[soleKey]; ok {
			merged[idx].MemberIDs = append(merged[idx].MemberIDs, g.MemberIDs...)
		} else {
			cp := ClusterGroup{ID: g.ID, MemberIDs: append([]string(nil), g.MemberIDs...)}
			byKey[soleKey] = len(merged)
			merged = append(merged, cp)
		}
	}
	return merged
}

func pooledEmbedding(items []*ClusterEvidence) []float32 {
	var contributors []*ClusterEvidence
	for _, it := range items {
		if len(it.Embeddings) > 0 {
			contributors = append(contributors, it)
		}
	}
	if len(contributors) == 0 {
		return nil
	}
	dim := len(contributors[0].Embeddings[0])
	total := make([]float32, dim)
	var weight float64
	for _, it := range contributors {
		share := float64(max(1, it.SpeechMs)) / float64(len(it.Embeddings))
		for _, emb := range it.Embeddings {
			if len(emb) != dim {
				continue
			}
			unit := transcription.NormalizeVector(emb)
			for i := range dim {
				total[i] += float32(float64(unit[i]) * share)
			}
			weight += share
		}
	}
	if weight == 0 {
		return nil
	}
	return transcription.NormalizeVector(total)
}

func mergeWithinSessions(ctx context.Context, tx SQLExecQueryer, userID string, items []*ClusterEvidence) (merged int, survivors []string, err error) {
	bySession := make(map[string][]*ClusterEvidence)
	var sessOrder []string
	for _, it := range items {
		if _, ok := bySession[it.SessionID]; !ok {
			sessOrder = append(sessOrder, it.SessionID)
		}
		bySession[it.SessionID] = append(bySession[it.SessionID], it)
	}
	for _, sid := range sessOrder {
		var rows []ClusterRow
		for _, it := range bySession[sid] {
			c, err := scanCluster(tx.QueryRowContext(ctx, `SELECT `+clusterCols+` FROM speaker_clusters WHERE id=? AND user_id=?`, it.ID, userID))
			if err == nil {
				rows = append(rows, c)
			}
		}
		if len(rows) == 0 {
			continue
		}
		sort.Slice(rows, func(i, j int) bool { return rows[i].LocalOrdinal < rows[j].LocalOrdinal })
		target := rows[0]
		for _, src := range rows[1:] {
			target, err = MergeClusters(ctx, tx, userID, target, src)
			if err != nil {
				return merged, survivors, err
			}
			merged++
		}
		survivors = append(survivors, target.ID)
	}
	return merged, survivors, nil
}

type ResolveOutcome struct {
	Skipped        string `json:"skipped,omitempty"`
	Voices         int    `json:"voices"`
	Groups         int    `json:"groups"`
	MergedClusters int    `json:"mergedClusters"`
	AssignedTurns  int    `json:"assignedTurns"`
}

func (s *Service) ResolveConversation(ctx context.Context, userID, conversationID string) (ResolveOutcome, error) {
	limits := s.Proc.Get(ctx)
	recurringMatching := s.userRecurringMatching(ctx, userID)

	items, err := CollectEvidence(ctx, s.DB, userID, conversationID)
	if err != nil {
		return ResolveOutcome{}, err
	}
	if len(items) > MaximumVoices {
		if s.Log != nil {
			s.Log.Warn("Skipped speaker resolution for overly crowded conversation", "userId", userID, "conversationId", conversationID, "voices", len(items))
		}
		_ = RecordResolutionOutcome(ctx, s.DB.W, limits, recurringMatching, userID, conversationID, "too_many_voices")
		return ResolveOutcome{Skipped: "too_many_voices", Voices: len(items)}, nil
	}
	if len(items) == 0 {
		_ = RecordResolutionOutcome(ctx, s.DB.W, limits, recurringMatching, userID, conversationID, "no_voices")
		return ResolveOutcome{}, nil
	}

	byID := make(map[string]*ClusterEvidence, len(items))
	cItems := make([]ClusterItem, len(items))
	for i, it := range items {
		byID[it.ID] = it
		cItems[i] = ClusterItem{ID: it.ID, Embeddings: it.Embeddings}
	}
	blocked, err := buildForbiddenPairs(ctx, s, items, limits.SpeakerMinimumTurnMs)
	if err != nil {
		return ResolveOutcome{}, err
	}
	forbidden := func(a, b string) bool { return blocked[a+" "+b] }
	groups := groupByDeclaration(byID, Cluster(cItems, limits.SpeakerClusterMergeThreshold, limits.SpeakerClusterMargin, forbidden))

	key, err := s.MasterKey()
	if err != nil {
		return ResolveOutcome{}, err
	}

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return ResolveOutcome{}, err
	}
	defer tx.Rollback()

	mergedClusters := 0
	assignedTurns := 0
	assignedByGroup := make(map[string]string)
	for _, g := range groups {
		var members []*ClusterEvidence
		var totalSpeechMs int
		for _, id := range g.MemberIDs {
			if m, ok := byID[id]; ok {
				members = append(members, m)
				totalSpeechMs += m.SpeechMs
			}
		}
		if len(members) == 0 {
			continue
		}
		merged, survivors, err := mergeWithinSessions(ctx, tx, userID, members)
		if err != nil {
			return ResolveOutcome{}, err
		}
		mergedClusters += merged
		if !recurringMatching {
			continue
		}
		emb := pooledEmbedding(members)
		if len(emb) == 0 || len(survivors) == 0 {
			continue
		}
		excluded := make(map[string]bool)
		for otherID, vpID := range assignedByGroup {
			for _, og := range groups {
				if og.ID != otherID {
					continue
				}
				conflict := false
				for _, l := range og.MemberIDs {
					for _, r := range g.MemberIDs {
						if forbidden(l, r) {
							conflict = true
							break
						}
					}
					if conflict {
						break
					}
				}
				if conflict {
					excluded[vpID] = true
				}
			}
		}
		speechPtr := &totalSpeechMs
		vp, err := ResolveVoiceprint(ctx, tx, key, limits, userID, survivors[0], emb, true, speechPtr, excluded)
		if err != nil {
			return ResolveOutcome{}, err
		}
		if vp == nil {
			continue
		}
		assignedByGroup[g.ID] = vp.ID
		args := make([]any, 0, 2+len(survivors))
		args = append(args, vp.ID, userID)
		for _, sid := range survivors {
			args = append(args, sid)
		}
		res, err := tx.ExecContext(ctx, `UPDATE speaker_turns SET voiceprint_id=?
			WHERE user_id=? AND voiceprint_id IS NULL AND cluster_id IN (`+placeholders(len(survivors))+`)`, args...)
		if err != nil {
			return ResolveOutcome{}, err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			assignedTurns += int(n)
		}
	}

	if err := RebuildConversationSpeakers(ctx, tx, userID, conversationID); err != nil {
		return ResolveOutcome{}, err
	}
	if err := RecordResolutionOutcome(ctx, tx, limits, recurringMatching, userID, conversationID, "resolved"); err != nil {
		return ResolveOutcome{}, err
	}
	if err := tx.Commit(); err != nil {
		return ResolveOutcome{}, err
	}
	return ResolveOutcome{
		Voices:         len(items),
		Groups:         len(groups),
		MergedClusters: mergedClusters,
		AssignedTurns:  assignedTurns,
	}, nil
}

// PersonEntityLink describes a consolidated person entity linked via speakerAlias.
type PersonEntityLink struct {
	Kind          string
	SpeakerAlias  string
	EntityID      string
	DisplayName   string
	CanonicalName string
}

func LinkEntitiesToSpeakers(ctx context.Context, db SQLExecQueryer, userID string, entities []PersonEntityLink, clusterIDsByAlias map[string]string) int {
	linked := 0
	for _, ent := range entities {
		if ent.Kind != "person" || ent.SpeakerAlias == "" || ent.EntityID == "" {
			continue
		}
		cid := clusterIDsByAlias[ent.SpeakerAlias]
		if cid == "" {
			continue
		}
		vp, err := StickyVoiceprintForCluster(ctx, db, userID, cid)
		if err != nil || vp == nil {
			continue
		}
		name := ent.DisplayName
		if name == "" {
			name = ent.CanonicalName
		}
		res, err := db.ExecContext(ctx, `UPDATE voiceprints SET entity_id=?, display_name=COALESCE(display_name, ?),
			display_name_source=CASE WHEN display_name IS NULL THEN 'inferred' ELSE display_name_source END,
			updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`,
			ent.EntityID, sql.NullString{String: name, Valid: name != ""}, vp.ID, userID)
		if err == nil {
			if n, _ := res.RowsAffected(); n > 0 {
				linked++
			}
		}
	}
	return linked
}
