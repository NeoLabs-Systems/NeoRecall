package context

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/filebox"
	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/events"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/settings"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
	"github.com/google/uuid"
)

type ContextAI interface {
	Ready(ctx context.Context) bool
	AnalyzeContextText(ctx context.Context, userID, name, content string) (desc, reqID string, err error)
	AnalyzeContextImage(ctx context.Context, userID, name, mediaType, base64Data string) (desc, reqID string, err error)
}

type Service struct {
	DB        *dbx.DB
	Cfg       func() config.Config
	MasterKey func() ([]byte, error)
	AI        ContextAI
	Jobs      *jobs.Service
	Settings  *settings.Service
	Usage     *usage.Service
	Log       *slog.Logger

	// Hooks wired by conversations / memories without circular imports.
	OnSessionContextChanged  func(ctx context.Context, userID, sessionID string)
	OnMemoryRewriteRequested func(ctx context.Context, userID string, memoryID int64) (string, error)
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

// Item is a context item as the apps and the memory detail read it.
type Item struct {
	ID                   string  `json:"id"`
	Kind                 string  `json:"kind"`
	SessionID            *string `json:"sessionId"`
	MemoryPublicID       *string `json:"memoryId"`
	CapturedOffsetMs     *int64  `json:"capturedOffsetMs"`
	CapturedAt           *string `json:"capturedAt"`
	NoteText             *string `json:"noteText"`
	OriginalName         *string `json:"originalName"`
	ContentType          *string `json:"contentType"`
	ByteSize             *int64  `json:"byteSize"`
	OriginalAvailable    bool    `json:"originalAvailable"`
	OriginalDeletedAt    *string `json:"originalDeletedAt"`
	ExtractedText        *string `json:"extractedText"`
	AnalysisText         *string `json:"analysisText"`
	AnalysisState        string  `json:"analysisState"`
	AnalysisErrorCode    *string `json:"analysisErrorCode"`
	AnalysisErrorMessage *string `json:"analysisErrorMessage"`
	UsedByAI             bool    `json:"usedByAi"`
	CreatedAt            string  `json:"createdAt"`
	UpdatedAt            string  `json:"updatedAt"`

	UserID       string  `json:"-"`
	MemoryID     *int64  `json:"-"`
	SHA256       *string `json:"-"`
	originalPath *string
}

const itemCols = `id, user_id, session_id, memory_id, kind, captured_offset_ms, captured_at,
	note_text, original_name, content_type, byte_size, sha256, original_path, original_deleted_at,
	extracted_text, analysis_text, analysis_state, analysis_error_code, analysis_error_message, created_at, updated_at,
	(SELECT public_id FROM memories WHERE memories.id=recording_context_items.memory_id),
	COALESCE((SELECT MAX(used_by_ai) FROM memory_context_sources WHERE context_item_id=recording_context_items.id), 0)`

func scanItem(s interface{ Scan(...any) error }) (Item, error) {
	var it Item
	var sess, capAt, note, origName, ct, sha, origPath, origDel, extr, anTxt, errCode, errMsg, memPublic sql.NullString
	var memID, capOff, byteSz sql.NullInt64
	if err := s.Scan(&it.ID, &it.UserID, &sess, &memID, &it.Kind, &capOff, &capAt,
		&note, &origName, &ct, &byteSz, &sha, &origPath, &origDel,
		&extr, &anTxt, &it.AnalysisState, &errCode, &errMsg, &it.CreatedAt, &it.UpdatedAt, &memPublic, &it.UsedByAI); err != nil {
		return Item{}, err
	}
	if sess.Valid {
		it.SessionID = &sess.String
	}
	if memID.Valid {
		v := memID.Int64
		it.MemoryID = &v
	}
	if capOff.Valid {
		v := capOff.Int64
		it.CapturedOffsetMs = &v
	}
	if capAt.Valid {
		it.CapturedAt = &capAt.String
	}
	if note.Valid {
		it.NoteText = &note.String
	}
	if origName.Valid {
		it.OriginalName = &origName.String
	}
	if ct.Valid {
		it.ContentType = &ct.String
	}
	if byteSz.Valid {
		v := byteSz.Int64
		it.ByteSize = &v
	}
	if sha.Valid {
		it.SHA256 = &sha.String
	}
	if origPath.Valid {
		it.originalPath = &origPath.String
	}
	if origDel.Valid {
		it.OriginalDeletedAt = &origDel.String
	}
	if extr.Valid {
		it.ExtractedText = &extr.String
	}
	if anTxt.Valid {
		it.AnalysisText = &anTxt.String
	}
	if errCode.Valid {
		it.AnalysisErrorCode = &errCode.String
	}
	if errMsg.Valid {
		it.AnalysisErrorMessage = &errMsg.String
	}
	if memPublic.Valid {
		it.MemoryPublicID = &memPublic.String
	}
	it.OriginalAvailable = it.originalPath != nil && *it.originalPath != "" && it.OriginalDeletedAt == nil
	return it, nil
}

func (s *Service) sealContextFile(userID, itemID string, data []byte) (string, error) {
	if s.MasterKey == nil {
		return "", fmt.Errorf("context master key provider missing")
	}
	key, err := s.MasterKey()
	if err != nil {
		return "", err
	}
	baseDir := s.cfg().Paths.Context
	if baseDir == "" {
		return "", fmt.Errorf("context storage path is empty")
	}
	userDir := filepath.Join(baseDir, userID)
	if err := os.MkdirAll(userDir, 0o700); err != nil {
		return "", err
	}
	root, err := os.OpenRoot(userDir)
	if err != nil {
		return "", err
	}
	defer root.Close()
	relName := itemID + ".bin"
	fullPath := filepath.Join(userDir, relName)
	f, err := root.OpenFile(relName, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return "", err
	}
	err = filebox.SealReader(f, bytes.NewReader(data), key, crypto.FileMagic)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = root.Remove(relName)
		return "", err
	}
	return fullPath, nil
}

type CreateInput struct {
	ID               string // chosen by the client so a retried upload is idempotent
	Kind             string
	NoteText         string
	CapturedOffsetMs *int64
	CapturedAt       *string
	FileName         string
	ContentType      string
	FileBytes        []byte
}

func (s *Service) verifySession(ctx context.Context, userID, sessionID string) (startedAt string, err error) {
	err = s.DB.R.QueryRowContext(ctx, `SELECT corrected_started_at FROM recording_sessions WHERE id=? AND user_id=?`, sessionID, userID).Scan(&startedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return "", httperr.New(http.StatusNotFound, "SESSION_NOT_FOUND", "Recording session not found.")
	}
	return startedAt, err
}

func (s *Service) verifyMemory(ctx context.Context, userID, publicID string) (id int64, startedAt string, err error) {
	err = s.DB.R.QueryRowContext(ctx, `SELECT id, started_at FROM memories WHERE public_id=? AND user_id=?`, publicID, userID).Scan(&id, &startedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, "", httperr.New(http.StatusNotFound, "MEMORY_NOT_FOUND", "Memory not found.")
	}
	return id, startedAt, err
}

func (s *Service) CreateForSession(ctx context.Context, userID, sessionID string, in CreateInput) (Item, error) {
	sessStart, err := s.verifySession(ctx, userID, sessionID)
	if err != nil {
		return Item{}, err
	}
	if existing, found, err := s.existingItem(ctx, userID, &sessionID, nil, in); found || err != nil {
		return existing, err
	}
	var cnt int
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM recording_context_items WHERE user_id=? AND session_id=?`, userID, sessionID).Scan(&cnt)
	if cnt >= s.cfg().ContextMaxItems {
		return Item{}, httperr.New(http.StatusConflict, "CONTEXT_LIMIT_REACHED", "This recording has reached the maximum number of context items.")
	}
	capAt := s.resolveCapturedAt(sessStart, in.CapturedAt, in.CapturedOffsetMs)
	item, err := s.createItem(ctx, userID, &sessionID, nil, capAt, in)
	if err != nil {
		return Item{}, err
	}
	if item.AnalysisState == "ready" && s.OnSessionContextChanged != nil {
		s.OnSessionContextChanged(ctx, userID, sessionID)
	}
	return item, nil
}

func (s *Service) CreateForMemory(ctx context.Context, userID, memoryPublicID string, in CreateInput) (Item, bool, error) {
	memID, memStart, err := s.verifyMemory(ctx, userID, memoryPublicID)
	if err != nil {
		return Item{}, false, err
	}
	if existing, found, err := s.existingItem(ctx, userID, nil, &memID, in); found || err != nil {
		return existing, false, err
	}
	var cnt int
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM recording_context_items WHERE user_id=? AND `+memoryLinked, userID, memID, memID).Scan(&cnt)
	if cnt >= s.cfg().ContextMaxItems {
		return Item{}, false, httperr.New(http.StatusConflict, "CONTEXT_LIMIT_REACHED", "This memory has reached the maximum number of context items.")
	}
	capAt := s.resolveCapturedAt(memStart, in.CapturedAt, in.CapturedOffsetMs)
	item, err := s.createItem(ctx, userID, nil, &memID, capAt, in)
	if err != nil {
		return Item{}, false, err
	}
	queued := false
	if item.AnalysisState == "ready" && item.Kind != "highlight" && s.Jobs != nil {
		_, _ = s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
			UserID: userID, ResourceType: "memory", ResourceID: memoryPublicID,
			Type: "rewrite_memory_with_context", Priority: 45,
			Payload: map[string]any{"memoryId": memID, "publicId": memoryPublicID},
		})
		queued = true
	}
	return item, queued, nil
}

func (s *Service) resolveCapturedAt(anchor string, explicit *string, offsetMs *int64) string {
	if explicit != nil && *explicit != "" {
		if t, err := timeutil.ParseISO(*explicit); err == nil {
			return timeutil.FormatISO(t)
		}
	}
	if offsetMs != nil && *offsetMs >= 0 {
		if t, err := timeutil.ParseISO(anchor); err == nil {
			return timeutil.FormatISO(t.Add(time.Duration(*offsetMs) * time.Millisecond))
		}
	}
	return timeutil.NowISO()
}

func (s *Service) createItem(ctx context.Context, userID string, sessionID *string, memoryID *int64, capAt string, in CreateInput) (Item, error) {
	c := s.cfg()
	id := in.ID
	if id == "" {
		id = uuid.NewString()
	}
	now := timeutil.NowISO()

	var kind string
	var notePtr, origNamePtr, ctPtr, shaPtr, origPathPtr, extractedPtr *string
	var byteSzPtr *int64
	analysisState := "ready"
	var errCode, errMsg *string

	if len(in.FileBytes) > 0 {
		if int64(len(in.FileBytes)) > c.ContextMaxFileBytes {
			return Item{}, httperr.New(http.StatusRequestEntityTooLarge, "PAYLOAD_TOO_LARGE", "Attached file exceeds the maximum allowed size.")
		}
		fname := filepath.Base(strings.TrimSpace(in.FileName))
		if fname == "" || fname == "." || fname == string(filepath.Separator) {
			fname = "attachment.bin"
		}
		classified := ClassifyAndExtract(fname, in.ContentType, in.FileBytes, c.ContextExtractionMaxCharacters)
		kind = classified.Kind
		origNamePtr = &fname
		ctPtr = &classified.ContentType
		sz := int64(len(in.FileBytes))
		byteSzPtr = &sz
		sum := sha256.Sum256(in.FileBytes)
		sh := hex.EncodeToString(sum[:])
		shaPtr = &sh

		sealedPath, err := s.sealContextFile(userID, id, in.FileBytes)
		if err != nil {
			return Item{}, err
		}
		origPathPtr = &sealedPath
		if classified.Extracted != "" {
			extractedPtr = &classified.Extracted
		}

		// Determine if asynchronous AI analysis should run.
		if kind == "image" {
			if int64(len(in.FileBytes)) > c.ContextImageAnalysisMaxBytes {
				analysisState = "skipped"
				ec, em := "CONTEXT_IMAGE_TOO_LARGE", "Image exceeds maximum size for visual analysis."
				errCode, errMsg = &ec, &em
			} else if s.AI != nil && s.AI.Ready(ctx) {
				analysisState = "pending"
			} else {
				analysisState = "skipped"
			}
		} else if classified.Extracted != "" {
			if s.AI != nil && s.AI.Ready(ctx) {
				analysisState = "pending"
			}
		} else {
			analysisState = "skipped"
			ec, em := "CONTEXT_UNREADABLE", "Could not extract readable text from this file."
			errCode, errMsg = &ec, &em
		}
	} else if in.Kind == "highlight" {
		kind = "highlight"
	} else if in.Kind == "note" || strings.TrimSpace(in.NoteText) != "" {
		kind = "note"
		trimmed := strings.TrimSpace(in.NoteText)
		if trimmed == "" {
			return Item{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Note text is required.")
		}
		if len([]rune(trimmed)) > c.ContextNoteMaxCharacters {
			return Item{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Note text exceeds the maximum allowed character length.")
		}
		notePtr = &trimmed
	} else {
		return Item{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Provide a highlight, note text, or attached file.")
	}

	_, err := s.DB.W.ExecContext(ctx, `INSERT INTO recording_context_items (
		id, user_id, session_id, memory_id, kind, captured_offset_ms, captured_at,
		note_text, original_name, content_type, byte_size, sha256, original_path,
		extracted_text, analysis_state, analysis_error_code, analysis_error_message, created_at, updated_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, userID, sessionID, memoryID, kind, in.CapturedOffsetMs, capAt,
		notePtr, origNamePtr, ctPtr, byteSzPtr, shaPtr, origPathPtr,
		extractedPtr, analysisState, errCode, errMsg, now, now)
	if err != nil {
		if origPathPtr != nil {
			_ = os.Remove(*origPathPtr)
		}
		return Item{}, err
	}

	if memoryID != nil {
		if _, err := s.DB.W.ExecContext(ctx, `INSERT OR IGNORE INTO memory_context_sources (memory_id, context_item_id) VALUES (?, ?)`, *memoryID, id); err != nil {
			return Item{}, err
		}
	}

	if analysisState == "pending" && s.Jobs != nil {
		_, _ = s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
			UserID: userID, ResourceType: "context_item", ResourceID: id,
			Type: "analyze_context_item", Priority: 40,
			Payload: map[string]any{"itemId": id},
		})
	}
	_ = events.EmitExec(ctx, s.DB.W, userID, "context.created", "context_item", id, map[string]any{
		"id": id, "sessionId": sessionID, "memoryId": memoryID, "kind": kind, "analysisState": analysisState,
	})
	return s.GetItem(ctx, userID, id)
}

func (s *Service) GetItem(ctx context.Context, userID, itemID string) (Item, error) {
	it, err := scanItem(s.DB.R.QueryRowContext(ctx, `SELECT `+itemCols+` FROM recording_context_items WHERE id=? AND user_id=?`, itemID, userID))
	if errors.Is(err, sql.ErrNoRows) {
		return Item{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Context item not found.")
	}
	return it, err
}

func (s *Service) ListForSession(ctx context.Context, userID, sessionID string) ([]Item, error) {
	if _, err := s.verifySession(ctx, userID, sessionID); err != nil {
		return nil, err
	}
	return s.listWhere(ctx, `user_id=? AND session_id=? ORDER BY COALESCE(captured_at, created_at)`, userID, sessionID)
}

func (s *Service) ListForMemory(ctx context.Context, userID, memoryPublicID string) ([]Item, error) {
	memID, _, err := s.verifyMemory(ctx, userID, memoryPublicID)
	if err != nil {
		return nil, err
	}
	return s.listWhere(ctx, `user_id=? AND `+memoryLinked+` ORDER BY COALESCE(captured_at, created_at)`, userID, memID, memID)
}

func (s *Service) listWhere(ctx context.Context, where string, args ...any) ([]Item, error) {
	rows, err := s.DB.R.QueryContext(ctx, `SELECT `+itemCols+` FROM recording_context_items WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Item{}
	for rows.Next() {
		if it, err := scanItem(rows); err == nil {
			items = append(items, it)
		}
	}
	return items, nil
}

// memoryLinked matches items attached to a memory directly or carried over from
// the recording it was written from. It takes the memory's row id twice.
const memoryLinked = `(memory_id=? OR EXISTS (SELECT 1 FROM memory_context_sources s
	WHERE s.context_item_id=recording_context_items.id AND s.memory_id=?))`

// Target is the recording or memory a request addresses an item through.
type Target struct {
	SessionID      string
	MemoryPublicID string
}

// owned returns the item only when it belongs to the addressed target.
func (s *Service) owned(ctx context.Context, userID, itemID string, target Target) (Item, error) {
	it, err := s.GetItem(ctx, userID, itemID)
	if err != nil {
		return Item{}, err
	}
	notFound := httperr.New(http.StatusNotFound, "NOT_FOUND", "Context item not found.")
	if target.SessionID != "" && (it.SessionID == nil || *it.SessionID != target.SessionID) {
		return Item{}, notFound
	}
	if target.MemoryPublicID != "" {
		memID, _, err := s.verifyMemory(ctx, userID, target.MemoryPublicID)
		if err != nil {
			return Item{}, err
		}
		var linked int
		if err := s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM recording_context_items WHERE id=? AND `+memoryLinked,
			itemID, memID, memID).Scan(&linked); err != nil {
			return Item{}, err
		}
		if linked == 0 {
			return Item{}, notFound
		}
	}
	return it, nil
}

func (s *Service) existingItem(ctx context.Context, userID string, sessionID *string, memoryID *int64, in CreateInput) (Item, bool, error) {
	if in.ID == "" {
		return Item{}, false, nil
	}
	it, err := scanItem(s.DB.R.QueryRowContext(ctx, `SELECT `+itemCols+` FROM recording_context_items WHERE id=?`, in.ID))
	if errors.Is(err, sql.ErrNoRows) {
		return Item{}, false, nil
	}
	if err != nil {
		return Item{}, false, err
	}
	same := it.UserID == userID
	if sessionID != nil {
		same = same && it.SessionID != nil && *it.SessionID == *sessionID
	}
	if memoryID != nil {
		same = same && it.MemoryID != nil && *it.MemoryID == *memoryID
	}
	if len(in.FileBytes) > 0 {
		sum := sha256.Sum256(in.FileBytes)
		same = same && it.SHA256 != nil && *it.SHA256 == hex.EncodeToString(sum[:])
	} else {
		note := ""
		if it.NoteText != nil {
			note = *it.NoteText
		}
		same = same && it.SHA256 == nil && note == strings.TrimSpace(in.NoteText)
	}
	if !same {
		return Item{}, false, httperr.New(http.StatusConflict, "IDEMPOTENCY_CONFLICT", "That context id already represents different content.")
	}
	return it, true, nil
}

// changed refreshes everything derived from an edited, retried or removed item.
func (s *Service) changed(ctx context.Context, userID string, sessionID *string, memoryIDs []int64) {
	if sessionID != nil && s.OnSessionContextChanged != nil {
		s.OnSessionContextChanged(ctx, userID, *sessionID)
	}
	if s.Jobs == nil {
		return
	}
	for _, memID := range memoryIDs {
		var publicID string
		if s.DB.R.QueryRowContext(ctx, `SELECT public_id FROM memories WHERE id=? AND user_id=?`, memID, userID).Scan(&publicID) != nil {
			continue
		}
		_, _ = s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
			UserID: userID, ResourceType: "memory", ResourceID: publicID,
			Type: "rewrite_memory_with_context", Priority: 60,
			Payload: map[string]any{"memoryId": memID, "publicId": publicID},
		})
	}
}

func (s *Service) linkedMemories(ctx context.Context, itemID string) ([]int64, error) {
	rows, err := s.DB.R.QueryContext(ctx, `SELECT memory_id FROM recording_context_items WHERE id=? AND memory_id IS NOT NULL
		UNION SELECT memory_id FROM memory_context_sources WHERE context_item_id=?`, itemID, itemID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func (s *Service) UpdateNote(ctx context.Context, userID, itemID string, target Target, noteText string) (Item, error) {
	it, err := s.owned(ctx, userID, itemID, target)
	if err != nil {
		return Item{}, err
	}
	if it.Kind != "note" {
		return Item{}, httperr.New(http.StatusConflict, "NOT_EDITABLE", "Only typed notes can be edited.")
	}
	text := strings.TrimSpace(noteText)
	if text == "" || len([]rune(text)) > s.cfg().ContextNoteMaxCharacters {
		return Item{}, httperr.New(http.StatusBadRequest, "INVALID_NOTE", "The note is empty or too long.")
	}
	memories, err := s.linkedMemories(ctx, itemID)
	if err != nil {
		return Item{}, err
	}
	if _, err := s.DB.W.ExecContext(ctx, `UPDATE recording_context_items SET note_text=?,
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, text, itemID); err != nil {
		return Item{}, err
	}
	s.changed(ctx, userID, it.SessionID, memories)
	return s.GetItem(ctx, userID, itemID)
}

func (s *Service) Retry(ctx context.Context, userID, itemID string, target Target) (Item, error) {
	it, err := s.owned(ctx, userID, itemID, target)
	if err != nil {
		return Item{}, err
	}
	if !it.OriginalAvailable {
		return Item{}, httperr.New(http.StatusGone, "ORIGINAL_EXPIRED", "The original file is no longer available for analysis.")
	}
	if _, err := s.DB.W.ExecContext(ctx, `UPDATE recording_context_items SET analysis_state='pending',
		analysis_error_code=NULL, analysis_error_message=NULL WHERE id=?`, itemID); err != nil {
		return Item{}, err
	}
	if s.Jobs != nil {
		if _, err := s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
			UserID: userID, ResourceType: "context_item", ResourceID: itemID,
			Type: "analyze_context_item", Priority: 50,
		}); err != nil {
			return Item{}, err
		}
	}
	return s.GetItem(ctx, userID, itemID)
}

func (s *Service) DeleteItem(ctx context.Context, userID, itemID string, target Target) error {
	it, err := s.owned(ctx, userID, itemID, target)
	if err != nil {
		return err
	}
	memories, err := s.linkedMemories(ctx, itemID)
	if err != nil {
		return err
	}
	if it.originalPath != nil && *it.originalPath != "" {
		if err := os.Remove(*it.originalPath); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	if _, err := s.DB.W.ExecContext(ctx, `DELETE FROM recording_context_items WHERE id=? AND user_id=?`, itemID, userID); err != nil {
		return err
	}
	s.changed(ctx, userID, nil, memories)
	return nil
}

func (s *Service) ReadOriginal(ctx context.Context, userID, itemID string, target Target) (Item, []byte, error) {
	it, err := s.owned(ctx, userID, itemID, target)
	if err != nil {
		return Item{}, nil, err
	}
	gone := httperr.New(http.StatusGone, "ORIGINAL_EXPIRED", "The original file is no longer retained.")
	if !it.OriginalAvailable {
		return Item{}, nil, gone
	}
	key, err := s.MasterKey()
	if err != nil {
		return Item{}, nil, err
	}
	plain, err := crypto.ReadSealedFile(key, *it.originalPath)
	if errors.Is(err, os.ErrNotExist) {
		return Item{}, nil, gone
	}
	if err != nil {
		return Item{}, nil, err
	}
	return it, plain, nil
}

func (s *Service) AnalyzeItem(ctx context.Context, userID, itemID string) error {
	res, err := s.DB.W.ExecContext(ctx, `UPDATE recording_context_items SET analysis_state='analyzing',
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE id=? AND user_id=? AND analysis_state IN ('pending','analyzing')`, itemID, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil
	}
	it, err := s.GetItem(ctx, userID, itemID)
	if err != nil {
		return err
	}
	if s.AI == nil || !s.AI.Ready(ctx) {
		_, _ = s.DB.W.ExecContext(ctx, `UPDATE recording_context_items SET analysis_state='pending', updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, itemID)
		return fmt.Errorf("AI provider not configured")
	}

	var desc string
	var analyzeErr error
	fname := "context"
	if it.OriginalName != nil && *it.OriginalName != "" {
		fname = *it.OriginalName
	}
	if it.Kind == "image" {
		if it.originalPath == nil || *it.originalPath == "" {
			analyzeErr = fmt.Errorf("image binary missing")
		} else {
			key, kerr := s.MasterKey()
			if kerr != nil {
				return kerr
			}
			raw, rerr := crypto.ReadSealedFile(key, *it.originalPath)
			if rerr != nil {
				analyzeErr = rerr
			} else {
				ct := "image/jpeg"
				if it.ContentType != nil && *it.ContentType != "" {
					ct = *it.ContentType
				}
				desc, _, analyzeErr = s.AI.AnalyzeContextImage(ctx, userID, fname, ct, base64.StdEncoding.EncodeToString(raw))
			}
		}
	} else {
		txt := ""
		if it.ExtractedText != nil {
			txt = *it.ExtractedText
		}
		if txt == "" {
			analyzeErr = fmt.Errorf("no extracted text")
		} else {
			desc, _, analyzeErr = s.AI.AnalyzeContextText(ctx, userID, fname, txt)
		}
	}

	if analyzeErr != nil {
		state := "failed"
		code := "CONTEXT_ANALYSIS_FAILED"
		var ae *ai.AIError
		if errors.As(analyzeErr, &ae) && ae.Code != "" {
			code = ae.Code
			if ai.TransientAICodes[ae.Code] {
				_, _ = s.DB.W.ExecContext(ctx, `UPDATE recording_context_items SET analysis_state='pending',
					analysis_error_code=?, analysis_error_message=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
					WHERE id=?`, code, analyzeErr.Error(), itemID)
				return analyzeErr
			}
		}
		_, _ = s.DB.W.ExecContext(ctx, `UPDATE recording_context_items SET analysis_state=?,
			analysis_error_code=?, analysis_error_message=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
			WHERE id=?`, state, code, analyzeErr.Error(), itemID)
		return nil
	}

	_, err = s.DB.W.ExecContext(ctx, `UPDATE recording_context_items SET analysis_text=?, analysis_state='ready',
		analysis_error_code=NULL, analysis_error_message=NULL, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE id=?`, desc, itemID)
	if err != nil {
		return err
	}
	if it.SessionID != nil && s.OnSessionContextChanged != nil {
		s.OnSessionContextChanged(ctx, userID, *it.SessionID)
	}
	if it.MemoryID != nil && s.Jobs != nil {
		var pubID string
		if s.DB.R.QueryRowContext(ctx, `SELECT public_id FROM memories WHERE id=?`, *it.MemoryID).Scan(&pubID) == nil && pubID != "" {
			_, _ = s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
				UserID: userID, ResourceType: "memory", ResourceID: pubID,
				Type: "rewrite_memory_with_context", Priority: 45,
				Payload: map[string]any{"memoryId": *it.MemoryID, "publicId": pubID},
			})
		}
	}
	return nil
}

// HasSince reports whether any ready context item for the conversation's session or time span arrived after sinceISO.
func (s *Service) HasSince(ctx context.Context, userID, sessionID, startedAt, endedAt, sinceISO string) bool {
	if sessionID == "" || sinceISO == "" {
		return false
	}
	var count int
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM recording_context_items
		WHERE user_id=? AND session_id=?
		  AND (analysis_state='ready' OR kind='highlight')
		  AND updated_at>?
		  AND (captured_at IS NULL OR (captured_at>=? AND captured_at<=?))`,
		userID, sessionID, sinceISO, startedAt, endedAt).Scan(&count)
	return count > 0
}

// Attach populates ContextItems onto conversations using session-matched ready context items inside each conversation's span.
func (s *Service) Attach(ctx context.Context, userID string, convs []ai.InputConversation) {
	sessSeen := make(map[string]bool)
	var sessIDs []string
	for _, c := range convs {
		if c.SessionID != nil && *c.SessionID != "" && !sessSeen[*c.SessionID] {
			sessSeen[*c.SessionID] = true
			sessIDs = append(sessSeenSlice(sessIDs, *c.SessionID), *c.SessionID)
		}
	}
	if len(sessIDs) == 0 {
		return
	}
	placeholders := strings.Repeat("?,", len(sessIDs)-1) + "?"
	args := make([]any, 0, 1+len(sessIDs))
	args = append(args, userID)
	for _, sid := range sessIDs {
		args = append(args, sid)
	}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT `+itemCols+` FROM recording_context_items
		WHERE user_id=? AND session_id IN (`+placeholders+`)
		  AND (analysis_state='ready' OR kind='highlight')
		ORDER BY COALESCE(captured_at, created_at)`, args...)
	if err != nil {
		return
	}
	defer rows.Close()
	bySession := make(map[string][]Item)
	for rows.Next() {
		if it, err := scanItem(rows); err == nil && it.SessionID != nil {
			bySession[*it.SessionID] = append(bySession[*it.SessionID], it)
		}
	}
	for idx := range convs {
		c := &convs[idx]
		if c.SessionID == nil {
			continue
		}
		for _, it := range bySession[*c.SessionID] {
			if it.CapturedAt != nil && (*it.CapturedAt < c.StartedAt || *it.CapturedAt > c.EndedAt) {
				continue
			}
			var content *string
			if it.AnalysisText != nil && *it.AnalysisText != "" {
				content = it.AnalysisText
			} else if it.NoteText != nil && *it.NoteText != "" {
				content = it.NoteText
			}
			capAt := it.CreatedAt
			if it.CapturedAt != nil {
				capAt = *it.CapturedAt
			}
			c.ContextItems = append(c.ContextItems, ai.InputContextItem{
				ID:            it.ID,
				Kind:          it.Kind,
				CapturedAt:    capAt,
				SourceName:    it.OriginalName,
				Content:       content,
				AnalysisState: it.AnalysisState,
			})
		}
	}
}

func sessSeenSlice(in []string, _ string) []string { return in }

func (s *Service) PurgeExpiredOriginals(ctx context.Context) int {
	rows, err := s.DB.R.QueryContext(ctx, `SELECT i.id, i.user_id, i.original_path, i.created_at
		FROM recording_context_items i
		WHERE i.original_path IS NOT NULL AND i.original_deleted_at IS NULL`)
	if err != nil {
		return 0
	}
	type cand struct {
		id, userID, path, createdAt string
	}
	var cands []cand
	for rows.Next() {
		var c cand
		if rows.Scan(&c.id, &c.userID, &c.path, &c.createdAt) == nil {
			cands = append(cands, c)
		}
	}
	rows.Close()

	purged := 0
	retCache := make(map[string]int)
	now := time.Now().UTC()
	for _, c := range cands {
		days, ok := retCache[c.userID]
		if !ok {
			days = 30
			if s.Settings != nil {
				if st, err := s.Settings.Get(ctx, c.userID); err == nil {
					if v, ok := st["contextOriginalRetentionDays"].(float64); ok && v > 0 {
						days = int(v)
					} else if vi, ok := st["contextOriginalRetentionDays"].(int); ok && vi > 0 {
						days = vi
					}
				}
			}
			retCache[c.userID] = days
		}
		if days <= 0 {
			continue
		}
		t, err := timeutil.ParseISO(c.createdAt)
		if err != nil {
			continue
		}
		if now.Sub(t) >= time.Duration(days)*24*time.Hour {
			_ = os.Remove(c.path)
			if _, err := s.DB.W.ExecContext(ctx, `UPDATE recording_context_items SET original_path=NULL,
				original_deleted_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, c.id); err == nil {
				purged++
			}
		}
	}
	return purged
}
