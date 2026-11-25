package transcription

import (
	"context"
	"sort"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

type TimeRange struct {
	StartMs int64
	EndMs   int64
}

func ParseRangeMs(startAt string, durationMs int) (TimeRange, bool) {
	if durationMs <= 0 {
		return TimeRange{}, false
	}
	t, err := timeutil.ParseISO(startAt)
	if err != nil {
		return TimeRange{}, false
	}
	startMs := t.UnixMilli()
	return TimeRange{StartMs: startMs, EndMs: startMs + int64(durationMs)}, true
}

func RangeOverlapMs(left, right TimeRange) int64 {
	lo := max(left.StartMs, right.StartMs)
	hi := min(left.EndMs, right.EndMs)
	if hi <= lo {
		return 0
	}
	return hi - lo
}

func MergedCoverageMs(target TimeRange, others []TimeRange) int64 {
	var clips []TimeRange
	for _, o := range others {
		if RangeOverlapMs(target, o) <= 0 {
			continue
		}
		clips = append(clips, TimeRange{
			StartMs: max(target.StartMs, o.StartMs),
			EndMs:   min(target.EndMs, o.EndMs),
		})
	}
	sort.Slice(clips, func(i, j int) bool {
		return clips[i].StartMs < clips[j].StartMs
	})
	var covered int64
	cursor := target.StartMs
	for _, clip := range clips {
		if clip.EndMs <= cursor {
			continue
		}
		covered += clip.EndMs - max(cursor, clip.StartMs)
		cursor = clip.EndMs
	}
	return covered
}

// CoverageRatio computes how much of chunk's time range is already covered by
// non-silent processed chunks from other sources on the same recording device.
func CoverageRatio(ctx context.Context, db *dbx.DB, userID, deviceID, sourceID, deviceStartedAt string, durationMs int, requiredRatio float64) float64 {
	target, ok := ParseRangeMs(deviceStartedAt, durationMs)
	if !ok || deviceID == "" || requiredRatio <= 0 {
		return 0
	}
	rows, err := db.R.QueryContext(ctx, `SELECT c.device_started_at, c.duration_ms
		FROM audio_chunks c
		JOIN recording_sessions r ON r.id=c.session_id
		WHERE r.user_id=? AND r.device_id=? AND c.source_id<>?
		  AND c.state IN ('transcribed','persisted_cleanup_pending')
		  AND COALESCE(c.transcript_segment_count,0) > 0
		  AND (julianday(c.device_started_at)-2440587.5)*86400000 < ?
		  AND (julianday(c.device_started_at)-2440587.5)*86400000 + c.duration_ms > ?`,
		userID, deviceID, sourceID, float64(target.EndMs), float64(target.StartMs))
	if err != nil {
		return 0
	}
	defer rows.Close()
	var others []TimeRange
	for rows.Next() {
		var sa string
		var dur int
		if rows.Scan(&sa, &dur) == nil {
			if rg, ok := ParseRangeMs(sa, dur); ok {
				others = append(others, rg)
			}
		}
	}
	return float64(MergedCoverageMs(target, others)) / float64(target.EndMs-target.StartMs)
}

func IsCovered(ctx context.Context, db *dbx.DB, userID, deviceID, sourceID, deviceStartedAt string, durationMs int, requiredRatio float64) bool {
	return CoverageRatio(ctx, db, userID, deviceID, sourceID, deviceStartedAt, durationMs, requiredRatio) >= requiredRatio
}
