// Package database provides vector database encoding for HE.
package database

import (
	"fmt"

	"github.com/tuneinsight/lattigo/v5/core/rlwe"
	"github.com/tuneinsight/lattigo/v5/he/hefloat"

	"github.com/ndesscs-resa/resa/baselines/ckks_error/pkg/he"
)

// EncodedDB represents an encrypted database with column-major layout.
// Layout: encDB[dim][chunk] where:
//   - dim: embedding dimension index (0 to embeddingDim-1)
//   - chunk: groups of N/2 vectors packed into one ciphertext
//
// This layout enables efficient const x ctxt inner product:
//
//	result[chunk] += query[dim] * encDB[dim][chunk]
type EncodedDB struct {
	Ciphertexts [][]*rlwe.Ciphertext // [dim][chunk]
	NumVectors  int
	EmbedDim    int
	NumChunks   int
	Slots       int // N/2, vectors per ciphertext
}

// EncodeDB encrypts a plaintext database into column-major ciphertexts.
// db: plaintext database [numVectors][embeddingDim]
// Returns: encrypted database [embeddingDim][numChunks]
func EncodeDB(db [][]float64, params hefloat.Parameters, sk *rlwe.SecretKey, progressFn func(dim, total int)) (*EncodedDB, error) {
	numVectors := len(db)
	if numVectors == 0 {
		return nil, fmt.Errorf("empty database")
	}
	embeddingDim := len(db[0])

	slots := he.Slots(params)
	numChunks := he.NumChunks(params, numVectors)

	encoder := hefloat.NewEncoder(params)
	encryptor := rlwe.NewEncryptor(params, sk)

	// Allocate result: encDB[dim][chunk]
	encDB := make([][]*rlwe.Ciphertext, embeddingDim)

	for dim := 0; dim < embeddingDim; dim++ {
		encDB[dim] = make([]*rlwe.Ciphertext, numChunks)

		for chunk := 0; chunk < numChunks; chunk++ {
			// Gather values for this chunk: all vectors' dim-th component
			values := make([]complex128, slots)
			for i := 0; i < slots; i++ {
				vecIdx := chunk*slots + i
				if vecIdx < numVectors {
					values[i] = complex(db[vecIdx][dim], 0)
				}
				// Remaining slots are zero-padded
			}

			// Encode at scale Delta_ctxt = 2^26 (paper Section 4.4)
			pt := hefloat.NewPlaintext(params, params.MaxLevel())
			// Default scale from params is 2^26, which is correct
			if err := encoder.Encode(values, pt); err != nil {
				return nil, fmt.Errorf("encode error at dim=%d, chunk=%d: %w", dim, chunk, err)
			}

			ct, err := encryptor.EncryptNew(pt)
			if err != nil {
				return nil, fmt.Errorf("encrypt error at dim=%d, chunk=%d: %w", dim, chunk, err)
			}

			encDB[dim][chunk] = ct
		}

		if progressFn != nil {
			progressFn(dim+1, embeddingDim)
		}
	}

	return &EncodedDB{
		Ciphertexts: encDB,
		NumVectors:  numVectors,
		EmbedDim:    embeddingDim,
		NumChunks:   numChunks,
		Slots:       slots,
	}, nil
}

// MemorySize returns the approximate memory size of the encoded database in bytes.
func (e *EncodedDB) MemorySize(params hefloat.Parameters) int64 {
	ctSize := he.CiphertextSize(params)
	totalCts := int64(e.EmbedDim) * int64(e.NumChunks)
	return totalCts * int64(ctSize)
}
