package embeddings

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

const (
	bandCount    = 10
	bitsPerBand  = 14
	indexVersion = 3
)

type Band struct {
	Index     int
	Value     int
	Dimension int
}

func sampledCoordinate(dimension, bandIndex, bitIndex int) int {
	v := uint32(bandIndex+1)*0x9e3779b1 ^ uint32(bitIndex+1)*0x85ebca6b
	v ^= v >> 16
	v *= 0x7feb352d
	v ^= v >> 15
	return int(v % uint32(dimension))
}

func CreateEmbeddingBands(vec []float32) []Band {
	if len(vec) < bitsPerBand {
		return nil
	}
	bands := make([]Band, 0, bandCount)
	for b := 0; b < bandCount; b++ {
		val := 0
		for bit := 0; bit < bitsPerBand; bit++ {
			coord := sampledCoordinate(len(vec), b, bit)
			if vec[coord] >= 0 {
				val |= 1 << bit
			}
		}
		bands = append(bands, Band{Index: b, Value: val, Dimension: len(vec)})
	}
	return bands
}

func bandProbes(vec []float32) ([][]int, []int) {
	bands := CreateEmbeddingBands(vec)
	probes := make([][]int, 0, len(bands))
	idxs := make([]int, 0, len(bands))
	for _, b := range bands {
		vals := make([]int, 0, 1+bitsPerBand+(bitsPerBand*(bitsPerBand-1))/2)
		vals = append(vals, b.Value)
		for i := 0; i < bitsPerBand; i++ {
			vals = append(vals, b.Value^(1<<i))
			for j := i + 1; j < bitsPerBand; j++ {
				vals = append(vals, b.Value^(1<<i)^(1<<j))
			}
		}
		probes = append(probes, vals)
		idxs = append(idxs, b.Index)
	}
	return probes, idxs
}

func replaceSearchBandsTx(ctx context.Context, tx *sql.Tx, documentID int64, userID string, vec []float32) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM search_embedding_bands WHERE document_id=?`, documentID); err != nil {
		return err
	}
	for _, b := range CreateEmbeddingBands(vec) {
		if _, err := tx.ExecContext(ctx, `INSERT INTO search_embedding_bands
			(document_id, user_id, dimension, index_version, band_index, band_value)
			VALUES (?, ?, ?, ?, ?, ?)`,
			documentID, userID, b.Dimension, indexVersion, b.Index, b.Value); err != nil {
			return err
		}
	}
	return nil
}

func placeholders(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.Repeat("?,", n-1) + "?"
}

type SearchSourceRef struct {
	Kind     string
	SourceID string
}

type SearchDocument struct {
	ID         int64  `json:"id"`
	UserID     string `json:"user_id"`
	Kind       string `json:"kind"`
	SourceID   string `json:"source_id"`
	Title      string `json:"title"`
	Body       string `json:"body"`
	OccurredAt string `json:"occurred_at"`
	Importance int    `json:"importance"`
	TextHash   string `json:"text_hash"`
}

func RemoveBySourcesTx(ctx context.Context, tx *sql.Tx, userID string, refs []SearchSourceRef) (int, error) {
	if len(refs) == 0 {
		return 0, nil
	}
	removed := 0
	for _, ref := range refs {
		rows, err := tx.QueryContext(ctx, `SELECT id FROM search_documents WHERE user_id=? AND kind=? AND source_id=?`,
			userID, ref.Kind, ref.SourceID)
		if err != nil {
			return removed, err
		}
		var docIDs []int64
		for rows.Next() {
			var id int64
			if rows.Scan(&id) == nil {
				docIDs = append(docIDs, id)
			}
		}
		rows.Close()
		for _, id := range docIDs {
			_, _ = tx.ExecContext(ctx, `DELETE FROM search_embedding_bands WHERE document_id=?`, id)
			if _, err := tx.ExecContext(ctx, `DELETE FROM search_documents WHERE id=?`, id); err != nil {
				return removed, err
			}
			removed++
		}
	}
	return removed, nil
}

func RemoveForUserTx(ctx context.Context, tx *sql.Tx, userID string) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM search_embedding_bands WHERE user_id=?`, userID); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `DELETE FROM search_documents WHERE user_id=?`, userID)
	return err
}

func UpsertDocumentExec(ctx context.Context, execer interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, defaultMaxAttempts int, userID, kind, sourceID string, title *string, body, occurredAt string, importance int) (SearchDocument, error) {
	var titleVal string
	var titleNull sql.NullString
	if title != nil {
		titleVal = *title
		titleNull = sql.NullString{String: *title, Valid: true}
	}
	textHash := crypto.SHA256Hex(titleVal + "\n" + body)
	if _, err := execer.ExecContext(ctx, `INSERT INTO search_documents (user_id, kind, source_id, title, body, occurred_at, importance, text_hash)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(user_id, kind, source_id) DO UPDATE SET
			title=excluded.title, body=excluded.body, occurred_at=excluded.occurred_at,
			importance=excluded.importance, text_hash=excluded.text_hash,
			updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
		userID, kind, sourceID, titleNull, body, occurredAt, importance, textHash); err != nil {
		return SearchDocument{}, err
	}
	var doc SearchDocument
	var tOut sql.NullString
	err := execer.QueryRowContext(ctx, `SELECT id, user_id, kind, source_id, title, body, occurred_at, importance, text_hash
		FROM search_documents WHERE user_id=? AND kind=? AND source_id=?`, userID, kind, sourceID).
		Scan(&doc.ID, &doc.UserID, &doc.Kind, &doc.SourceID, &tOut, &doc.Body, &doc.OccurredAt, &doc.Importance, &doc.TextHash)
	if err != nil {
		return SearchDocument{}, err
	}
	doc.Title = tOut.String
	_, _ = jobs.EnqueueTx(ctx, execer, jobs.EnqueueInput{
		UserID: userID, ResourceType: "search_document", ResourceID: fmt.Sprintf("%d", doc.ID),
		Type: "embed_search_documents", Priority: 50,
		Payload: map[string]any{"documentIds": []int64{doc.ID}},
	}, defaultMaxAttempts)
	return doc, nil
}

func (s *Service) ReindexAll(ctx context.Context) (int, error) {
	batch := max(1, s.cfg().ReindexBatchSize)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, user_id FROM search_documents ORDER BY id`)
	if err != nil {
		return 0, err
	}
	type docRef struct {
		id     int64
		userID string
	}
	var all []docRef
	for rows.Next() {
		var r docRef
		if rows.Scan(&r.id, &r.userID) == nil {
			all = append(all, r)
		}
	}
	rows.Close()
	for off := 0; off < len(all); off += batch {
		end := min(len(all), off+batch)
		ids := make([]int64, 0, end-off)
		for _, item := range all[off:end] {
			ids = append(ids, item.id)
		}
		_, _ = s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
			UserID: all[off].userID, ResourceType: "search_reindex",
			ResourceID: fmt.Sprintf("reindex:%d", all[off].id),
			Type:       "embed_search_documents", Priority: 10,
			Payload: map[string]any{"documentIds": ids},
		})
	}
	return len(all), nil
}

func (s *Service) EmbedDocuments(ctx context.Context, documentIDs []int64) error {
	for _, docID := range documentIDs {
		var uid, kind, body, textHash string
		var title sql.NullString
		err := s.DB.R.QueryRowContext(ctx, `SELECT user_id, kind, title, body, text_hash FROM search_documents WHERE id=?`, docID).
			Scan(&uid, &kind, &title, &body, &textHash)
		if err != nil {
			continue
		}
		text := body
		if title.Valid && title.String != "" {
			text = title.String + "\n" + body
		}
		res, err := s.EmbedDetailed(ctx, text, "passage")
		if err != nil {
			return err
		}
		rev := s.LocalModelRevision()
		if res.Space != "" {
			rev = fmt.Sprintf("neorouter:%s@%d", res.Space, len(res.Vector))
		}
		rawVec := transcription.VectorToBytes(res.Vector)
		tx, err := s.DB.W.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO search_embeddings (document_id, user_id, model_revision, dimensions, embedding, text_hash)
			VALUES (?, ?, ?, ?, ?, ?)
			ON CONFLICT(document_id) DO UPDATE SET
				model_revision=excluded.model_revision, dimensions=excluded.dimensions,
				embedding=excluded.embedding, text_hash=excluded.text_hash,
				embedded_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
			docID, uid, rev, len(res.Vector), rawVec, textHash); err != nil {
			_ = tx.Rollback()
			return err
		}
		if err := replaceSearchBandsTx(ctx, tx, docID, uid, res.Vector); err != nil {
			_ = tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

type VectorMatch struct {
	DocumentID int64
	Similarity float64
}

// SearchVector scores all compatible embeddings, including migrated rows without bands.
func (s *Service) SearchVector(ctx context.Context, userID string, kinds []string, queryVec []float32, limit int) ([]VectorMatch, error) {
	if len(queryVec) == 0 || limit <= 0 {
		return nil, nil
	}
	args := []any{userID, len(queryVec)}
	filter := ""
	if len(kinds) > 0 {
		filter = " AND d.kind IN (" + placeholders(len(kinds)) + ")"
		for _, k := range kinds {
			args = append(args, k)
		}
	}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT e.document_id,e.embedding FROM search_embeddings e JOIN search_documents d ON d.id=e.document_id WHERE e.user_id=? AND e.dimensions=?`+filter, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []VectorMatch{}
	for rows.Next() {
		var id int64
		var blob []byte
		if err := rows.Scan(&id, &blob); err != nil {
			return nil, err
		}
		vec := transcription.VectorFromBytes(blob)
		if len(vec) != len(queryVec) {
			continue
		}
		sim := transcription.Cosine(queryVec, vec)
		if !math.IsNaN(sim) {
			out = append(out, VectorMatch{DocumentID: id, Similarity: sim})
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Similarity > out[j].Similarity })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// ParseDocumentIDs decodes documentIds JSON payload cleanly.
func ParseDocumentIDs(raw string) []int64 {
	var p struct {
		DocumentIDs []int64 `json:"documentIds"`
	}
	_ = json.Unmarshal([]byte(raw), &p)
	return p.DocumentIDs
}
