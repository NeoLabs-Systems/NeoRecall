package speakers

import (
	"sort"

	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

// SealCentroid seals a float32 centroid vector using AES-256-GCM (0x01|iv|tag|ct)
// so stored voiceprint biometrics cannot be read directly from the SQLite file.
func SealCentroid(key []byte, vec []float32) ([]byte, error) {
	if len(vec) == 0 {
		return nil, nil
	}
	return crypto.SealBuffer(key, transcription.VectorToBytes(vec))
}

// ReadCentroid unseals (or passes through legacy unsealed) centroid bytes.
func ReadCentroid(key []byte, blob []byte) ([]float32, error) {
	if len(blob) == 0 {
		return nil, nil
	}
	return transcription.VectorFromBytes(crypto.UnsealBuffer(key, blob)), nil
}

func SealPreviewAudio(key []byte, audio []byte) ([]byte, error) {
	if len(audio) == 0 {
		return nil, nil
	}
	return crypto.SealBuffer(key, audio)
}

func ReadPreviewAudio(key []byte, blob []byte) ([]byte, error) {
	if len(blob) == 0 {
		return nil, nil
	}
	return crypto.UnsealBuffer(key, blob), nil
}

type VoiceprintScore struct {
	Row   VoiceprintRow
	Score float64
}

func RankVoiceprints(key []byte, vec []float32, rows []VoiceprintRow) []VoiceprintScore {
	scored := make([]VoiceprintScore, 0, len(rows))
	for _, row := range rows {
		centroid, err := ReadCentroid(key, row.CentroidEmbedding)
		score := -1.0
		if err == nil && len(centroid) > 0 {
			score = transcription.Cosine(vec, centroid)
		}
		scored = append(scored, VoiceprintScore{Row: row, Score: score})
	}
	sort.SliceStable(scored, func(i, j int) bool {
		return scored[i].Score > scored[j].Score
	})
	return scored
}
