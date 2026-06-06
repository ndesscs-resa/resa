// Package he provides HE operations for const x ctxt multiplication.
//
// Uses asymmetric scale splitting from the paper (Section 4.4):
//   - DB ciphertexts encoded at scale Delta_ctxt = 2^26
//   - Query scalars encoded as plaintexts at scale Delta_const = 2^23
//   - Product scale = 2^49 < Q (single 51-bit prime), no rescaling needed
package he

import (
	"github.com/tuneinsight/lattigo/v5/core/rlwe"
	"github.com/tuneinsight/lattigo/v5/he/hefloat"
)

// Evaluator wraps Lattigo evaluator for const x ctxt operations.
// This is the core operation needed for encrypted inner product.
type Evaluator struct {
	params    hefloat.Parameters
	sk        *rlwe.SecretKey
	eval      *hefloat.Evaluator
	encoder   *hefloat.Encoder
	encryptor *rlwe.Encryptor
	decryptor *rlwe.Decryptor
}

// NewEvaluator creates a new evaluator for const x ctxt operations.
// No relinearization key is needed since we only do scalar multiplication.
func NewEvaluator(params hefloat.Parameters, sk *rlwe.SecretKey) *Evaluator {
	eval := hefloat.NewEvaluator(params, nil)
	encoder := hefloat.NewEncoder(params)
	encryptor := rlwe.NewEncryptor(params, sk)
	decryptor := rlwe.NewDecryptor(params, sk)

	return &Evaluator{
		params:    params,
		sk:        sk,
		eval:      eval,
		encoder:   encoder,
		encryptor: encryptor,
		decryptor: decryptor,
	}
}

// Encoder returns the encoder for external use.
func (e *Evaluator) Encoder() *hefloat.Encoder {
	return e.encoder
}

// Encryptor returns the encryptor for external use.
func (e *Evaluator) Encryptor() *rlwe.Encryptor {
	return e.encryptor
}

// NewFreshEncryptor creates an encryptor with a fresh PRNG.
// Long validation runs use this to keep sampler state local to a query-sized
// HE validation call.
func (e *Evaluator) NewFreshEncryptor() *rlwe.Encryptor {
	return rlwe.NewEncryptor(e.params, e.sk)
}

// NewFreshEncoder creates an encoder for a query-sized HE validation call.
func (e *Evaluator) NewFreshEncoder() *hefloat.Encoder {
	return hefloat.NewEncoder(e.params)
}

// Decryptor returns the decryptor for external use.
func (e *Evaluator) Decryptor() *rlwe.Decryptor {
	return e.decryptor
}

// Params returns the parameters.
func (e *Evaluator) Params() hefloat.Parameters {
	return e.params
}

// EncodeQueryScalar encodes a single query scalar value into a plaintext
// at scale Delta_const = 2^23 (paper Section 4.4).
// The plaintext is broadcast to all slots.
func (e *Evaluator) EncodeQueryScalar(scalar float64) (*rlwe.Plaintext, error) {
	pt := hefloat.NewPlaintext(e.params, e.params.MaxLevel())
	// Set the plaintext scale to Delta_const = 2^23
	pt.Scale = ScaleConst

	slots := Slots(e.params)
	values := make([]complex128, slots)
	for i := range values {
		values[i] = complex(scalar, 0)
	}

	if err := e.encoder.Encode(values, pt); err != nil {
		return nil, err
	}

	return pt, nil
}

// MulConstAndAdd performs result += scalar * ct (fused multiply-add).
// This is the core operation for encrypted inner product:
//
//	for each dimension i: result += query[i] * database[i]
//
// Uses asymmetric scale: ct at scale 2^26, scalar encoded as plaintext at scale 2^23.
// Result accumulates at scale 2^49.
//
// The scalar is passed as a pre-encoded plaintext from EncodeQueryScalar so
// Lattigo uses the paper's explicit scalar scale.
func (e *Evaluator) MulConstAndAdd(result *rlwe.Ciphertext, scalarPt *rlwe.Plaintext, ct *rlwe.Ciphertext) error {
	// MulThenAdd with plaintext operand: result += ct * scalarPt
	// Result scale = ct.Scale * scalarPt.Scale = 2^26 * 2^23 = 2^49
	return e.eval.MulThenAdd(ct, scalarPt, result)
}

// MulConstAndAddScalar performs result += scalar * ct using a raw float64 scalar.
// This is a convenience method that encodes the scalar internally.
// For repeated use with the same scalar, prefer EncodeQueryScalar + MulConstAndAdd.
func (e *Evaluator) MulConstAndAddScalar(result *rlwe.Ciphertext, scalar float64, ct *rlwe.Ciphertext) error {
	pt, err := e.EncodeQueryScalar(scalar)
	if err != nil {
		return err
	}
	return e.MulConstAndAdd(result, pt, ct)
}

// MulConst performs scalar * ct and returns a new ciphertext.
// The scalar is encoded at scale 2^23 (Delta_const).
func (e *Evaluator) MulConst(scalar float64, ct *rlwe.Ciphertext) (*rlwe.Ciphertext, error) {
	pt, err := e.EncodeQueryScalar(scalar)
	if err != nil {
		return nil, err
	}
	result, err := e.eval.MulNew(ct, pt)
	if err != nil {
		return nil, err
	}
	return result, nil
}

// Add performs ct1 + ct2 and stores the result in ct1.
func (e *Evaluator) AddInPlace(ct1, ct2 *rlwe.Ciphertext) error {
	return e.eval.Add(ct1, ct2, ct1)
}

// EncryptValues encrypts a slice of float64 values into a ciphertext.
// Values are encoded at the default scale (Delta_ctxt = 2^26).
func (e *Evaluator) EncryptValues(values []float64) (*rlwe.Ciphertext, error) {
	pt := hefloat.NewPlaintext(e.params, e.params.MaxLevel())
	// Scale is default = 2^26 (LogDefaultScale)

	complex128Values := make([]complex128, len(values))
	for i, v := range values {
		complex128Values[i] = complex(v, 0)
	}

	if err := e.encoder.Encode(complex128Values, pt); err != nil {
		return nil, err
	}

	return e.encryptor.EncryptNew(pt)
}

// DecryptValues decrypts a ciphertext and returns the float64 values.
func (e *Evaluator) DecryptValues(ct *rlwe.Ciphertext, numSlots int) ([]float64, error) {
	pt := e.decryptor.DecryptNew(ct)

	complex128Values := make([]complex128, numSlots)
	if err := e.encoder.Decode(pt, complex128Values); err != nil {
		return nil, err
	}

	result := make([]float64, numSlots)
	for i, v := range complex128Values {
		result[i] = real(v)
	}

	return result, nil
}

// NewZeroCiphertext creates a zero-initialized ciphertext for accumulation.
// The ciphertext is at scale 2^49 (product scale) to match MulConstAndAdd output.
func (e *Evaluator) NewZeroCiphertext() (*rlwe.Ciphertext, error) {
	pt := hefloat.NewPlaintext(e.params, e.params.MaxLevel())
	// Set scale to product scale 2^49 so it matches the accumulation scale
	pt.Scale = ScaleResult

	slots := Slots(e.params)
	zeros := make([]complex128, slots)
	if err := e.encoder.Encode(zeros, pt); err != nil {
		return nil, err
	}

	return e.encryptor.EncryptNew(pt)
}
