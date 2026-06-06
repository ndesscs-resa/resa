// Package database provides storage utilities for encrypted databases.
package database

import (
	"encoding/gob"
	"fmt"
	"io"
	"os"

	"github.com/tuneinsight/lattigo/v5/core/rlwe"
	"github.com/tuneinsight/lattigo/v5/he/hefloat"
)

// SerializedDB represents a serialized encrypted database on disk.
type SerializedDB struct {
	SchemaVersion int
	NumVectors    int
	EmbedDim      int
	Seed          int64
	NumChunks     int
	Slots         int
	ParamID       string
	// Ciphertexts are stored separately in binary format
}

// SaveSecretKey saves the secret key to a file.
func SaveSecretKey(path string, sk *rlwe.SecretKey) error {
	data, err := sk.MarshalBinary()
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0600)
}

// LoadSecretKey loads the secret key from a file.
func LoadSecretKey(path string, params hefloat.Parameters) (*rlwe.SecretKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	sk := rlwe.NewSecretKey(params)
	if err := sk.UnmarshalBinary(data); err != nil {
		return nil, err
	}
	return sk, nil
}

// SaveDBMetadata saves database metadata to a file.
func SaveDBMetadata(path string, encDB *EncodedDB, seed int64, paramID string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	meta := SerializedDB{
		SchemaVersion: 1,
		NumVectors:    encDB.NumVectors,
		EmbedDim:      encDB.EmbedDim,
		Seed:          seed,
		NumChunks:     encDB.NumChunks,
		Slots:         encDB.Slots,
		ParamID:       paramID,
	}

	return gob.NewEncoder(f).Encode(meta)
}

// LoadDBMetadata loads database metadata from a file.
func LoadDBMetadata(path string) (*SerializedDB, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var meta SerializedDB
	if err := gob.NewDecoder(f).Decode(&meta); err != nil {
		return nil, err
	}

	return &meta, nil
}

// ParamID returns the reproducibility-relevant HE parameter identifier.
func ParamID(params hefloat.Parameters) string {
	return fmt.Sprintf("LogN=%d;LogQ=%.0f;Slots=%d;MaxLevel=%d",
		params.LogN(), params.LogQ(), params.N()/2, params.MaxLevel())
}

// Validate checks that a serialized database matches the requested run.
func (m *SerializedDB) Validate(numVectors, embedDim int, seed int64, params hefloat.Parameters) error {
	if m.SchemaVersion != 1 {
		return fmt.Errorf("metadata schema mismatch: got %d, want 1", m.SchemaVersion)
	}
	if m.NumVectors != numVectors {
		return fmt.Errorf("vector-count mismatch: DB has %d, requested %d", m.NumVectors, numVectors)
	}
	if m.EmbedDim != embedDim {
		return fmt.Errorf("embedding-dim mismatch: DB has %d, requested %d", m.EmbedDim, embedDim)
	}
	if m.Seed != seed {
		return fmt.Errorf("seed mismatch: DB was generated with seed %d, requested %d", m.Seed, seed)
	}
	expectedParamID := ParamID(params)
	if m.ParamID != expectedParamID {
		return fmt.Errorf("HE parameter mismatch: DB has %q, requested %q", m.ParamID, expectedParamID)
	}
	if m.Slots != params.N()/2 {
		return fmt.Errorf("slot-count mismatch: DB has %d, params provide %d", m.Slots, params.N()/2)
	}
	return nil
}

// SaveCiphertexts saves all ciphertexts to a binary file.
// Format: sequential ciphertexts in [dim][chunk] order.
func SaveCiphertexts(path string, encDB *EncodedDB) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	for dim := 0; dim < encDB.EmbedDim; dim++ {
		for chunk := 0; chunk < encDB.NumChunks; chunk++ {
			ct := encDB.Ciphertexts[dim][chunk]
			data, err := ct.MarshalBinary()
			if err != nil {
				return fmt.Errorf("marshal error at dim=%d, chunk=%d: %w", dim, chunk, err)
			}

			// Write length prefix + data
			length := int64(len(data))
			if err := writeBinaryInt64(f, length); err != nil {
				return err
			}
			if _, err := f.Write(data); err != nil {
				return err
			}
		}
	}

	return nil
}

// LoadCiphertextsAll loads all ciphertexts into memory.
func LoadCiphertextsAll(path string, params hefloat.Parameters, meta *SerializedDB) (*EncodedDB, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	encDB := &EncodedDB{
		Ciphertexts: make([][]*rlwe.Ciphertext, meta.EmbedDim),
		NumVectors:  meta.NumVectors,
		EmbedDim:    meta.EmbedDim,
		NumChunks:   meta.NumChunks,
		Slots:       meta.Slots,
	}

	for dim := 0; dim < meta.EmbedDim; dim++ {
		encDB.Ciphertexts[dim] = make([]*rlwe.Ciphertext, meta.NumChunks)
		for chunk := 0; chunk < meta.NumChunks; chunk++ {
			ct, err := readCiphertext(f, params)
			if err != nil {
				return nil, fmt.Errorf("read error at dim=%d, chunk=%d: %w", dim, chunk, err)
			}
			encDB.Ciphertexts[dim][chunk] = ct
		}
	}

	return encDB, nil
}

// CiphertextReader provides streaming access to ciphertexts on disk.
type CiphertextReader struct {
	file   *os.File
	params hefloat.Parameters
	meta   *SerializedDB
	dimIdx int
	chkIdx int
}

// NewCiphertextReader creates a streaming reader for ciphertexts.
func NewCiphertextReader(path string, params hefloat.Parameters, meta *SerializedDB) (*CiphertextReader, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}

	return &CiphertextReader{
		file:   f,
		params: params,
		meta:   meta,
		dimIdx: 0,
		chkIdx: 0,
	}, nil
}

// ReadNext reads the next ciphertext and returns its dimension and chunk indices.
// Returns io.EOF when all ciphertexts have been read.
func (r *CiphertextReader) ReadNext() (*rlwe.Ciphertext, int, int, error) {
	if r.dimIdx >= r.meta.EmbedDim {
		return nil, 0, 0, io.EOF
	}

	ct, err := readCiphertext(r.file, r.params)
	if err != nil {
		return nil, 0, 0, err
	}

	dim, chunk := r.dimIdx, r.chkIdx

	// Advance indices
	r.chkIdx++
	if r.chkIdx >= r.meta.NumChunks {
		r.chkIdx = 0
		r.dimIdx++
	}

	return ct, dim, chunk, nil
}

// SeekToDimension seeks to the start of a specific dimension.
// This is useful for restarting reads from a specific point.
func (r *CiphertextReader) SeekToDimension(dim int) error {
	if dim < 0 || dim > r.meta.EmbedDim {
		return fmt.Errorf("dimension %d out of range [0, %d]", dim, r.meta.EmbedDim)
	}
	if err := r.Reset(); err != nil {
		return err
	}
	toSkip := dim * r.meta.NumChunks
	for i := 0; i < toSkip; i++ {
		length, err := readBinaryInt64(r.file)
		if err != nil {
			return fmt.Errorf("read ciphertext length while seeking to dim=%d: %w", dim, err)
		}
		if length < 0 {
			return fmt.Errorf("invalid ciphertext length %d while seeking to dim=%d", length, dim)
		}
		if _, err := r.file.Seek(length, io.SeekCurrent); err != nil {
			return fmt.Errorf("skip ciphertext payload while seeking to dim=%d: %w", dim, err)
		}
	}
	r.dimIdx = dim
	r.chkIdx = 0
	return nil
}

// Close closes the reader.
func (r *CiphertextReader) Close() error {
	return r.file.Close()
}

// Reset resets the reader to the beginning.
func (r *CiphertextReader) Reset() error {
	_, err := r.file.Seek(0, 0)
	if err != nil {
		return err
	}
	r.dimIdx = 0
	r.chkIdx = 0
	return nil
}

// Helper functions

func writeBinaryInt64(w io.Writer, v int64) error {
	buf := make([]byte, 8)
	for i := 0; i < 8; i++ {
		buf[i] = byte(v >> (i * 8))
	}
	_, err := w.Write(buf)
	return err
}

func readBinaryInt64(r io.Reader) (int64, error) {
	buf := make([]byte, 8)
	if _, err := io.ReadFull(r, buf); err != nil {
		return 0, err
	}
	var v int64
	for i := 0; i < 8; i++ {
		v |= int64(buf[i]) << (i * 8)
	}
	return v, nil
}

func readCiphertext(r io.Reader, params hefloat.Parameters) (*rlwe.Ciphertext, error) {
	length, err := readBinaryInt64(r)
	if err != nil {
		return nil, err
	}

	data := make([]byte, length)
	if _, err := io.ReadFull(r, data); err != nil {
		return nil, err
	}

	ct := hefloat.NewCiphertext(params, 1, params.MaxLevel())
	if err := ct.UnmarshalBinary(data); err != nil {
		return nil, err
	}

	return ct, nil
}
