package search

import (
	"math"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

func ExponentialRecency(occurredAt string, now time.Time, halfLifeDays float64) float64 {
	if halfLifeDays <= 0 {
		halfLifeDays = 30
	}
	t, err := timeutil.ParseISO(occurredAt)
	if err != nil {
		return 0
	}
	ageDays := max(0.0, now.Sub(t).Hours()/24.0)
	return math.Exp(-math.Log(2) * ageDays / halfLifeDays)
}

func Score(relevance float64, occurredAt string, importance int, w config.SearchWeights, halfLifeDays float64, now time.Time) float64 {
	normImp := min(1.0, max(0.0, float64(importance)/10.0))
	recency := ExponentialRecency(occurredAt, now, halfLifeDays)
	return w.Relevance*relevance + w.Recency*recency + w.Importance*normImp
}
