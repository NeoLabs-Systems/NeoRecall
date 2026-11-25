package memories

import (
	"context"
	"database/sql"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	nctx "github.com/NeoLabs-Systems/neorecall/internal/context"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/events"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/transcripts"
	"github.com/google/uuid"
)

const MemoryBulkMax = 100

type MemoryAI interface {
	Ready(ctx context.Context) bool
	Consolidate(ctx context.Context, userID string, in ai.ConsolidationInput) (ai.ConsolidationResult, error)
	WriteDailySummary(ctx context.Context, userID string, sections []ai.ConversationSection, prev *ai.PreviousDailySummary, timezone string) (*ai.DailySummaryOutput, error)
	RewriteMergedMemory(ctx context.Context, userID string, memories []ai.MemoryMergeInput) (ai.MemoryMergeOutput, string, error)
	JudgeDuplicateMemories(ctx context.Context, userID string, left, right ai.MemoryMergeInput, minutesApart int, sameStream bool) (ai.MemoryDedupeOutput, string, error)
	RewriteMemoryWithContext(ctx context.Context, userID string, mem ai.RewriteContextMemory, segs []ai.RewriteContextSegment, items []ai.RewriteContextItem) (ai.RewriteContextOutput, string, error)
}

type Service struct {
	DB      *dbx.DB
	Cfg     func() config.Config
	Context *nctx.Service
	Jobs    *jobs.Service
	AI      MemoryAI
	Log     *slog.Logger
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

type MiniMemoryRow struct {
	InternalID          int64          `json:"internal_id,omitempty"`
	ID                  string         `json:"public_id"`
	MemoryID            string         `json:"memory_public_id,omitempty"`
	Memory              map[string]any `json:"memory,omitempty"`
	TimelineAt          string         `json:"timeline_at,omitempty"`
	Kind                string         `json:"kind"`
	TextEn              string         `json:"text_en"`
	Importance          float64        `json:"importance"`
	ImportanceOverride  *float64       `json:"importance_override"`
	EffectiveImportance float64        `json:"effective_importance"`
	Confidence          float64        `json:"confidence"`
	DueAt               *string        `json:"due_at"`
	OccurredAt          *string        `json:"occurred_at"`
	Status              *string        `json:"status"`
	CreatedAt           string         `json:"created_at"`
	UpdatedAt           string         `json:"updated_at"`
}

type MemoryRow struct {
	InternalID          int64    `json:"internal_id,omitempty"`
	ID                  string   `json:"id"`
	PublicID            string   `json:"public_id"`
	UserID              string   `json:"user_id"`
	Type                string   `json:"type"`
	TitleEn             string   `json:"title_en"`
	SummaryEn           string   `json:"summary_en"`
	Emoji               *string  `json:"emoji"`
	Importance          float64  `json:"importance"`
	ImportanceOverride  *float64 `json:"importance_override"`
	EffectiveImportance float64  `json:"effective_importance"`
	StartedAt           string   `json:"started_at"`
	EndedAt             string   `json:"ended_at"`
	Pinned              bool     `json:"pinned"`
	Archived            bool     `json:"archived"`
	Topics              []string `json:"topics"`
	CreatedAt           string   `json:"created_at"`
	UpdatedAt           string   `json:"updated_at"`
}

type LinkedEntity struct {
	ID              string  `json:"id"`
	Kind            string  `json:"kind"`
	CanonicalNameEn string  `json:"canonical_name_en"`
	DisplayName     *string `json:"display_name"`
	Role            string  `json:"role"`
}

type MemorySourceItem struct {
	ConversationID *string `json:"conversation_id"`
	SegmentID      *int64  `json:"segment_id"`
	PublicSegID    *string `json:"segment_public_id,omitempty"`
	StartedAt      *string `json:"started_at,omitempty"`
	EndedAt        *string `json:"ended_at,omitempty"`
	Text           *string `json:"text,omitempty"`
}

type MemoryDetail struct {
	MemoryRow
	Entities     []LinkedEntity     `json:"entities"`
	MiniMemories []MiniMemoryRow    `json:"mini_memories"`
	Sources      []MemorySourceItem `json:"sources"`
	ContextItems []nctx.Item        `json:"contextItems"`
}

func scanMemoryRow(s interface{ Scan(...any) error }) (MemoryRow, error) {
	var m MemoryRow
	var emoji sql.NullString
	var impOv sql.NullFloat64
	var pinned, archived int
	if err := s.Scan(&m.InternalID, &m.PublicID, &m.UserID, &m.Type, &m.TitleEn, &m.SummaryEn,
		&emoji, &m.Importance, &impOv, &m.StartedAt, &m.EndedAt, &pinned, &archived, &m.CreatedAt, &m.UpdatedAt); err != nil {
		return MemoryRow{}, err
	}
	m.ID = m.PublicID
	if emoji.Valid {
		m.Emoji = &emoji.String
	}
	m.EffectiveImportance = m.Importance
	if impOv.Valid {
		v := impOv.Float64
		m.ImportanceOverride = &v
		m.EffectiveImportance = v
	}
	m.Pinned = pinned != 0
	m.Archived = archived != 0
	m.Topics = []string{}
	return m, nil
}

const memoryCols = `id, public_id, user_id, type, title_en, summary_en, emoji, importance, importance_override,
	started_at, ended_at, pinned, archived, created_at, updated_at`

type ListFilter struct {
	Limit    string
	Type     string
	From     string
	To       string
	Pinned   string
	Archived string
	Topic    string
}

func (s *Service) List(ctx context.Context, userID string, f ListFilter) ([]MemoryRow, error) {
	lim := transcripts.PageLimit(f.Limit, 200, 50)
	conds := []string{"user_id=?"}
	args := []any{userID}
	if f.Type != "" {
		conds = append(conds, "type=?")
		args = append(args, f.Type)
	}
	if f.From != "" {
		conds = append(conds, "ended_at>=?")
		args = append(args, f.From)
	}
	if f.To != "" {
		conds = append(conds, "started_at<=?")
		args = append(args, f.To)
	}
	if f.Pinned == "true" || f.Pinned == "1" {
		conds = append(conds, "pinned=1")
	} else if f.Pinned == "false" || f.Pinned == "0" {
		conds = append(conds, "pinned=0")
	}
	if f.Archived == "true" || f.Archived == "1" {
		conds = append(conds, "archived=1")
	} else if f.Archived != "all" {
		conds = append(conds, "archived=0")
	}
	if f.Topic != "" {
		conds = append(conds, "EXISTS (SELECT 1 FROM memory_topics mt WHERE mt.memory_id=memories.id AND mt.topic=?)")
		args = append(args, f.Topic)
	}
	args = append(args, lim)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT `+memoryCols+` FROM memories WHERE `+strings.Join(conds, " AND ")+`
		ORDER BY pinned DESC, started_at DESC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []MemoryRow{}
	var ids []int64
	byID := make(map[int64]int)
	for rows.Next() {
		if m, err := scanMemoryRow(rows); err == nil {
			byID[m.InternalID] = len(out)
			ids = append(ids, m.InternalID)
			out = append(out, m)
		}
	}
	if len(ids) > 0 {
		targs := anyInts(ids)
		trows, err := s.DB.R.QueryContext(ctx, `SELECT memory_id, topic FROM memory_topics WHERE memory_id IN (`+placeholders(len(ids))+`) ORDER BY topic`, targs...)
		if err == nil {
			for trows.Next() {
				var mid int64
				var t string
				if trows.Scan(&mid, &t) == nil {
					if idx, ok := byID[mid]; ok {
						out[idx].Topics = append(out[idx].Topics, t)
					}
				}
			}
			trows.Close()
		}
	}
	return out, nil
}

func (s *Service) Get(ctx context.Context, userID, publicID string) (MemoryDetail, error) {
	m, err := scanMemoryRow(s.DB.R.QueryRowContext(ctx, `SELECT `+memoryCols+` FROM memories WHERE public_id=? AND user_id=?`, publicID, userID))
	if err == sql.ErrNoRows {
		return MemoryDetail{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Memory not found.")
	}
	if err != nil {
		return MemoryDetail{}, err
	}
	if trows, err := s.DB.R.QueryContext(ctx, `SELECT topic FROM memory_topics WHERE memory_id=? ORDER BY topic`, m.InternalID); err == nil {
		for trows.Next() {
			var t string
			if trows.Scan(&t) == nil {
				m.Topics = append(m.Topics, t)
			}
		}
		trows.Close()
	}

	entities := []LinkedEntity{}
	if erows, err := s.DB.R.QueryContext(ctx, `SELECT e.id, e.kind, e.canonical_name_en, e.display_name, me.role
		FROM memory_entities me JOIN entities e ON e.id=me.entity_id
		WHERE me.memory_id=?`, m.InternalID); err == nil {
		for erows.Next() {
			var le LinkedEntity
			var dn sql.NullString
			if erows.Scan(&le.ID, &le.Kind, &le.CanonicalNameEn, &dn, &le.Role) == nil {
				if dn.Valid {
					le.DisplayName = &dn.String
				}
				entities = append(entities, le)
			}
		}
		erows.Close()
	}

	minis := []MiniMemoryRow{}
	if mrows, err := s.DB.R.QueryContext(ctx, `SELECT id, public_id, kind, text_en, importance, importance_override,
		confidence, due_at, occurred_at, status, created_at, updated_at
		FROM mini_memories WHERE memory_id=? AND user_id=? ORDER BY importance DESC, id ASC`, m.InternalID, userID); err == nil {
		for mrows.Next() {
			var mr MiniMemoryRow
			var impOv sql.NullFloat64
			var due, occ, st sql.NullString
			if mrows.Scan(&mr.InternalID, &mr.ID, &mr.Kind, &mr.TextEn, &mr.Importance, &impOv,
				&mr.Confidence, &due, &occ, &st, &mr.CreatedAt, &mr.UpdatedAt) == nil {
				mr.MemoryID = m.PublicID
				mr.EffectiveImportance = mr.Importance
				if impOv.Valid {
					v := impOv.Float64
					mr.ImportanceOverride = &v
					mr.EffectiveImportance = v
				}
				if due.Valid {
					mr.DueAt = &due.String
				}
				if occ.Valid {
					mr.OccurredAt = &occ.String
				}
				if st.Valid {
					mr.Status = &st.String
				}
				minis = append(minis, mr)
			}
		}
		mrows.Close()
	}

	sources := []MemorySourceItem{}
	if srows, err := s.DB.R.QueryContext(ctx, `SELECT ms.conversation_id, ms.segment_id, ts.public_id, ts.started_at, ts.ended_at, ts.text
		FROM memory_sources ms LEFT JOIN transcript_segments ts ON ts.id=ms.segment_id
		WHERE ms.memory_id=? ORDER BY ts.started_at ASC`, m.InternalID); err == nil {
		for srows.Next() {
			var src MemorySourceItem
			var cid, pub, sa, ea, txt sql.NullString
			var segID sql.NullInt64
			if srows.Scan(&cid, &segID, &pub, &sa, &ea, &txt) == nil {
				if cid.Valid {
					src.ConversationID = &cid.String
				}
				if segID.Valid {
					v := segID.Int64
					src.SegmentID = &v
				}
				if pub.Valid {
					src.PublicSegID = &pub.String
				}
				if sa.Valid {
					src.StartedAt = &sa.String
				}
				if ea.Valid {
					src.EndedAt = &ea.String
				}
				if txt.Valid {
					src.Text = &txt.String
				}
				sources = append(sources, src)
			}
		}
		srows.Close()
	}

	var ctxItems []nctx.Item
	if s.Context != nil {
		ctxItems, _ = s.Context.ListForMemory(ctx, userID, publicID)
	}
	if ctxItems == nil {
		ctxItems = []nctx.Item{}
	}
	return MemoryDetail{
		MemoryRow:    m,
		Entities:     entities,
		MiniMemories: minis,
		Sources:      sources,
		ContextItems: ctxItems,
	}, nil
}

type MemoryPatch struct {
	Type               *string  `json:"type"`
	TitleEn            *string  `json:"titleEn"`
	SummaryEn          *string  `json:"summaryEn"`
	Emoji              *string  `json:"emoji"`
	ImportanceOverride *float64 `json:"importanceOverride"`
	ClearImportanceOv  bool     `json:"clearImportanceOverride"`
	Pinned             *bool    `json:"pinned"`
	Archived           *bool    `json:"archived"`
}

func (s *Service) Update(ctx context.Context, userID, publicID string, p MemoryPatch) (MemoryDetail, error) {
	cur, err := s.Get(ctx, userID, publicID)
	if err != nil {
		return MemoryDetail{}, err
	}
	typ := cur.Type
	if p.Type != nil {
		if !slices.Contains(ai.MemoryTypes, *p.Type) {
			return MemoryDetail{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid memory type.")
		}
		typ = *p.Type
	}
	title := cur.TitleEn
	summary := cur.SummaryEn
	proseEdited := false
	if p.TitleEn != nil {
		t := strings.TrimSpace(*p.TitleEn)
		if t == "" {
			return MemoryDetail{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "titleEn must not be empty.")
		}
		title = ai.BoundedText(t, ai.TitleMaxLength)
		proseEdited = true
	}
	if p.SummaryEn != nil {
		sm := strings.TrimSpace(*p.SummaryEn)
		if sm == "" {
			return MemoryDetail{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "summaryEn must not be empty.")
		}
		summary = ai.BoundedText(sm, ai.SummaryMaxLength)
		proseEdited = true
	}
	var emoji any
	if cur.Emoji != nil {
		emoji = *cur.Emoji
	}
	if p.Emoji != nil {
		em := strings.TrimSpace(*p.Emoji)
		if em == "" {
			emoji = nil
		} else {
			emoji = ai.BoundedText(em, ai.EmojiMaxLength)
		}
	}
	var impOv any
	if cur.ImportanceOverride != nil {
		impOv = *cur.ImportanceOverride
	}
	if p.ClearImportanceOv {
		impOv = nil
	} else if p.ImportanceOverride != nil {
		if *p.ImportanceOverride < 1 || *p.ImportanceOverride > 10 {
			return MemoryDetail{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "importanceOverride must be between 1 and 10.")
		}
		impOv = *p.ImportanceOverride
	}
	pinned := cur.Pinned
	if p.Pinned != nil {
		pinned = *p.Pinned
	}
	archived := cur.Archived
	if p.Archived != nil {
		archived = *p.Archived
	}

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return MemoryDetail{}, err
	}
	defer tx.Rollback()

	_, err = tx.ExecContext(ctx, `UPDATE memories SET
		type=?, title_en=?, summary_en=?, emoji=?, importance_override=?, pinned=?, archived=?,
		prose_edited_at = CASE WHEN ? THEN strftime('%Y-%m-%dT%H:%M:%fZ','now') ELSE prose_edited_at END,
		updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE id=? AND user_id=?`,
		typ, title, summary, emoji, impOv, boolInt(pinned), boolInt(archived), proseEdited, cur.InternalID, userID)
	if err != nil {
		return MemoryDetail{}, err
	}
	if err := syncMemorySearchDocTx(ctx, tx, s.cfg().JobMaxAttempts, userID, cur.InternalID); err != nil {
		return MemoryDetail{}, err
	}
	if err := tx.Commit(); err != nil {
		return MemoryDetail{}, err
	}
	return s.Get(ctx, userID, publicID)
}

func (s *Service) BulkAction(ctx context.Context, userID, action string, publicIDs []string) (map[string]any, error) {
	if len(publicIDs) == 0 || len(publicIDs) > MemoryBulkMax {
		return nil, httperr.New(http.StatusBadRequest, "INVALID_IDS", "Provide between 1 and 100 memory ids.")
	}
	seen := make(map[string]bool)
	var ids []string
	for _, id := range publicIDs {
		if id != "" && !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	args := append([]any{userID}, anyStrings(ids)...)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id FROM memories WHERE user_id=? AND public_id IN (`+placeholders(len(ids))+`)`, args...)
	if err != nil {
		return nil, err
	}
	var internalIDs []int64
	for rows.Next() {
		var mid int64
		if rows.Scan(&mid) == nil {
			internalIDs = append(internalIDs, mid)
		}
	}
	rows.Close()
	if len(internalIDs) != len(ids) {
		return nil, httperr.New(http.StatusNotFound, "NOT_FOUND", "One or more memories were not found.")
	}

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	ph := placeholders(len(internalIDs))
	iargs := append([]any{userID}, anyInts(internalIDs)...)
	var unlink []string
	switch action {
	case "pin":
		_, err = tx.ExecContext(ctx, `UPDATE memories SET pinned=1, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id=? AND id IN (`+ph+`)`, iargs...)
	case "unpin":
		_, err = tx.ExecContext(ctx, `UPDATE memories SET pinned=0, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id=? AND id IN (`+ph+`)`, iargs...)
	case "archive":
		_, err = tx.ExecContext(ctx, `UPDATE memories SET archived=1, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id=? AND id IN (`+ph+`)`, iargs...)
	case "unarchive":
		_, err = tx.ExecContext(ctx, `UPDATE memories SET archived=0, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id=? AND id IN (`+ph+`)`, iargs...)
	case "delete":
		crows, _ := tx.QueryContext(ctx, `SELECT original_path FROM recording_context_items WHERE user_id=? AND memory_id IN (`+ph+`) AND original_path IS NOT NULL`, iargs...)
		if crows != nil {
			for crows.Next() {
				var p string
				if crows.Scan(&p) == nil && p != "" {
					unlink = append(unlink, p)
				}
			}
			crows.Close()
		}
		var refs []embeddings.SearchSourceRef
		for _, id := range internalIDs {
			refs = append(refs, embeddings.SearchSourceRef{Kind: "memory", SourceID: intStr(id)})
		}
		mrows, _ := tx.QueryContext(ctx, `SELECT id FROM mini_memories WHERE user_id=? AND memory_id IN (`+ph+`)`, iargs...)
		if mrows != nil {
			for mrows.Next() {
				var mmid int64
				if mrows.Scan(&mmid) == nil {
					refs = append(refs, embeddings.SearchSourceRef{Kind: "mini_memory", SourceID: intStr(mmid)})
				}
			}
			mrows.Close()
		}
		_, _ = embeddings.RemoveBySourcesTx(ctx, tx, userID, refs)
		_, err = tx.ExecContext(ctx, `DELETE FROM memories WHERE user_id=? AND id IN (`+ph+`)`, iargs...)
	default:
		return nil, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Unsupported bulk action.")
	}
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	for _, p := range unlink {
		_ = os.Remove(p)
	}
	return map[string]any{"action": action, "count": len(ids), "ids": ids}, nil
}

func (s *Service) Merge(ctx context.Context, userID string, publicIDs []string, automatic bool) (MemoryDetail, []string, error) {
	maxItems := s.cfg().MemoryMergeMaxItems
	if maxItems <= 1 {
		maxItems = 10
	}
	seen := make(map[string]bool)
	var ids []string
	for _, id := range publicIDs {
		if id != "" && !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	if len(ids) < 2 {
		return MemoryDetail{}, nil, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "At least two distinct memories are required to merge.")
	}
	if len(ids) > maxItems {
		return MemoryDetail{}, nil, httperr.New(http.StatusBadRequest, "TOO_MANY_IDS", "Too many memories selected for merge.")
	}

	args := append([]any{userID}, anyStrings(ids)...)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT `+memoryCols+` FROM memories WHERE user_id=? AND public_id IN (`+placeholders(len(ids))+`)`, args...)
	if err != nil {
		return MemoryDetail{}, nil, err
	}
	var list []MemoryRow
	for rows.Next() {
		if m, err := scanMemoryRow(rows); err == nil {
			list = append(list, m)
		}
	}
	rows.Close()
	if len(list) != len(ids) {
		return MemoryDetail{}, nil, httperr.New(http.StatusNotFound, "NOT_FOUND", "One or more memories were not found.")
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].StartedAt != list[j].StartedAt {
			return list[i].StartedAt < list[j].StartedAt
		}
		return list[i].InternalID < list[j].InternalID
	})

	snapshot, _ := json.Marshal(ids)
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return MemoryDetail{}, nil, err
	}
	defer tx.Rollback()

	absorbedRes, err := AbsorbClaimedTx(ctx, tx, userID, ids)
	if err != nil {
		return MemoryDetail{}, nil, err
	}
	var sumBuilder strings.Builder
	for i, m := range list {
		if i > 0 {
			sumBuilder.WriteString("\n\n")
		}
		sumBuilder.WriteString(m.SummaryEn)
	}
	maxImp := list[0].Importance
	for _, m := range list[1:] {
		if m.Importance > maxImp {
			maxImp = m.Importance
		}
	}
	_, err = tx.ExecContext(ctx, `UPDATE memories SET
		summary_en=?, importance=?, started_at=?, ended_at=?, pinned=?,
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE id=? AND user_id=?`,
		ai.BoundedText(sumBuilder.String(), ai.SummaryMaxLength), maxImp,
		absorbedRes.StartedAt, absorbedRes.EndedAt, absorbedRes.Pinned,
		absorbedRes.TargetID, userID)
	if err != nil {
		return MemoryDetail{}, nil, err
	}
	if err := syncMemorySearchDocTx(ctx, tx, s.cfg().JobMaxAttempts, userID, absorbedRes.TargetID); err != nil {
		return MemoryDetail{}, nil, err
	}
	_ = events.EmitExec(ctx, tx, userID, "memories.merged", "memory", absorbedRes.PublicID, map[string]any{
		"memoryId": absorbedRes.PublicID, "absorbed": ids[1:], "automatic": automatic,
	})
	if err := tx.Commit(); err != nil {
		return MemoryDetail{}, nil, err
	}

	if s.Jobs != nil && s.AI != nil && s.AI.Ready(ctx) {
		var inputs []ai.MemoryMergeInput
		for _, m := range list {
			inputs = append(inputs, ai.MemoryMergeInput{
				Type: m.Type, TitleEn: m.TitleEn, SummaryEn: m.SummaryEn,
				StartedAt: m.StartedAt, EndedAt: m.EndedAt,
			})
		}
		_, _ = s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
			UserID: userID, ResourceType: "memory_merge", ResourceID: absorbedRes.PublicID,
			Type: "rewrite_merged_memory", Priority: 45,
			Payload: map[string]any{"publicId": absorbedRes.PublicID, "memoryId": absorbedRes.TargetID, "inputs": inputs, "mergedIds": string(snapshot)},
		})
	}
	det, err := s.Get(ctx, userID, absorbedRes.PublicID)
	var absorbedPubs []string
	for _, m := range list {
		if m.PublicID != absorbedRes.PublicID {
			absorbedPubs = append(absorbedPubs, m.PublicID)
		}
	}
	return det, absorbedPubs, err
}

func (s *Service) ExecuteRewriteMerged(ctx context.Context, userID, publicID string, inputs []ai.MemoryMergeInput) error {
	if s.AI == nil || !s.AI.Ready(ctx) {
		return nil
	}
	det, err := s.Get(ctx, userID, publicID)
	if err != nil {
		return nil // deleted cleanly
	}
	if len(inputs) == 0 {
		inputs = []ai.MemoryMergeInput{{
			Type: det.Type, TitleEn: det.TitleEn, SummaryEn: det.SummaryEn,
			StartedAt: det.StartedAt, EndedAt: det.EndedAt, Topics: det.Topics,
		}}
	}
	out, _, err := s.AI.RewriteMergedMemory(ctx, userID, inputs)
	if err != nil {
		return err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, `UPDATE memories SET type=?, title_en=?, summary_en=?, emoji=?,
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`,
		out.Type, out.TitleEn, out.SummaryEn, out.Emoji, det.InternalID, userID)
	if err != nil {
		return err
	}
	if err := syncMemorySearchDocTx(ctx, tx, s.cfg().JobMaxAttempts, userID, det.InternalID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) RewriteWithContext(ctx context.Context, userID string, memoryID int64) (string, error) {
	if s.AI == nil || !s.AI.Ready(ctx) {
		return "", httperr.New(http.StatusServiceUnavailable, "AI_NOT_CONFIGURED", "No language model is configured.")
	}
	m, err := scanMemoryRow(s.DB.R.QueryRowContext(ctx, `SELECT `+memoryCols+` FROM memories WHERE id=? AND user_id=?`, memoryID, userID))
	if err == sql.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	emoji := ""
	if m.Emoji != nil {
		emoji = *m.Emoji
	}

	var ctxRows []ai.RewriteContextItem
	if s.Context != nil {
		list, _ := s.Context.ListForMemory(ctx, userID, m.PublicID)
		for _, it := range list {
			if it.AnalysisState != "ready" && it.Kind != "highlight" {
				continue
			}
			cStr := ""
			if it.AnalysisText != nil && *it.AnalysisText != "" {
				cStr = *it.AnalysisText
			} else if it.NoteText != nil && *it.NoteText != "" {
				cStr = *it.NoteText
			}
			if cStr == "" && it.Kind != "highlight" {
				continue
			}
			capAt := it.CreatedAt
			if it.CapturedAt != nil {
				capAt = *it.CapturedAt
			}
			ctxRows = append(ctxRows, ai.RewriteContextItem{
				ID:           it.ID,
				Kind:         it.Kind,
				CapturedAt:   capAt,
				Content:      cStr,
				OriginalName: it.OriginalName,
			})
		}
	}
	if len(ctxRows) == 0 {
		return m.PublicID, nil
	}

	var segs []ai.RewriteContextSegment
	segIDMap := make(map[string]int64)
	if srows, err := s.DB.R.QueryContext(ctx, `SELECT DISTINCT ts.id, ts.public_id, ts.started_at, ts.ended_at, ts.text
		FROM memory_sources ms JOIN transcript_segments ts ON (ts.id=ms.segment_id OR ts.conversation_id=ms.conversation_id)
		WHERE ms.memory_id=? ORDER BY ts.started_at`, m.InternalID); err == nil {
		for srows.Next() {
			var internalID int64
			var sg ai.RewriteContextSegment
			if srows.Scan(&internalID, &sg.PublicID, &sg.StartedAt, &sg.EndedAt, &sg.Text) == nil {
				segIDMap[sg.PublicID] = internalID
				segs = append(segs, sg)
			}
		}
		srows.Close()
	}

	out, _, err := s.AI.RewriteMemoryWithContext(ctx, userID, ai.RewriteContextMemory{
		Type: m.Type, TitleEn: m.TitleEn, SummaryEn: m.SummaryEn,
		Emoji: emoji, Importance: m.Importance, StartedAt: m.StartedAt, EndedAt: m.EndedAt,
	}, segs, ctxRows)
	if err != nil {
		return "", err
	}

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()

	_, err = tx.ExecContext(ctx, `UPDATE memories SET type=?, title_en=?, summary_en=?, emoji=?, importance=?,
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`,
		out.Type, out.TitleEn, out.SummaryEn, out.Emoji, out.Importance, m.InternalID, userID)
	if err != nil {
		return "", err
	}
	for _, topic := range out.Topics {
		t := strings.TrimSpace(topic)
		if t != "" {
			_, _ = tx.ExecContext(ctx, `INSERT OR IGNORE INTO memory_topics (memory_id, topic) VALUES (?, ?)`, m.InternalID, t)
		}
	}
	for _, cid := range out.SourceContextItemIDs {
		_, _ = tx.ExecContext(ctx, `INSERT INTO memory_context_sources (memory_id, context_item_id, used_by_ai)
			VALUES (?, ?, 1) ON CONFLICT(memory_id, context_item_id) DO UPDATE SET used_by_ai=1`, m.InternalID, cid)
	}
	for _, mm := range out.MiniMemories {
		pub := uuid.NewString()
		var existing int
		_ = tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM mini_memories WHERE memory_id=? AND text_en=?`, m.InternalID, mm.TextEn).Scan(&existing)
		if existing > 0 {
			continue
		}
		res, ierr := tx.ExecContext(ctx, `INSERT INTO mini_memories (public_id, user_id, memory_id, kind, text_en, importance, confidence, due_at, status)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'open')`,
			pub, userID, m.InternalID, mm.Kind, mm.TextEn, mm.Importance, mm.Confidence, mm.DueAtISO)
		if ierr == nil {
			if mmID, err := res.LastInsertId(); err == nil {
				for _, segPub := range mm.SourceSegmentIDs {
					if sid, ok := segIDMap[segPub]; ok {
						_, _ = tx.ExecContext(ctx, `INSERT OR IGNORE INTO mini_memory_sources (mini_memory_id, segment_id) VALUES (?, ?)`, mmID, sid)
					}
				}
				_ = syncMiniMemorySearchDocTx(ctx, tx, s.cfg().JobMaxAttempts, userID, mmID)
			}
		}
	}
	if err := syncMemorySearchDocTx(ctx, tx, s.cfg().JobMaxAttempts, userID, m.InternalID); err != nil {
		return "", err
	}
	_ = events.EmitExec(ctx, tx, userID, "memory.updated", "memory", m.PublicID, map[string]any{"memoryId": m.PublicID})
	if err := tx.Commit(); err != nil {
		return "", err
	}
	return m.PublicID, nil
}

func (s *Service) ListMini(ctx context.Context, userID, kind, status, limitRaw string, filters ...string) ([]MiniMemoryRow, error) {
	lim := transcripts.PageLimit(limitRaw, 200, 50)
	conds := []string{"mm.user_id=?"}
	args := []any{userID}
	if kind != "" {
		conds = append(conds, "mm.kind=?")
		args = append(args, kind)
	}
	if status != "" {
		conds = append(conds, "mm.status=?")
		args = append(args, status)
	}

	if len(filters) > 0 && filters[0] != "" {
		conds = append(conds, "m.public_id=?")
		args = append(args, filters[0])
	}
	if len(filters) > 1 && filters[1] != "" {
		conds = append(conds, "EXISTS (SELECT 1 FROM mini_memory_entities mme WHERE mme.mini_memory_id=mm.id AND mme.entity_id=?)")
		args = append(args, filters[1])
	}
	if len(filters) > 2 && filters[2] != "" {
		conds = append(conds, "mm.text_en LIKE ? COLLATE NOCASE")
		args = append(args, "%"+strings.TrimSpace(filters[2])+"%")
	}
	if len(filters) > 3 && filters[3] != "" {
		conds = append(conds, "mm.public_id=?")
		args = append(args, filters[3])
	}
	args = append(args, lim)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT mm.id, mm.public_id, m.public_id, mm.kind, mm.text_en, mm.importance,
		mm.importance_override, mm.confidence, mm.due_at, mm.occurred_at, mm.status, mm.created_at, mm.updated_at, m.title_en, m.emoji, m.type, COALESCE(mm.occurred_at,mm.due_at,mm.created_at)
		FROM mini_memories mm JOIN memories m ON m.id=mm.memory_id
		WHERE `+strings.Join(conds, " AND ")+` ORDER BY COALESCE(mm.occurred_at,mm.due_at,mm.created_at) DESC, mm.id DESC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []MiniMemoryRow{}
	for rows.Next() {
		var r MiniMemoryRow
		var impOv sql.NullFloat64
		var due, occ, st, emoji sql.NullString
		var title, memType string
		if rows.Scan(&r.InternalID, &r.ID, &r.MemoryID, &r.Kind, &r.TextEn, &r.Importance,
			&impOv, &r.Confidence, &due, &occ, &st, &r.CreatedAt, &r.UpdatedAt, &title, &emoji, &memType, &r.TimelineAt) == nil {
			r.Memory = map[string]any{"public_id": r.MemoryID, "title_en": title, "type": memType, "emoji": nil}
			if emoji.Valid && emoji.String != "" {
				r.Memory["emoji"] = emoji.String
			} else {
				r.Memory["emoji"] = ai.DefaultEmojiForType(memType)
			}
			r.EffectiveImportance = r.Importance
			if impOv.Valid {
				v := impOv.Float64
				r.ImportanceOverride = &v
				r.EffectiveImportance = v
			}
			if due.Valid {
				r.DueAt = &due.String
			}
			if occ.Valid {
				r.OccurredAt = &occ.String
			}
			if st.Valid {
				r.Status = &st.String
			}
			out = append(out, r)
		}
	}
	return out, nil
}

type MiniPatch struct {
	TextEn             *string  `json:"textEn"`
	Status             *string  `json:"status"`
	DueAt              *string  `json:"dueAt"`
	ClearDueAt         bool     `json:"clearDueAt"`
	ImportanceOverride *float64 `json:"importanceOverride"`
	ClearImportanceOv  bool     `json:"clearImportanceOverride"`
}

// UnmarshalJSON distinguishes an explicit null override from an omitted field.
func (p *MiniPatch) UnmarshalJSON(data []byte) error {
	type plain MiniPatch
	var v plain
	if err := json.Unmarshal(data, &v); err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	if raw, ok := fields["importanceOverride"]; ok && string(raw) == "null" {
		v.ClearImportanceOv = true
	}
	*p = MiniPatch(v)
	return nil
}

func (s *Service) UpdateMini(ctx context.Context, userID, publicID string, p MiniPatch) (MiniMemoryRow, error) {
	var id int64
	var memPub, kind, textEn, createdAt, updatedAt string
	var imp, conf float64
	var impOv sql.NullFloat64
	var due, occ, st sql.NullString
	err := s.DB.R.QueryRowContext(ctx, `SELECT mm.id, m.public_id, mm.kind, mm.text_en, mm.importance, mm.importance_override,
		mm.confidence, mm.due_at, mm.occurred_at, mm.status, mm.created_at, mm.updated_at
		FROM mini_memories mm JOIN memories m ON m.id=mm.memory_id
		WHERE mm.public_id=? AND mm.user_id=?`, publicID, userID).
		Scan(&id, &memPub, &kind, &textEn, &imp, &impOv, &conf, &due, &occ, &st, &createdAt, &updatedAt)
	if err == sql.ErrNoRows {
		return MiniMemoryRow{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Mini memory not found.")
	}
	if err != nil {
		return MiniMemoryRow{}, err
	}
	if p.TextEn != nil {
		tr := strings.TrimSpace(*p.TextEn)
		if tr == "" {
			return MiniMemoryRow{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "textEn must not be empty.")
		}
		textEn = tr
	}
	var stOut any
	if st.Valid {
		stOut = st.String
	}
	if p.Status != nil {
		if *p.Status != "open" && *p.Status != "completed" && *p.Status != "cancelled" {
			return MiniMemoryRow{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid mini-memory status.")
		}
		stOut = *p.Status
	}
	var dueOut any
	if due.Valid {
		dueOut = due.String
	}
	if p.ClearDueAt {
		dueOut = nil
	} else if p.DueAt != nil {
		t, terr := timeutil.ParseISO(*p.DueAt)
		if terr != nil {
			return MiniMemoryRow{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid dueAt timestamp.")
		}
		dueOut = timeutil.FormatISO(t)
	}
	var ovOut any
	if impOv.Valid {
		ovOut = impOv.Float64
	}
	if p.ClearImportanceOv {
		ovOut = nil
	} else if p.ImportanceOverride != nil {
		if *p.ImportanceOverride < 1 || *p.ImportanceOverride > 10 {
			return MiniMemoryRow{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "importanceOverride must be between 1 and 10.")
		}
		ovOut = *p.ImportanceOverride
	}

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return MiniMemoryRow{}, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `UPDATE mini_memories SET text_en=?, status=?, due_at=?, importance_override=?,
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`,
		textEn, stOut, dueOut, ovOut, id, userID); err != nil {
		return MiniMemoryRow{}, err
	}
	if err := syncMiniMemorySearchDocTx(ctx, tx, s.cfg().JobMaxAttempts, userID, id); err != nil {
		return MiniMemoryRow{}, err
	}
	if err := tx.Commit(); err != nil {
		return MiniMemoryRow{}, err
	}

	var res MiniMemoryRow
	res.InternalID = id
	res.ID = publicID
	res.MemoryID = memPub
	res.Kind = kind
	res.TextEn = textEn
	res.Importance = imp
	res.Confidence = conf
	res.EffectiveImportance = imp
	if v, ok := ovOut.(float64); ok {
		res.ImportanceOverride = &v
		res.EffectiveImportance = v
	}
	if s, ok := dueOut.(string); ok {
		res.DueAt = &s
	}
	if s, ok := stOut.(string); ok {
		res.Status = &s
	}
	res.CreatedAt = createdAt
	res.UpdatedAt = timeutil.NowISO()
	return res, nil
}

func syncMemorySearchDocTx(ctx context.Context, tx *sql.Tx, maxAttempts int, userID string, memID int64) error {
	var title, summary, startedAt string
	var imp float64
	var impOv sql.NullFloat64
	if err := tx.QueryRowContext(ctx, `SELECT title_en, summary_en, started_at, importance, importance_override
		FROM memories WHERE id=? AND user_id=?`, memID, userID).Scan(&title, &summary, &startedAt, &imp, &impOv); err != nil {
		return err
	}
	eff := int(imp)
	if impOv.Valid {
		eff = int(impOv.Float64)
	}
	if eff < 1 {
		eff = 1
	}
	_, err := embeddings.UpsertDocumentExec(ctx, tx, maxAttempts, userID, "memory", intStr(memID), &title, summary, startedAt, eff)
	return err
}

func syncMiniMemorySearchDocTx(ctx context.Context, tx *sql.Tx, maxAttempts int, userID string, mmID int64) error {
	var text, createdAt string
	var due, occ sql.NullString
	var imp float64
	var impOv sql.NullFloat64
	if err := tx.QueryRowContext(ctx, `SELECT text_en, COALESCE(due_at, occurred_at, created_at), importance, importance_override
		FROM mini_memories WHERE id=? AND user_id=?`, mmID, userID).Scan(&text, &createdAt, &imp, &impOv); err != nil {
		return err
	}
	_ = due
	_ = occ
	eff := int(imp)
	if impOv.Valid {
		eff = int(impOv.Float64)
	}
	if eff < 1 {
		eff = 1
	}
	_, err := embeddings.UpsertDocumentExec(ctx, tx, maxAttempts, userID, "mini_memory", intStr(mmID), nil, text, createdAt, eff)
	return err
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func anyInts(in []int64) []any {
	out := make([]any, len(in))
	for i, v := range in {
		out[i] = v
	}
	return out
}

// MiniDetail returns the original mini-memory detail contract.
func (s *Service) MiniDetail(ctx context.Context, userID, publicID string) (map[string]any, error) {
	rows, err := s.ListMini(ctx, userID, "", "", "1", "", "", "", publicID)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, httperr.New(http.StatusNotFound, "NOT_FOUND", "Mini-memory not found.")
	}
	m := rows[0]
	encoded, err := json.Marshal(m)
	if err != nil {
		return nil, err
	}
	out := map[string]any{}
	if err = json.Unmarshal(encoded, &out); err != nil {
		return nil, err
	}
	var summary, started string
	if err = s.DB.R.QueryRowContext(ctx, `SELECT summary_en,started_at FROM memories WHERE public_id=? AND user_id=?`, m.MemoryID, userID).Scan(&summary, &started); err != nil {
		return nil, err
	}
	m.Memory["summary_en"] = summary
	m.Memory["started_at"] = started
	out["memory"] = m.Memory
	sources := []map[string]any{}
	sr, err := s.DB.R.QueryContext(ctx, `SELECT ts.public_id,ts.started_at,ts.ended_at,ts.text,ts.conversation_id FROM mini_memory_sources ms JOIN transcript_segments ts ON ts.id=ms.segment_id WHERE ms.mini_memory_id=? ORDER BY ts.started_at`, m.InternalID)
	if err != nil {
		return nil, err
	}
	for sr.Next() {
		var id, start, end, text string
		var conv sql.NullString
		if err = sr.Scan(&id, &start, &end, &text, &conv); err != nil {
			sr.Close()
			return nil, err
		}
		var cid any
		if conv.Valid {
			cid = conv.String
		}
		sources = append(sources, map[string]any{"segment_id": id, "started_at": start, "ended_at": end, "text": text, "conversation_id": cid})
	}
	err = sr.Err()
	sr.Close()
	if err != nil {
		return nil, err
	}
	entities := []LinkedEntity{}
	er, err := s.DB.R.QueryContext(ctx, `SELECT e.id,e.kind,e.canonical_name_en,e.display_name,me.role FROM mini_memory_entities me JOIN entities e ON e.id=me.entity_id WHERE me.mini_memory_id=? AND e.user_id=? ORDER BY e.canonical_name_en`, m.InternalID, userID)
	if err != nil {
		return nil, err
	}
	for er.Next() {
		var e LinkedEntity
		var name sql.NullString
		if err = er.Scan(&e.ID, &e.Kind, &e.CanonicalNameEn, &name, &e.Role); err != nil {
			er.Close()
			return nil, err
		}
		if name.Valid {
			e.DisplayName = &name.String
		}
		entities = append(entities, e)
	}
	err = er.Err()
	er.Close()
	if err != nil {
		return nil, err
	}
	out["sources"] = sources
	out["entities"] = entities
	return out, nil
}
func (s *Service) RemoveMini(ctx context.Context, userID, publicID string) error {
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var id int64
	err = tx.QueryRowContext(ctx, `SELECT id FROM mini_memories WHERE user_id=? AND public_id=?`, userID, publicID).Scan(&id)
	if err == sql.ErrNoRows {
		return httperr.New(http.StatusNotFound, "NOT_FOUND", "Mini-memory not found.")
	}
	if err != nil {
		return err
	}
	if _, err = embeddings.RemoveBySourcesTx(ctx, tx, userID, []embeddings.SearchSourceRef{{Kind: "mini_memory", SourceID: strconv.FormatInt(id, 10)}}); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM mini_memories WHERE user_id=? AND id=?`, userID, id); err != nil {
		return err
	}
	return tx.Commit()
}
