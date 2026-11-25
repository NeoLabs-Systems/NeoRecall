package speakers

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/binary"
	"errors"
	"fmt"
	"os/exec"
	"sort"
	"strings"

	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
)

type PreviewTurn struct {
	VoiceprintID      string
	StartMs           int
	EndMs             int
	Quality           float64
	OverlappingSpeech bool
	SourceComponent   string
}

type PreviewSelection struct {
	Turns      []PreviewTurn
	DurationMs int
	Quality    float64
}

type PreviewData struct {
	VoiceprintID string
	UserID       string
	Audio        []byte
	ContentType  string
	DurationMs   int
	Quality      float64
}

func previewChannelIndex(layout, sourceComponent string) int {
	if layout != "stereo" && layout != "microphone_left_system_right" {
		return 0
	}
	if layout == "microphone_left_system_right" {
		if sourceComponent == "system" {
			return 1
		}
		return 0
	}
	if sourceComponent == "right" {
		return 1
	}
	return 0
}

func SelectPreviewTurns(turns []PreviewTurn, minMs, maxMs int) *PreviewSelection {
	ranked := make([]PreviewTurn, 0, len(turns))
	for _, t := range turns {
		if !t.OverlappingSpeech && t.EndMs > t.StartMs {
			ranked = append(ranked, t)
		}
	}
	sort.SliceStable(ranked, func(i, j int) bool {
		if ranked[i].Quality != ranked[j].Quality {
			return ranked[i].Quality > ranked[j].Quality
		}
		return (ranked[i].EndMs - ranked[i].StartMs) > (ranked[j].EndMs - ranked[j].StartMs)
	})

	var selected []PreviewTurn
	durationMs := 0
	for _, t := range ranked {
		if durationMs >= maxMs {
			break
		}
		avail := t.EndMs - t.StartMs
		used := min(avail, maxMs-durationMs)
		if used <= 0 {
			continue
		}
		cp := t
		cp.EndMs = t.StartMs + used
		selected = append(selected, cp)
		durationMs += used
	}
	if durationMs < minMs {
		return nil
	}
	sort.SliceStable(selected, func(i, j int) bool {
		return selected[i].StartMs < selected[j].StartMs
	})
	var weightedQual float64
	for _, t := range selected {
		weightedQual += t.Quality * float64(max(1, t.EndMs-t.StartMs))
	}
	return &PreviewSelection{
		Turns:      selected,
		DurationMs: durationMs,
		Quality:    weightedQual / float64(durationMs),
	}
}

func wavAudioData(b []byte) (pcm []byte, byteRate int, sampleRate int, ok bool) {
	if len(b) < 44 {
		return nil, 0, 0, false
	}
	offset := 12
	var dataStart, dataSize int
	var hasData bool
	for offset+8 <= len(b) {
		id := string(b[offset : offset+4])
		size := int(binary.LittleEndian.Uint32(b[offset+4 : offset+8]))
		if id == "fmt " && offset+24 <= len(b) {
			sampleRate = int(binary.LittleEndian.Uint32(b[offset+12 : offset+16]))
			byteRate = int(binary.LittleEndian.Uint32(b[offset+16 : offset+20]))
		}
		if id == "data" {
			dataStart = offset + 8
			dataSize = size
			hasData = true
			break
		}
		offset += 8 + size + (size % 2)
	}
	if byteRate <= 0 || !hasData || dataStart > len(b) {
		return nil, 0, 0, false
	}
	end := min(len(b), dataStart+dataSize)
	if sampleRate <= 0 {
		sampleRate = 16000
	}
	return b[dataStart:end], byteRate, sampleRate, true
}

func WavDurationMs(b []byte) int {
	pcm, byteRate, _, ok := wavAudioData(b)
	if !ok || byteRate <= 0 {
		return 0
	}
	return int((len(pcm) * 1000) / byteRate)
}

func wrapMonoPCMWav(pcm []byte, sampleRate int) []byte {
	out := make([]byte, 44+len(pcm))
	copy(out[0:4], "RIFF")
	binary.LittleEndian.PutUint32(out[4:8], uint32(36+len(pcm)))
	copy(out[8:12], "WAVE")
	copy(out[12:16], "fmt ")
	binary.LittleEndian.PutUint32(out[16:20], 16)
	binary.LittleEndian.PutUint16(out[20:22], 1)
	binary.LittleEndian.PutUint16(out[22:24], 1)
	binary.LittleEndian.PutUint32(out[24:28], uint32(sampleRate))
	binary.LittleEndian.PutUint32(out[28:32], uint32(sampleRate*2))
	binary.LittleEndian.PutUint16(out[32:34], 2)
	binary.LittleEndian.PutUint16(out[34:36], 16)
	copy(out[36:40], "data")
	binary.LittleEndian.PutUint32(out[40:44], uint32(len(pcm)))
	copy(out[44:], pcm)
	return out
}

func ConcatPreviewAudio(first, second []byte, maxDurationMs int) ([]byte, error) {
	lPCM, _, sr, okL := wavAudioData(first)
	rPCM, _, _, okR := wavAudioData(second)
	if !okL || !okR {
		return nil, errors.New("SPEAKER_PREVIEW_FAILED: speaker preview audio is not a readable WAV clip")
	}
	maxBytes := (maxDurationMs * sr / 1000) * 2
	rem := max(0, maxBytes-len(lPCM))
	takeLen := min(len(rPCM), rem-(rem%2))
	buf := make([]byte, len(lPCM)+takeLen)
	copy(buf, lPCM)
	if takeLen > 0 {
		copy(buf[len(lPCM):], rPCM[:takeLen])
	}
	return wrapMonoPCMWav(buf, sr), nil
}

func ShouldReplacePreview(curDurationMs int, curQuality float64, selDurationMs int, selQuality float64, targetDurationMs int) bool {
	curFull := curDurationMs >= targetDurationMs
	selFull := selDurationMs >= targetDurationMs
	if curFull != selFull {
		return selFull
	}
	return selQuality > curQuality
}

func capPreviewSelection(sel *PreviewSelection, remMs int) *PreviewSelection {
	if sel == nil || remMs <= 0 {
		return nil
	}
	if sel.DurationMs <= remMs {
		return sel
	}
	used := 0
	var turns []PreviewTurn
	for _, t := range sel.Turns {
		if used >= remMs {
			break
		}
		avail := t.EndMs - t.StartMs
		take := min(avail, remMs-used)
		if take <= 0 {
			continue
		}
		cp := t
		cp.EndMs = t.StartMs + take
		turns = append(turns, cp)
		used += take
	}
	if used <= 0 {
		return nil
	}
	var wQual float64
	for _, t := range turns {
		wQual += t.Quality * float64(max(1, t.EndMs-t.StartMs))
	}
	return &PreviewSelection{Turns: turns, DurationMs: used, Quality: wQual / float64(used)}
}

func ExtractPreview(ctx context.Context, ffmpegPath string, key []byte, audioWorkDir, filename, layout string, sel *PreviewSelection, maxBytes int64) ([]byte, error) {
	if ffmpegPath == "" {
		return nil, errors.New("SPEAKER_PREVIEW_FAILED: ffmpeg binary not found")
	}
	var outBytes []byte
	err := crypto.WithPlain(key, audioWorkDir, filename, func(plainPath string) error {
		var filters []string
		var inputs strings.Builder
		for i, t := range sel.Turns {
			ch := previewChannelIndex(layout, t.SourceComponent)
			filters = append(filters, fmt.Sprintf("[0:a]atrim=start=%.3f:end=%.3f,asetpts=PTS-STARTPTS,pan=mono|c0=c%d[p%d]",
				float64(t.StartMs)/1000.0, float64(t.EndMs)/1000.0, ch, i))
			fmt.Fprintf(&inputs, "[p%d]", i)
		}
		filters = append(filters, fmt.Sprintf("%sconcat=n=%d:v=0:a=1[out]", inputs.String(), len(sel.Turns)))
		cmd := exec.CommandContext(ctx, ffmpegPath,
			"-v", "error", "-i", plainPath,
			"-filter_complex", strings.Join(filters, ";"),
			"-map", "[out]", "-ar", "16000", "-c:a", "pcm_s16le", "-f", "wav", "pipe:1",
		)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil || stdout.Len() == 0 {
			return fmt.Errorf("SPEAKER_PREVIEW_FAILED: ffmpeg could not create the speaker preview: %s", stderr.String())
		}
		b := stdout.Bytes()
		if maxBytes > 0 && int64(len(b)) > maxBytes {
			b = b[:maxBytes]
		}
		if len(b) >= 44 && string(b[0:4]) == "RIFF" && string(b[8:12]) == "WAVE" {
			binary.LittleEndian.PutUint32(b[4:8], uint32(len(b)-8))
			if off := bytes.Index(b[12:], []byte("data")); off >= 0 {
				dOff := 12 + off
				if dOff+8 <= len(b) {
					binary.LittleEndian.PutUint32(b[dOff+4:dOff+8], uint32(len(b)-dOff-8))
				}
			}
		}
		outBytes = b
		return nil
	})
	return outBytes, err
}

func (s *Service) CapturePreviewsFromChunk(ctx context.Context, userID, chunkID, temporaryPath, channelLayout string) (int, error) {
	if temporaryPath == "" {
		return 0, nil
	}
	c := s.cfg()
	key, err := s.MasterKey()
	if err != nil {
		return 0, err
	}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT st.voiceprint_id, st.start_ms, st.end_ms, st.quality, st.overlapping_speech,
		COALESCE(ts.source_component, 'combined') AS source_component
		FROM speaker_turns st
		LEFT JOIN transcript_segments ts
			ON ts.chunk_id=st.chunk_id AND ts.speaker_cluster_id=st.cluster_id
			AND ts.chunk_start_ms=st.start_ms AND ts.chunk_end_ms=st.end_ms
		WHERE st.chunk_id=? AND st.voiceprint_id IS NOT NULL
		ORDER BY st.start_ms`, chunkID)
	if err != nil {
		return 0, err
	}
	grouped := make(map[string][]PreviewTurn)
	var vpOrder []string
	for rows.Next() {
		var t PreviewTurn
		var ov int
		if rows.Scan(&t.VoiceprintID, &t.StartMs, &t.EndMs, &t.Quality, &ov, &t.SourceComponent) == nil {
			t.OverlappingSpeech = ov != 0
			if _, ok := grouped[t.VoiceprintID]; !ok {
				vpOrder = append(vpOrder, t.VoiceprintID)
			}
			grouped[t.VoiceprintID] = append(grouped[t.VoiceprintID], t)
		}
	}
	rows.Close()

	captured := 0
	for _, vpID := range vpOrder {
		sel := SelectPreviewTurns(grouped[vpID], c.SpeakerPreviewMinimumMs, c.SpeakerPreviewMaximumMs)
		if sel == nil {
			continue
		}
		var curDur int
		var curQual float64
		var curBlob []byte
		curErr := s.DB.R.QueryRowContext(ctx, `SELECT duration_ms, quality, audio FROM speaker_previews WHERE voiceprint_id=?`, vpID).
			Scan(&curDur, &curQual, &curBlob)

		var audio []byte
		var durMs int
		var qual float64
		if errors.Is(curErr, sql.ErrNoRows) {
			audio, err = ExtractPreview(ctx, s.FFmpegPath, key, c.Paths.AudioWork, temporaryPath, channelLayout, sel, c.SpeakerPreviewMaxBytes)
			if err != nil {
				return captured, err
			}
			durMs = WavDurationMs(audio)
			if durMs == 0 {
				durMs = sel.DurationMs
			}
			qual = sel.Quality
		} else if curErr == nil {
			existing, err := ReadPreviewAudio(key, curBlob)
			if err != nil {
				return captured, err
			}
			curMs := WavDurationMs(existing)
			if curMs == 0 {
				curMs = curDur
			}
			if curMs >= c.SpeakerPreviewMaximumMs {
				if !ShouldReplacePreview(curMs, curQual, sel.DurationMs, sel.Quality, c.SpeakerPreviewMaximumMs) {
					continue
				}
				audio, err = ExtractPreview(ctx, s.FFmpegPath, key, c.Paths.AudioWork, temporaryPath, channelLayout, sel, c.SpeakerPreviewMaxBytes)
				if err != nil {
					return captured, err
				}
				durMs = WavDurationMs(audio)
				if durMs == 0 {
					durMs = sel.DurationMs
				}
				qual = sel.Quality
			} else if sel.DurationMs >= c.SpeakerPreviewMaximumMs {
				audio, err = ExtractPreview(ctx, s.FFmpegPath, key, c.Paths.AudioWork, temporaryPath, channelLayout, sel, c.SpeakerPreviewMaxBytes)
				if err != nil {
					return captured, err
				}
				durMs = WavDurationMs(audio)
				if durMs == 0 {
					durMs = sel.DurationMs
				}
				qual = sel.Quality
			} else {
				remMs := c.SpeakerPreviewMaximumMs - curMs
				addition := capPreviewSelection(sel, remMs+100)
				if addition == nil {
					continue
				}
				extra, err := ExtractPreview(ctx, s.FFmpegPath, key, c.Paths.AudioWork, temporaryPath, channelLayout, addition, c.SpeakerPreviewMaxBytes)
				if err != nil {
					return captured, err
				}
				audio, err = ConcatPreviewAudio(existing, extra, c.SpeakerPreviewMaximumMs)
				if err != nil {
					return captured, err
				}
				durMs = WavDurationMs(audio)
				if durMs <= curMs {
					continue
				}
				addedMs := durMs - curMs
				qual = (curQual*float64(curMs) + addition.Quality*float64(addedMs)) / float64(durMs)
			}
		} else {
			return captured, curErr
		}

		sealed, err := SealPreviewAudio(key, audio)
		if err != nil {
			return captured, err
		}
		clamped := max(c.SpeakerPreviewMinimumMs, min(c.SpeakerPreviewMaximumMs, durMs))
		if _, err := s.DB.W.ExecContext(ctx, `INSERT INTO speaker_previews
			(voiceprint_id, user_id, audio, content_type, duration_ms, quality)
			VALUES (?, ?, ?, 'audio/wav', ?, ?)
			ON CONFLICT(voiceprint_id) DO UPDATE SET
				audio=excluded.audio, content_type=excluded.content_type, duration_ms=excluded.duration_ms,
				quality=excluded.quality, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
			vpID, userID, sealed, clamped, qual); err != nil {
			return captured, err
		}
		captured++
	}
	return captured, nil
}

func (s *Service) GetPreview(ctx context.Context, userID, voiceprintID string) (*PreviewData, error) {
	key, err := s.MasterKey()
	if err != nil {
		return nil, err
	}
	var p PreviewData
	var sealed []byte
	err = s.DB.R.QueryRowContext(ctx, `SELECT p.voiceprint_id, p.user_id, p.audio, p.content_type, p.duration_ms, p.quality
		FROM speaker_previews p JOIN voiceprints v ON v.id=p.voiceprint_id
		WHERE p.voiceprint_id=? AND p.user_id=? AND v.user_id=?`, voiceprintID, userID, userID).
		Scan(&p.VoiceprintID, &p.UserID, &sealed, &p.ContentType, &p.DurationMs, &p.Quality)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	plain, err := ReadPreviewAudio(key, sealed)
	if err != nil {
		return nil, err
	}
	p.Audio = plain
	return &p, nil
}
