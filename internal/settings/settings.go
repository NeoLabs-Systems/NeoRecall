package settings

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"net/http"
	"slices"
	"strconv"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/skip2/go-qrcode"
)

var LanguageCodes = []string{"en", "de"}

const DefaultLanguage = "en"

var apiToColumn = map[string]string{
	"language":                     "language",
	"consolidationIntervalMs":      "consolidation_interval_ms",
	"timezone":                     "timezone",
	"recurringSpeakerMatching":     "recurring_speaker_matching",
	"diarizationEnabled":           "diarization_enabled",
	"chunkTargetMs":                "chunk_target_ms",
	"chunkOverlapMs":               "chunk_overlap_ms",
	"uploadOnlyOnUnmetered":        "upload_only_on_unmetered",
	"recordingScheduleEnabled":     "recording_schedule_enabled",
	"recordingStartMinute":         "recording_start_minute",
	"recordingEndMinute":           "recording_end_minute",
	"customVocabulary":             "custom_vocabulary",
	"contextOriginalRetentionDays": "context_original_retention_days",
	"keepRawAudio":                 "keep_raw_audio",
	"vocabularyCorrectionEnabled":  "vocabulary_correction_enabled",
	"deferredSpeakerResolution":    "deferred_speaker_resolution",
	"instructionsGlobal":           "instructions_global",
	"instructionsMemories":         "instructions_memories",
	"instructionsSummaries":        "instructions_summaries",
	"instructionsAsk":              "instructions_ask",
}

type Service struct {
	DB                       *dbx.DB
	Cfg                      func() config.Config
	SpeakerIdentityAvailable func() bool
	Log                      *slog.Logger
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func (s *Service) defaults() map[string]any {
	c := s.cfg()
	return map[string]any{
		"language":                     nil,
		"consolidationIntervalMs":      c.MinConsolidationIntervalMs,
		"timezone":                     "UTC",
		"recurringSpeakerMatching":     true,
		"diarizationEnabled":           c.DiarizationEnabled,
		"chunkTargetMs":                c.ChunkTargetMs,
		"chunkOverlapMs":               c.ChunkOverlapMs,
		"uploadOnlyOnUnmetered":        true,
		"recordingScheduleEnabled":     false,
		"recordingStartMinute":         0,
		"recordingEndMinute":           0,
		"customVocabulary":             []string{},
		"contextOriginalRetentionDays": 7,
		"keepRawAudio":                 true,
		"vocabularyCorrectionEnabled":  true,
		"deferredSpeakerResolution":    true,
		"instructionsGlobal":           "",
		"instructionsMemories":         "",
		"instructionsSummaries":        "",
		"instructionsAsk":              "",
	}
}

func uniqueTerms(terms []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(terms))
	for _, t := range terms {
		low := strings.ToLower(t)
		if !seen[low] {
			seen[low] = true
			out = append(out, t)
		}
	}
	return out
}

func (s *Service) speakerVocabulary(ctx context.Context, userID string) []string {
	rows, err := s.DB.R.QueryContext(ctx, `SELECT display_name FROM voiceprints
		WHERE user_id=? AND display_name IS NOT NULL AND display_name_source='manual'
		ORDER BY updated_at DESC`, userID)
	if err != nil {
		return []string{}
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var name string
		if rows.Scan(&name) == nil {
			if t := strings.TrimSpace(name); t != "" {
				out = append(out, t)
			}
		}
	}
	if out == nil {
		return []string{}
	}
	return out
}

func (s *Service) Get(ctx context.Context, userID string) (map[string]any, error) {
	colToAPI := make(map[string]string, len(apiToColumn))
	for k, col := range apiToColumn {
		colToAPI[col] = k
	}
	res := s.defaults()
	rows, err := s.DB.R.QueryContext(ctx, `SELECT key, value_json FROM user_settings WHERE user_id=?`, userID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var col, raw string
		if rows.Scan(&col, &raw) != nil {
			continue
		}
		apiKey, ok := colToAPI[col]
		if !ok {
			continue
		}
		var v any
		if err := json.Unmarshal([]byte(raw), &v); err != nil {
			if s.Log != nil {
				s.Log.Warn("ignoring unreadable stored setting", "userId", userID, "setting", apiKey, "error", err)
			}
			continue
		}
		res[apiKey] = v
	}
	rows.Close()

	c := s.cfg()
	interval := c.MinConsolidationIntervalMs
	if f, ok := res["consolidationIntervalMs"].(float64); ok {
		interval = int64(f)
	} else if i, ok := res["consolidationIntervalMs"].(int64); ok {
		interval = i
	}
	eff := max(interval, c.MinConsolidationIntervalMs)
	idAvail := false
	if s.SpeakerIdentityAvailable != nil {
		idAvail = s.SpeakerIdentityAvailable()
	}

	res["minConsolidationIntervalMs"] = c.MinConsolidationIntervalMs
	res["effectiveConsolidationIntervalMs"] = eff
	res["chunkMinMs"] = c.ChunkMinMs
	res["chunkMaxMs"] = c.ChunkMaxMs
	res["customVocabularyMaxTerms"] = c.CustomVocabularyMaxTerms
	res["availableLanguages"] = LanguageCodes
	res["customInstructionsMaxCharacters"] = c.CustomInstructionsMaxChars
	res["customVocabularyMaxTermLength"] = c.CustomVocabularyMaxTermLength
	res["vocabularyCorrectionMinimumLength"] = c.VocabularyCorrectionMinimumLength
	res["automaticSpeakerVocabulary"] = s.speakerVocabulary(ctx, userID)
	res["speakerIdentityAvailable"] = idAvail
	return res, nil
}

func (s *Service) OutputLanguage(ctx context.Context, userID string) string {
	var raw string
	if err := s.DB.R.QueryRowContext(ctx, `SELECT value_json FROM user_settings WHERE user_id=? AND key='language'`, userID).Scan(&raw); err != nil {
		return DefaultLanguage
	}
	var lang string
	if json.Unmarshal([]byte(raw), &lang) != nil || !slices.Contains(LanguageCodes, strings.ToLower(lang)) {
		return DefaultLanguage
	}
	return strings.ToLower(lang)
}

func (s *Service) TranscriptionVocabulary(ctx context.Context, userID string) []string {
	full, err := s.Get(ctx, userID)
	if err != nil {
		return []string{}
	}
	var custom []string
	if raw, ok := full["customVocabulary"].([]any); ok {
		for _, item := range raw {
			if st, ok := item.(string); ok {
				custom = append(custom, st)
			}
		}
	} else if sl, ok := full["customVocabulary"].([]string); ok {
		custom = sl
	}
	all := uniqueTerms(append(s.speakerVocabulary(ctx, userID), custom...))
	limit := s.cfg().CustomVocabularyMaxTerms
	if limit > 0 && len(all) > limit {
		all = all[:limit]
	}
	return all
}

func (s *Service) storedChunkTargetMs(ctx context.Context, userID string) int {
	var raw string
	if err := s.DB.R.QueryRowContext(ctx, `SELECT value_json FROM user_settings WHERE user_id=? AND key='chunk_target_ms'`, userID).Scan(&raw); err != nil {
		return s.cfg().ChunkTargetMs
	}
	var v int
	if json.Unmarshal([]byte(raw), &v) != nil || v <= 0 {
		return s.cfg().ChunkTargetMs
	}
	return v
}

func (s *Service) Update(ctx context.Context, userID string, input map[string]any) (map[string]any, error) {
	c := s.cfg()
	toStore := map[string]any{}

	getBool := func(k string) (bool, bool, error) {
		raw, ok := input[k]
		if !ok {
			return false, false, nil
		}
		b, ok := raw.(bool)
		if !ok {
			return false, true, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Settings are invalid.")
		}
		return b, true, nil
	}
	getInt := func(k string, minV, maxV int) (int, bool, error) {
		raw, ok := input[k]
		if !ok {
			return 0, false, nil
		}
		f, ok := raw.(float64)
		if !ok || f != float64(int(f)) || int(f) < minV || (maxV >= 0 && int(f) > maxV) {
			return 0, true, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Settings are invalid.")
		}
		return int(f), true, nil
	}

	if v, ok := input["language"]; ok {
		str, isStr := v.(string)
		if !isStr || !slices.Contains(LanguageCodes, str) {
			return nil, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Settings are invalid.")
		}
		toStore["language"] = str
	}
	if iv, ok, err := getInt("consolidationIntervalMs", 0, -1); err != nil {
		return nil, err
	} else if ok {
		toStore["consolidationIntervalMs"] = iv
	}
	if rawTZ, ok := input["timezone"]; ok {
		tz, isStr := rawTZ.(string)
		if !isStr || len(tz) < 1 || len(tz) > 100 {
			return nil, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Settings are invalid.")
		}
		if !timeutil.IsIANATimezone(tz) {
			return nil, httperr.New(http.StatusBadRequest, "INVALID_TIMEZONE", "Timezone must be a valid IANA timezone identifier.")
		}
		toStore["timezone"] = tz
	}
	for _, bk := range []string{
		"recurringSpeakerMatching", "diarizationEnabled", "uploadOnlyOnUnmetered",
		"recordingScheduleEnabled", "keepRawAudio", "vocabularyCorrectionEnabled", "deferredSpeakerResolution",
	} {
		if b, ok, err := getBool(bk); err != nil {
			return nil, err
		} else if ok {
			toStore[bk] = b
		}
	}
	if sm, ok, err := getInt("recordingStartMinute", 0, 1439); err != nil {
		return nil, err
	} else if ok {
		toStore["recordingStartMinute"] = sm
	}
	if em, ok, err := getInt("recordingEndMinute", 0, 1439); err != nil {
		return nil, err
	} else if ok {
		toStore["recordingEndMinute"] = em
	}
	if rd, ok, err := getInt("contextOriginalRetentionDays", 1, 365); err != nil {
		return nil, err
	} else if ok {
		toStore["contextOriginalRetentionDays"] = rd
	}

	if rawVocab, ok := input["customVocabulary"]; ok {
		arr, isArr := rawVocab.([]any)
		if !isArr {
			return nil, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Settings are invalid.")
		}
		if len(arr) > c.CustomVocabularyMaxTerms {
			return nil, httperr.New(http.StatusBadRequest, "CUSTOM_VOCABULARY_TOO_LARGE",
				"Custom vocabulary may contain at most "+itoa(c.CustomVocabularyMaxTerms)+" terms.")
		}
		terms := make([]string, 0, len(arr))
		for _, elem := range arr {
			t, ok := elem.(string)
			t = strings.TrimSpace(t)
			if !ok || t == "" {
				return nil, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Settings are invalid.")
			}
			if len([]rune(t)) > c.CustomVocabularyMaxTermLength {
				return nil, httperr.New(http.StatusBadRequest, "CUSTOM_VOCABULARY_TERM_TOO_LONG",
					"Custom vocabulary terms may contain at most "+itoa(c.CustomVocabularyMaxTermLength)+" characters.")
			}
			terms = append(terms, t)
		}
		toStore["customVocabulary"] = uniqueTerms(terms)
	}

	for _, ik := range []string{"instructionsGlobal", "instructionsMemories", "instructionsSummaries", "instructionsAsk"} {
		if raw, ok := input[ik]; ok {
			str, isStr := raw.(string)
			if !isStr {
				return nil, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Settings are invalid.")
			}
			str = strings.TrimSpace(str)
			if len([]rune(str)) > c.CustomInstructionsMaxChars {
				return nil, httperr.New(http.StatusBadRequest, "CUSTOM_INSTRUCTIONS_TOO_LONG",
					"Custom instructions may contain at most "+itoa(c.CustomInstructionsMaxChars)+" characters.")
			}
			toStore[ik] = str
		}
	}

	if rawCT, ok := input["chunkTargetMs"]; ok {
		f, isNum := rawCT.(float64)
		if !isNum || f != float64(int(f)) {
			return nil, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Settings are invalid.")
		}
		ct := int(f)
		if ct < c.ChunkMinMs || ct > c.ChunkMaxMs {
			return nil, httperr.New(http.StatusBadRequest, "INVALID_CHUNK_DURATION", "Chunk target is outside the server-supported range.")
		}
		toStore["chunkTargetMs"] = ct
	}
	if rawCO, ok := input["chunkOverlapMs"]; ok {
		f, isNum := rawCO.(float64)
		if !isNum || f != float64(int(f)) {
			return nil, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Settings are invalid.")
		}
		co := int(f)
		effTarget := s.storedChunkTargetMs(ctx, userID)
		if v, ok := toStore["chunkTargetMs"].(int); ok {
			effTarget = v
		}
		if co < 0 || co >= effTarget {
			return nil, httperr.New(http.StatusBadRequest, "INVALID_CHUNK_OVERLAP", "Chunk overlap must be non-negative and shorter than the target chunk.")
		}
		toStore["chunkOverlapMs"] = co
	}

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	for apiKey, val := range toStore {
		col := apiToColumn[apiKey]
		b, _ := json.Marshal(val)
		if _, err := tx.ExecContext(ctx, `INSERT INTO user_settings (user_id, key, value_json) VALUES (?, ?, ?)
			ON CONFLICT(user_id, key) DO UPDATE SET value_json=excluded.value_json, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
			userID, col, string(b)); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.Get(ctx, userID)
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

type Routes struct {
	Svc     *Service
	AuthSvc *auth.Service
	Auth    *auth.Authenticator
	Log     *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	wrap := func(scope string, h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireScope(scope, h))
	}
	wrapSess := func(scope string, h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireSession(rt.Auth.RequireScope(scope, h)))
	}

	mux.Handle("GET /api/v1/settings", wrap("settings:read", rt.handleGet))
	mux.Handle("GET /api/v1/settings/", wrap("settings:read", rt.handleGet))
	mux.Handle("PUT /api/v1/settings", wrap("settings:write", rt.handlePut))
	mux.Handle("PUT /api/v1/settings/", wrap("settings:write", rt.handlePut))

	mux.Handle("GET /api/v1/settings/2fa", wrap("settings:read", rt.handle2FAStatus))
	mux.Handle("POST /api/v1/settings/2fa/setup", wrap("settings:write", rt.handle2FASetup))
	mux.Handle("POST /api/v1/settings/2fa/enable", wrap("settings:write", rt.handle2FAEnable))
	mux.Handle("DELETE /api/v1/settings/2fa", wrap("settings:write", rt.handle2FADisable))
	mux.Handle("POST /api/v1/settings/2fa/recovery-codes", wrap("settings:write", rt.handle2FARecoveryCodes))

	mux.Handle("GET /api/v1/settings/security-keys", wrap("settings:read", rt.handleListKeys))
	mux.Handle("POST /api/v1/settings/security-keys/options", wrapSess("settings:write", rt.handleKeysOptions))
	mux.Handle("POST /api/v1/settings/security-keys", wrapSess("settings:write", rt.handleRegisterKey))
	mux.Handle("PUT /api/v1/settings/security-keys/{id}", wrapSess("settings:write", rt.handleRenameKey))
	mux.Handle("DELETE /api/v1/settings/security-keys/{id}", wrapSess("settings:write", rt.handleDeleteKey))
}

func (rt *Routes) handleGet(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	st, err := rt.Svc.Get(r.Context(), a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"settings": st})
}

func (rt *Routes) handlePut(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body map[string]any
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body == nil {
		body = map[string]any{}
	}
	st, err := rt.Svc.Update(r.Context(), a.UserID, body)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"settings": st})
}

func (rt *Routes) handle2FAStatus(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	st, err := rt.AuthSvc.GetTwoFactorStatus(r.Context(), a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, st)
}

func (rt *Routes) handle2FASetup(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	setup, err := rt.AuthSvc.BeginTwoFactor(r.Context(), a.UserID, a.User.Username)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	pngBytes, err := qrcode.Encode(setup.OtpauthURI, qrcode.Medium, 200)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"secret":     setup.Secret,
		"manualKey":  setup.ManualKey,
		"otpauthUri": setup.OtpauthURI,
		"qrDataUrl":  "data:image/png;base64," + base64.StdEncoding.EncodeToString(pngBytes),
	})
}

func (rt *Routes) handle2FAEnable(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		Code string `json:"code"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body.Code == "" {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The request is invalid."))
		return
	}
	codes, err := rt.AuthSvc.ActivateTwoFactor(r.Context(), a.UserID, body.Code)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"ok": true, "recoveryCodes": codes})
}

func (rt *Routes) handle2FADisable(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		Password string `json:"password"`
		Code     string `json:"code"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body.Password == "" {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The request is invalid."))
		return
	}
	if err := rt.AuthSvc.DisableTwoFactor(r.Context(), a.UserID, body.Password, body.Code); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (rt *Routes) handle2FARecoveryCodes(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		Password string `json:"password"`
		Code     string `json:"code"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body.Password == "" || body.Code == "" {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The request is invalid."))
		return
	}
	codes, err := rt.AuthSvc.RegenerateRecoveryCodes(r.Context(), a.UserID, body.Password, body.Code)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"ok": true, "recoveryCodes": codes})
}

func (rt *Routes) handleListKeys(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	creds, err := rt.AuthSvc.ListWebAuthnCredentials(r.Context(), a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"credentials": creds})
}

func (rt *Routes) handleKeysOptions(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	cid, opts, err := rt.AuthSvc.BeginWebAuthnRegistration(r.Context(), r, a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"challengeId": cid, "options": opts})
}

func (rt *Routes) handleRegisterKey(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		ChallengeID string          `json:"challengeId"`
		Response    json.RawMessage `json:"response"`
		Label       string          `json:"label"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body.ChallengeID == "" || len(body.ChallengeID) > 64 || len(body.Response) == 0 || len(body.Label) > 64 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The request is invalid."))
		return
	}
	creds, err := rt.AuthSvc.CompleteWebAuthnRegistration(r.Context(), r, a.UserID, body.ChallengeID, body.Response, body.Label)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"credentials": creds})
}

// keyID is the security key a path names.
func (rt *Routes) keyID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusNotFound, "CREDENTIAL_NOT_FOUND", "This security key does not exist."))
		return 0, false
	}
	return id, true
}

func (rt *Routes) handleRenameKey(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		Label string `json:"label"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if strings.TrimSpace(body.Label) == "" || len(body.Label) > 64 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The request is invalid."))
		return
	}
	id, ok := rt.keyID(w, r)
	if !ok {
		return
	}
	creds, err := rt.AuthSvc.RenameWebAuthnCredential(r.Context(), a.UserID, id, body.Label)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"credentials": creds})
}

func (rt *Routes) handleDeleteKey(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	id, ok := rt.keyID(w, r)
	if !ok {
		return
	}
	creds, err := rt.AuthSvc.DeleteWebAuthnCredential(r.Context(), a.UserID, id)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"credentials": creds})
}
