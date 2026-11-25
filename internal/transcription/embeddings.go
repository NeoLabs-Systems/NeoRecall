package transcription

import (
	"encoding/binary"
	"math"
)

// CentroidWeightCap matches speaker_embeddings.js so voiceprint centroids keep
// adapting over the lifetime of a recording setup rather than freezing.
const CentroidWeightCap = 50

func VectorFromBytes(b []byte) []float32 {
	if len(b) < 4 {
		return nil
	}
	n := len(b) / 4
	out := make([]float32, n)
	for i := range n {
		out[i] = math.Float32frombits(binary.LittleEndian.Uint32(b[i*4 : (i+1)*4]))
	}
	return out
}

func VectorToBytes(v []float32) []byte {
	if v == nil {
		return nil
	}
	out := make([]byte, len(v)*4)
	for i, f := range v {
		binary.LittleEndian.PutUint32(out[i*4:(i+1)*4], math.Float32bits(f))
	}
	return out
}

func Cosine(left, right []float32) float64 {
	if len(left) == 0 || len(right) == 0 || len(left) != len(right) {
		return -1
	}
	var dot, nl, nr float64
	for i := range left {
		l := float64(left[i])
		r := float64(right[i])
		dot += l * r
		nl += l * l
		nr += r * r
	}
	if nl == 0 || nr == 0 {
		return -1
	}
	return dot / math.Sqrt(nl*nr)
}

func NormalizeVector(v []float32) []float32 {
	if len(v) == 0 {
		return v
	}
	var norm float64
	for _, x := range v {
		f := float64(x)
		norm += f * f
	}
	if norm == 0 {
		return v
	}
	scale := float32(1.0 / math.Sqrt(norm))
	out := make([]float32, len(v))
	for i, x := range v {
		out[i] = x * scale
	}
	return out
}

func UpdateCentroid(existing []float32, existingCount int, sample []float32) []float32 {
	cur := NormalizeVector(existing)
	next := NormalizeVector(sample)
	w := float32(min(max(0, existingCount), CentroidWeightCap))
	out := make([]float32, len(next))
	for i := range next {
		var c float32
		if i < len(cur) {
			c = cur[i]
		}
		out[i] = (c*w + next[i]) / (w + 1)
	}
	return NormalizeVector(out)
}
