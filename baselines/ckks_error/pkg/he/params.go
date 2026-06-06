// Package he provides HE parameter configuration matching the paper (Section 4.4).
//
// Paper design: single 51-bit Solinas prime Q = 2^51 - 2^17 + 1.
// Asymmetric scale splitting:
//   - Delta_ctxt = 2^26 (DB embedding encoding scale)
//   - Delta_const = 2^23 (query scalar encoding scale)
//   - Product scale = 2^49 < 2^51, fits in single prime without rescaling
package he

import (
	"math"

	"github.com/tuneinsight/lattigo/v5/core/rlwe"
	"github.com/tuneinsight/lattigo/v5/he/hefloat"
	"github.com/tuneinsight/lattigo/v5/ring"
)

// Configuration constants
const (
	LogN         = 12 // Ring degree N = 4096
	EmbeddingDim = 768
	NumVectors   = 1e6

	// Asymmetric scale constants (Section 4.4)
	LogScaleCtxt  = 26 // DB embedding encoding scale: 2^26
	LogScaleConst = 23 // Query scalar encoding scale: 2^23
	// Product scale = 2^(26+23) = 2^49 < 2^51 single prime
)

var (
	ScaleCtxt   = rlwe.NewScale(math.Exp2(LogScaleCtxt))                 // 2^26
	ScaleConst  = rlwe.NewScale(math.Exp2(LogScaleConst))                // 2^23
	ScaleResult = rlwe.NewScale(math.Exp2(LogScaleCtxt + LogScaleConst)) // 2^49
)

// Slots returns the number of SIMD slots (N/2 for CKKS)
func Slots(params hefloat.Parameters) int {
	return params.N() / 2
}

// NewParameters creates HE parameters matching the paper configuration.
// N=4096, single 51-bit prime, no rescaling needed.
//
// Paper specifies Solinas prime Q = 2^51 - 2^17 + 1, but Lattigo generates
// NTT-friendly primes automatically. We use LogQ=[51] to get a single
// NTT-friendly 51-bit prime. The asymmetric scale design ensures
// product scale 2^49 < Q regardless of the exact prime value.
func NewParameters() (hefloat.Parameters, error) {
	return hefloat.NewParametersFromLiteral(hefloat.ParametersLiteral{
		LogN:            LogN,
		LogQ:            []int{51},    // Single 51-bit prime (paper: Q = 2^51 - 2^17 + 1)
		LogP:            []int{},      // No special modulus (no relin needed)
		LogDefaultScale: LogScaleCtxt, // Default scale = 2^26 (DB encoding)
		RingType:        ring.Standard,
	})
}

// CiphertextSize returns the approximate size of a ciphertext in bytes.
func CiphertextSize(params hefloat.Parameters) int {
	// Ciphertext = 2 polynomials * N coefficients * ceil(logQ/8) bytes
	N := params.N()
	logQ := params.LogQ() // total bits across all primes
	bytesPerCoeff := (logQ + 7) / 8
	return 2 * N * int(bytesPerCoeff)
}

// NumChunks calculates the number of ciphertexts needed to store M vectors.
// Each ciphertext can hold N/2 values using SIMD packing.
func NumChunks(params hefloat.Parameters, numVectors int) int {
	slots := Slots(params)
	return (numVectors + slots - 1) / slots
}

// TotalCiphertexts returns the total number of ciphertexts for the encrypted database.
// Layout: [dimension][chunk] where dimension is embedding_dim and chunk packs multiple vectors.
func TotalCiphertexts(params hefloat.Parameters, numVectors, embeddingDim int) int {
	return NumChunks(params, numVectors) * embeddingDim
}

// EstimatedDatabaseSize returns the estimated size of the encrypted database in bytes.
func EstimatedDatabaseSize(params hefloat.Parameters, numVectors, embeddingDim int) int64 {
	totalCts := TotalCiphertexts(params, numVectors, embeddingDim)
	ctSize := CiphertextSize(params)
	return int64(totalCts) * int64(ctSize)
}
