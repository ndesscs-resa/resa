// Package database provides vector database generation and encoding.
package database

import (
	"math"
	"math/rand"
)

// GenerateDB creates a random vector database with reproducible seed.
// Returns db[numVectors][embeddingDim] with standard normal distribution.
func GenerateDB(numVectors, embeddingDim int, seed int64) [][]float64 {
	rng := rand.New(rand.NewSource(seed))

	db := make([][]float64, numVectors)
	for i := 0; i < numVectors; i++ {
		db[i] = make([]float64, embeddingDim)
		for j := 0; j < embeddingDim; j++ {
			db[i][j] = rng.NormFloat64()
		}
	}

	return db
}

// GenerateDBFloat32 creates a random vector database with float32 for memory efficiency.
// This is useful for fp32 plaintext storage estimates.
func GenerateDBFloat32(numVectors, embeddingDim int, seed int64) [][]float32 {
	rng := rand.New(rand.NewSource(seed))

	db := make([][]float32, numVectors)
	for i := 0; i < numVectors; i++ {
		db[i] = make([]float32, embeddingDim)
		for j := 0; j < embeddingDim; j++ {
			db[i][j] = float32(rng.NormFloat64())
		}
	}

	return db
}

// GenerateQuery creates a random query vector with reproducible seed.
func GenerateQuery(embeddingDim int, seed int64) []float64 {
	rng := rand.New(rand.NewSource(seed))

	query := make([]float64, embeddingDim)
	for j := 0; j < embeddingDim; j++ {
		query[j] = rng.NormFloat64()
	}

	return query
}

// NormalizeL2 normalizes a vector to unit L2 norm in-place.
func NormalizeL2(vec []float64) {
	var norm float64
	for _, v := range vec {
		norm += v * v
	}
	if norm > 0 {
		norm = 1.0 / math.Sqrt(norm)
		for i := range vec {
			vec[i] *= norm
		}
	}
}

// DotProduct computes the dot product of two vectors.
func DotProduct(a, b []float64) float64 {
	var sum float64
	for i := range a {
		sum += a[i] * b[i]
	}
	return sum
}

// DotProductFloat32 computes the dot product of two float32 vectors.
func DotProductFloat32(a, b []float32) float32 {
	var sum float32
	for i := range a {
		sum += a[i] * b[i]
	}
	return sum
}
