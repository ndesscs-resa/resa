// Package benchmark provides timing measurement utilities.
package benchmark

import (
	"fmt"
	"time"
)

// Timer provides simple latency measurement.
type Timer struct {
	start time.Time
	name  string
}

// NewTimer creates and starts a new timer.
func NewTimer(name string) *Timer {
	return &Timer{
		start: time.Now(),
		name:  name,
	}
}

// Elapsed returns the elapsed time since the timer started.
func (t *Timer) Elapsed() time.Duration {
	return time.Since(t.start)
}

// Stop returns the elapsed time and prints a message.
func (t *Timer) Stop() time.Duration {
	elapsed := t.Elapsed()
	fmt.Printf("[%s] Elapsed: %v\n", t.name, elapsed)
	return elapsed
}

// Reset resets the timer to now.
func (t *Timer) Reset() {
	t.start = time.Now()
}

// BenchmarkResult holds benchmark results.
type BenchmarkResult struct {
	Name            string        `json:"name"`
	NumVectors      int           `json:"num_vectors"`
	EmbeddingDim    int           `json:"embedding_dim"`
	Latency         time.Duration `json:"latency_ns"`
	LatencySeconds  float64       `json:"latency_seconds"`
	PeakMemoryBytes uint64        `json:"peak_memory_bytes"`
	PeakMemoryGB    float64       `json:"peak_memory_gb"`
	Throughput      float64       `json:"throughput_qps"` // Queries per second
}

// NewBenchmarkResult creates a new benchmark result.
func NewBenchmarkResult(name string, numVectors, embeddingDim int, latency time.Duration, peakMemory uint64) *BenchmarkResult {
	latencySec := latency.Seconds()
	return &BenchmarkResult{
		Name:            name,
		NumVectors:      numVectors,
		EmbeddingDim:    embeddingDim,
		Latency:         latency,
		LatencySeconds:  latencySec,
		PeakMemoryBytes: peakMemory,
		PeakMemoryGB:    BytesToGB(peakMemory),
		Throughput:      1.0 / latencySec,
	}
}

// String returns a formatted string representation of the result.
func (r *BenchmarkResult) String() string {
	return fmt.Sprintf(
		"%s: %d vectors, d=%d, Latency=%.3fs, Memory=%s (%.2f GB), Throughput=%.3f QPS",
		r.Name,
		r.NumVectors,
		r.EmbeddingDim,
		r.LatencySeconds,
		FormatBytes(r.PeakMemoryBytes),
		r.PeakMemoryGB,
		r.Throughput,
	)
}
