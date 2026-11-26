package memories

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/conversations"
	"github.com/NeoLabs-Systems/neorecall/internal/events"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/settings"
	"github.com/NeoLabs-Systems/neorecall/internal/speakers"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
	"github.com/google/uuid"
)

type ConsolidationService struct {
	Memories *Service
	Settings *settings.Service
	Usage    *usage.Service
}

type RunSummary struct {
	ID            string  `json:"id"`
	UserID        string  `json:"user_id"`
	State         string  `json:"state"`
	MemoryCount   int     `json:"memory_count"`
	MiniCount     int     `json:"mini_memory_count"`
	MaterialChars int     `json:"material_characters"`
	MaterialConvs int     `json:"material_conversations"`
	ReservedAt    string  `json:"reserved_at"`
	StartedAt     *string `json:"started_at"`
	CompletedAt   *string `json:"completed_at"`
	ErrorCode     *string `json:"error_code"`
	ErrorMessage  *string `json:"error_message"`
}

func (cs *ConsolidationService) ListRuns(ctx context.Context, userID string, limit int) ([]RunSummary, error) {
	if limit <= 0 || limit > 100 {
		limit = 25
	}
	rows, err := cs.Memories.DB.R.QueryContext(ctx, `SELECT id, user_id, state, memory_count, mini_memory_count,
		material_characters, material_conversations, reserved_at, started_at, completed_at, error_code, error_message
		FROM consolidation_runs WHERE user_id=? ORDER BY reserved_at DESC LIMIT ?`, userID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []RunSummary{}
	for rows.Next() {
		var r RunSummary
		var sa, ca, ec, em sql.NullString
		if rows.Scan(&r.ID, &r.UserID, &r.State, &r.MemoryCount, &r.MiniCount,
			&r.MaterialChars, &r.MaterialConvs, &r.ReservedAt, &sa, &ca, &ec, &em) == nil {
			if sa.Valid {
				r.StartedAt = &sa.String
			}
			if ca.Valid {
				r.CompletedAt = &ca.String
			}
			if ec.Valid {
				r.ErrorCode = &ec.String
			}
			if em.Valid {
				r.ErrorMessage = &em.String
			}
			out = append(out, r)
		}
	}
	return out, nil
}

func (cs *ConsolidationService) userTimezone(ctx context.Context, userID string) string {
	if cs.Settings != nil {
		if st, err := cs.Settings.Get(ctx, userID); err == nil {
			if tz, _ := st["timezone"].(string); tz != "" {
				return tz
			}
		}
	}
	return "UTC"
}

func (cs *ConsolidationService) Request(ctx context.Context, userID string, manual bool) (bool, string, error) {
	db := cs.Memories.DB
	if cs.Memories.AI == nil || !cs.Memories.AI.Ready(ctx) {
		if manual {
			return false, "", httperr.New(http.StatusServiceUnavailable, "AI_NOT_CONFIGURED", "No language model is configured.")
		}
		return false, "", nil
	}
	if cs.Usage != nil {
		if _, err := cs.Usage.RejectIfReached(ctx, userID, "ai"); err != nil {
			if manual {
				return false, "", err
			}
			return false, "", nil
		}
	}

	var activeRun string
	_ = db.R.QueryRowContext(ctx, `SELECT id FROM consolidation_runs WHERE user_id=? AND state IN ('reserved','running') ORDER BY reserved_at DESC LIMIT 1`, userID).Scan(&activeRun)
	if activeRun != "" {
		return false, activeRun, nil
	}

	eligible, totalChars, err := cs.candidates(ctx, userID, manual)
	if err != nil || len(eligible) == 0 {
		return false, "", err
	}

	runID := uuid.NewString()
	nowISO := timeutil.NowISO()
	convIDs := make([]string, len(eligible))
	for i, cv := range eligible {
		convIDs[i] = cv.ID
	}
	if _, err := db.W.ExecContext(ctx, `INSERT INTO consolidation_runs
		(id, user_id, candidate_started_at, candidate_ended_at, material_characters, material_conversations, state, reserved_at)
		VALUES (?, ?, ?, ?, ?, ?, 'reserved', ?)`,
		runID, userID, eligible[0].StartedAt, eligible[len(eligible)-1].EndedAt, totalChars, len(eligible), nowISO); err != nil {
		return false, "", err
	}
	if cs.Memories.Jobs != nil {
		_, _ = cs.Memories.Jobs.Enqueue(ctx, jobs.EnqueueInput{
			UserID: userID, ResourceType: "consolidation", ResourceID: runID,
			Type: "consolidate_memories", Priority: 30,
			Payload: map[string]any{"runId": runID, "conversationIds": convIDs, "manual": manual},
		})
	}
	return true, runID, nil
}

// candidates picks the closed conversations the next consolidation would send.
func (cs *ConsolidationService) candidates(ctx context.Context, userID string, manual bool) ([]conversations.ConversationRow, int, error) {
	db := cs.Memories.DB
	c := cs.Memories.cfg()
	convs, err := conversations.ListByState(ctx, db.R, userID, []string{"closed"}, false)
	if err != nil {
		return nil, 0, err
	}
	if len(convs) == 0 {
		return nil, 0, nil
	}

	now := time.Now().UTC()
	var eligible []conversations.ConversationRow
	totalChars := 0
	maxConvs := max(1, c.MaxConsolidationConvs)
	maxChars := max(1000, c.MaxConsolidationInputChars)
	for i := 0; i < len(convs) && len(eligible) < maxConvs; i++ {
		if !conversations.IsComplete(ctx, db.R, userID, convs[i].ID) {
			continue
		}
		if !manual {
			chain := OccasionChain(convs, i, c.MemoryOccasionGapMs)
			if len(chain) == 0 {
				continue
			}
			ready := CheckOccasionReadiness(ctx, db.R, c, userID, chain, now)
			if !ready.Ready {
				i += len(chain) - 1
				continue
			}
		}
		ch := conversations.TranscriptCharacters(ctx, db.R, userID, convs[i].ID)
		if len(eligible) > 0 && totalChars+ch > maxChars {
			break
		}
		eligible = append(eligible, convs[i])
		totalChars += ch
	}
	if len(eligible) == 0 {
		return nil, 0, nil
	}
	return eligible, totalChars, nil
}

func (cs *ConsolidationService) Execute(ctx context.Context, userID, runID string, convIDs []string) error {
	db := cs.Memories.DB
	c := cs.Memories.cfg()
	_, _ = db.W.ExecContext(ctx, `UPDATE consolidation_runs SET state='running', started_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE id=? AND user_id=? AND state='reserved'`, runID, userID)

	failRun := func(code, msg string, quarantineConvs bool) error {
		_, _ = db.W.ExecContext(ctx, `UPDATE consolidation_runs SET state='failed', error_code=?, error_message=?,
			completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`,
			code, msg, runID, userID)
		if quarantineConvs {
			for _, cid := range convIDs {
				_ = conversations.Quarantine(ctx, db.W, userID, cid, code+": "+msg, c)
			}
		}
		return &ai.AIError{Code: code, Message: msg}
	}

	if cs.Memories.AI == nil || !cs.Memories.AI.Ready(ctx) {
		return failRun("AI_NOT_CONFIGURED", "Language model not configured", false)
	}

	var mats []ai.InputConversation
	var rawConvs []conversations.ConversationRow
	for _, cid := range convIDs {
		conv, err := conversations.FindInState(ctx, db.R, userID, cid, []string{"closed"}, false)
		if err != nil || conv == nil {
			continue
		}
		if !conversations.IsComplete(ctx, db.R, userID, cid) {
			continue
		}
		mat, _, err := conversations.BuildMaterial(ctx, db.R, userID, *conv, cs.Memories.Context)
		if err != nil || len(mat.Segments) == 0 {
			continue
		}
		rawConvs = append(rawConvs, *conv)
		mats = append(mats, mat)
	}
	if len(mats) == 0 {
		_, _ = db.W.ExecContext(ctx, `UPDATE consolidation_runs SET state='skipped_no_material', completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, runID)
		return nil
	}

	// Trivial single short non-contextual exchange check -> close cleanly as not_memory_worthy without AI burn.
	totalChars := 0
	var maxDur int64
	hasContext := false
	for _, m := range mats {
		for _, sg := range m.Segments {
			totalChars += len(sg.Text)
		}
		if len(m.ContextItems) > 0 {
			hasContext = true
		}
		d := conversations.DurationMs(m.StartedAt, m.EndedAt)
		if d > maxDur {
			maxDur = d
		}
	}
	if !hasContext && len(mats) == 1 && maxDur < c.MinMemoryEvidenceMs && totalChars < c.MinMemoryEvidenceChars {
		tx, err := db.W.BeginTx(ctx, nil)
		if err == nil {
			_, _ = tx.ExecContext(ctx, `UPDATE conversations SET state='not_memory_worthy', memory_worthy=0, insight_state='final',
				refined_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), refinement_run_id=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
				WHERE id=? AND user_id=?`, runID, mats[0].ID, userID)
			_, _ = tx.ExecContext(ctx, `UPDATE consolidation_runs SET state='succeeded', memory_count=0, mini_memory_count=0,
				completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, runID)
			_ = tx.Commit()
			return nil
		}
	}

	tz := cs.userTimezone(ctx, userID)
	cands := FindCandidates(ctx, db.R, userID, mats, c)
	prevDaily := LatestDailySummary(ctx, db.R, userID)

	res, err := cs.Memories.AI.Consolidate(ctx, userID, ai.ConsolidationInput{
		Conversations:          mats,
		PreviousDailySummary:   prevDaily,
		Timezone:               tz,
		ContinuationCandidates: cands,
	})
	if err != nil {
		code := "CONSOLIDATION_FAILED"
		quarantine := true
		var ae *ai.AIError
		if errors.As(err, &ae) && ae.Code != "" {
			code = ae.Code
			if ai.TransientAICodes[ae.Code] {
				quarantine = false
			}
		}
		return failRun(code, err.Error(), quarantine)
	}

	_, _ = ResolveClaims(&res.Value, cands)

	memCount, miniCount, err := cs.PersistTx(ctx, userID, runID, res, mats, tz)
	if err != nil {
		return failRun("CONSOLIDATION_PERSIST_FAILED", err.Error(), false)
	}

	// Best-effort Daily Summary update covering latest day present in batch.
	cs.maybeUpdateDailySummary(ctx, userID, runID, tz, mats)
	_ = memCount
	_ = miniCount
	return nil
}

func (cs *ConsolidationService) PersistTx(ctx context.Context, userID, runID string, res ai.ConsolidationResult, mats []ai.InputConversation, tz string) (memCount, miniCount int, err error) {
	tx, err := cs.Memories.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback()

	refPlan, err := conversations.ApplyConversationSectionsTx(ctx, tx, userID, runID, res.Value.ConversationSections, mats)
	if err != nil {
		return 0, 0, err
	}

	// Map public segID -> internal segment integer id + startedAt/endedAt + context items
	segInfo := make(map[string]struct {
		id     int64
		convID string
		start  string
		end    string
	})
	for _, conv := range refPlan.Conversations {
		for _, sm := range conv.Segments {
			var intID int64
			if tx.QueryRowContext(ctx, `SELECT id FROM transcript_segments WHERE public_id=? AND user_id=?`, sm.Seg.ID, userID).Scan(&intID) == nil {
				segInfo[sm.Seg.ID] = struct {
					id     int64
					convID string
					start  string
					end    string
				}{intID, conv.ID, sm.Seg.StartedAt, sm.Seg.EndedAt}
			}
		}
	}

	// Upsert Entities + Aliases
	entityIDByRef := make(map[string]string, len(res.Value.Entities))
	var speakerLinks []speakers.PersonEntityLink
	for _, ent := range res.Value.Entities {
		normKey := strings.ToLower(strings.TrimSpace(ent.CanonicalNameEn))
		var entID string
		if tx.QueryRowContext(ctx, `SELECT id FROM entities WHERE user_id=? AND kind=? AND normalized_identity_key=?`, userID, ent.Kind, normKey).Scan(&entID) != nil {
			entID = uuid.NewString()
			_, err = tx.ExecContext(ctx, `INSERT INTO entities (id, user_id, kind, canonical_name_en, display_name, normalized_identity_key)
				VALUES (?, ?, ?, ?, ?, ?)`, entID, userID, ent.Kind, ent.CanonicalNameEn, ent.DisplayName, normKey)
			if err != nil {
				return 0, 0, err
			}
		}
		entityIDByRef[ent.Ref] = entID
		for _, al := range ent.Aliases {
			if strings.TrimSpace(al.Value) != "" {
				_, _ = tx.ExecContext(ctx, `INSERT OR IGNORE INTO entity_aliases (entity_id, alias, language) VALUES (?, ?, ?)`, entID, al.Value, al.Language)
			}
		}
		if ent.Kind == "person" && ent.SpeakerAlias != nil && *ent.SpeakerAlias != "" {
			dn := ent.CanonicalNameEn
			if ent.DisplayName != nil && *ent.DisplayName != "" {
				dn = *ent.DisplayName
			}
			speakerLinks = append(speakerLinks, speakers.PersonEntityLink{
				Kind: ent.Kind, EntityID: entID, DisplayName: dn, CanonicalName: ent.CanonicalNameEn, SpeakerAlias: *ent.SpeakerAlias,
			})
		}
	}
	if len(speakerLinks) > 0 && len(res.SpeakerClusters) > 0 {
		speakers.LinkEntitiesToSpeakers(ctx, tx, userID, speakerLinks, res.SpeakerClusters)
	}

	maxAttempts := cs.Memories.cfg().JobMaxAttempts
	for _, mem := range res.Value.Memories {
		var earliest, latest string
		convSet := make(map[string]bool)
		var segIntIDs []int64
		for _, spub := range mem.SourceSegmentIDs {
			si, ok := segInfo[spub]
			if !ok {
				continue
			}
			segIntIDs = append(segIntIDs, si.id)
			convSet[si.convID] = true
			if earliest == "" || si.start < earliest {
				earliest = si.start
			}
			if latest == "" || si.end > latest {
				latest = si.end
			}
		}
		if earliest == "" {
			earliest = mats[0].StartedAt
			latest = mats[len(mats)-1].EndedAt
		}

		var memIntID int64
		var memPubID string
		if len(mem.ContinuesMemoryIDs) > 0 {
			if ab, aerr := AbsorbClaimedTx(ctx, tx, userID, mem.ContinuesMemoryIDs); aerr == nil && ab != nil {
				memIntID = ab.TargetID
				memPubID = ab.PublicID
				if ab.StartedAt < earliest {
					earliest = ab.StartedAt
				}
				if ab.EndedAt > latest {
					latest = ab.EndedAt
				}
				_, err = tx.ExecContext(ctx, `UPDATE memories SET type=?, title_en=?, summary_en=?, emoji=?, importance=?,
					started_at=?, ended_at=?, consolidation_run_id=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
					WHERE id=? AND user_id=?`,
					mem.Type, mem.TitleEn, mem.SummaryEn, mem.Emoji, mem.Importance, earliest, latest, runID, memIntID, userID)
				if err != nil {
					return 0, 0, err
				}
			}
		}
		if memIntID == 0 {
			memPubID = uuid.NewString()
			resIns, ierr := tx.ExecContext(ctx, `INSERT INTO memories
				(public_id, user_id, type, title_en, summary_en, emoji, importance, started_at, ended_at, consolidation_run_id)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				memPubID, userID, mem.Type, mem.TitleEn, mem.SummaryEn, mem.Emoji, mem.Importance, earliest, latest, runID)
			if ierr != nil {
				return 0, 0, ierr
			}
			memIntID, err = resIns.LastInsertId()
			if err != nil {
				return 0, 0, err
			}
		}
		memCount++

		for _, t := range mem.Topics {
			tr := strings.TrimSpace(t)
			if tr != "" {
				_, _ = tx.ExecContext(ctx, `INSERT OR IGNORE INTO memory_topics (memory_id, topic) VALUES (?, ?)`, memIntID, tr)
			}
		}
		for _, er := range mem.Entities {
			if eid, ok := entityIDByRef[er.Ref]; ok {
				_, _ = tx.ExecContext(ctx, `INSERT OR IGNORE INTO memory_entities (memory_id, entity_id, role) VALUES (?, ?, ?)`, memIntID, eid, er.Role)
			}
		}
		for cid := range convSet {
			_, _ = tx.ExecContext(ctx, `INSERT OR IGNORE INTO memory_sources (memory_id, conversation_id, segment_id) VALUES (?, ?, NULL)`, memIntID, cid)
		}
		for _, sid := range segIntIDs {
			_, _ = tx.ExecContext(ctx, `INSERT OR IGNORE INTO memory_sources (memory_id, conversation_id, segment_id) VALUES (?, NULL, ?)`, memIntID, sid)
		}
		if err := syncMemorySearchDocTx(ctx, tx, maxAttempts, userID, memIntID); err != nil {
			return 0, 0, err
		}

		for _, mm := range mem.MiniMemories {
			mmPub := uuid.NewString()
			stVal := "open"
			if mm.Status != nil && *mm.Status != "" {
				stVal = *mm.Status
			}
			mmRes, merr := tx.ExecContext(ctx, `INSERT INTO mini_memories
				(public_id, user_id, memory_id, kind, text_en, importance, confidence, due_at, status)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				mmPub, userID, memIntID, mm.Kind, mm.TextEn, mm.Importance, mm.Confidence, mm.DueAtISO, stVal)
			if merr != nil {
				return 0, 0, merr
			}
			mmIntID, _ := mmRes.LastInsertId()
			miniCount++
			for _, spub := range mm.SourceSegmentIDs {
				if si, ok := segInfo[spub]; ok {
					_, _ = tx.ExecContext(ctx, `INSERT OR IGNORE INTO mini_memory_sources (mini_memory_id, segment_id) VALUES (?, ?)`, mmIntID, si.id)
				}
			}
			for _, er := range mm.Entities {
				if eid, ok := entityIDByRef[er.Ref]; ok {
					_, _ = tx.ExecContext(ctx, `INSERT OR IGNORE INTO mini_memory_entities (mini_memory_id, entity_id, role) VALUES (?, ?, ?)`, mmIntID, eid, er.Role)
				}
			}
			_ = syncMiniMemorySearchDocTx(ctx, tx, maxAttempts, userID, mmIntID)
		}
		_ = events.EmitExec(ctx, tx, userID, "memory.created", "memory", memPubID, map[string]any{"memoryId": memPubID, "titleEn": mem.TitleEn})
	}

	var aiReqNull any
	if res.RequestID != "" {
		aiReqNull = res.RequestID
	}
	if _, err := tx.ExecContext(ctx, `UPDATE consolidation_runs SET state='succeeded', ai_request_id=?,
		memory_count=?, mini_memory_count=?, completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE id=? AND user_id=?`, aiReqNull, memCount, miniCount, runID, userID); err != nil {
		return 0, 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, 0, err
	}
	return memCount, miniCount, nil
}

func (cs *ConsolidationService) maybeUpdateDailySummary(ctx context.Context, userID, runID, tz string, mats []ai.InputConversation) {
	if cs.Memories.AI == nil || !cs.Memories.AI.Ready(ctx) || len(mats) == 0 {
		return
	}
	loc, err := time.LoadLocation(tz)
	if err != nil {
		loc = time.UTC
	}
	anchor, err := timeutil.ParseISO(mats[len(mats)-1].EndedAt)
	if err != nil {
		anchor = time.Now().UTC()
	}
	localDate := anchor.In(loc).Format("2006-01-02")
	prev := LatestDailySummary(ctx, cs.Memories.DB.R, userID)
	var dayPrev *ai.PreviousDailySummary
	if prev != nil && prev.LocalDate == localDate {
		dayPrev = prev
	}
	mems, _ := cs.Memories.List(ctx, userID, ListFilter{Limit: "50"})
	var sections []ai.ConversationSection
	var covS, covE string
	for _, m := range mems {
		t, err := timeutil.ParseISO(m.StartedAt)
		if err != nil || t.In(loc).Format("2006-01-02") != localDate {
			continue
		}
		if covS == "" || m.StartedAt < covS {
			covS = m.StartedAt
		}
		if covE == "" || m.EndedAt > covE {
			covE = m.EndedAt
		}
		sections = append(sections, ai.ConversationSection{
			TitleEn: m.TitleEn, SummaryEn: m.SummaryEn, Topics: m.Topics, MemoryWorthy: true,
		})
	}
	if len(sections) == 0 {
		return
	}
	dsOut, err := cs.Memories.AI.WriteDailySummary(ctx, userID, sections, dayPrev, tz)
	if err != nil || dsOut == nil || dsOut.SummaryEn == "" {
		return
	}
	tx, err := cs.Memories.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return
	}
	defer tx.Rollback()
	_ = UpsertDailySummaryTx(ctx, tx, cs.Memories.cfg().JobMaxAttempts, uuid.NewString(), userID, localDate, tz, dsOut.SummaryEn, &covS, &covE, "final", len(sections), runID)
	_ = tx.Commit()
}

var _ = fmt.Sprintf
