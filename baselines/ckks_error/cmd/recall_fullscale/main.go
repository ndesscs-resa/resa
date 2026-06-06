// Recall@K benchmark for full-scale datasets.
//
// Strategy: Full-scale plaintext + HE numerical validation
// - Plaintext scores computed for ALL vectors (ground truth)
// - HE scores computed either for random samples or for full-corpus top-k boundary candidates
// - Reported HE recall/MRR is computed within the evaluated candidate set
//
// Rationale:
// - CKKS noise is independent of database size (depends only on dimension sum)
// - CKKS error is measured directly on evaluated candidates for each dataset/run
// - Full-corpus score gaps are computed from plaintext rankings
// - Boundary mode validates the ranking candidates selected by the full-corpus scan
//
// Parallelization:
// - Corpus is streamed once in batches (I/O efficient - each batch read once)
// - For each corpus batch, worker goroutines compute dot products for query subsets
// - Each query maintains a top-K heap (memory efficient - no full score arrays)
// - All queries processed per corpus pass (single sequential read of corpus file)
//
// Usage:
//   ./recall_fullscale --dataset beir-cohere --queries 0
//   ./recall_fullscale --dataset msmarco-distilbert --queries 0 --workers 16

package main

import (
	"container/heap"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"math/rand"
	"os"
	"runtime"
	"sort"
	"sync"
	"time"

	"github.com/tuneinsight/lattigo/v5/core/rlwe"
	"github.com/tuneinsight/lattigo/v5/he/hefloat"

	"github.com/ndesscs-resa/resa/baselines/ckks_error/pkg/benchmark"
	"github.com/ndesscs-resa/resa/baselines/ckks_error/pkg/he"
)

// FullScaleResult holds comprehensive benchmark results.
type FullScaleResult struct {
	Implementation string `json:"implementation"`
	Dataset        string `json:"dataset"`
	Model          string `json:"model"`
	NumVectors     int    `json:"num_vectors"`
	NumQueries     int    `json:"num_queries"`
	Dim            int    `json:"dim"`
	Params         struct {
		N     int    `json:"N"`
		LogQ  string `json:"logQ"`
		Scale string `json:"scale"`
	} `json:"params"`
	// HE numerical validation (sampled vectors or full-corpus boundary candidates)
	HEValidationMode     string  `json:"he_validation_mode"`
	HECandidateSource    string  `json:"he_candidate_source"`
	HECandidateCount     int     `json:"he_candidate_count"`
	HECandidateCountPerQ int     `json:"he_candidate_count_per_query"`
	HESampleSize         int     `json:"he_sample_size"`
	HEMaxError           float64 `json:"he_max_error"`
	HEMeanError          float64 `json:"he_mean_error"`
	HEStdError           float64 `json:"he_std_error"`
	HERankCorrelation    float64 `json:"he_rank_correlation"`
	HESampleRecall1      float64 `json:"he_sample_recall@1"`
	HESampleRecall10     float64 `json:"he_sample_recall@10"`
	HESampleMRR10        float64 `json:"he_sample_mrr@10"`
	PaperMetric          string  `json:"paper_metric"`
	PaperMRR10           float64 `json:"paper_mrr@10"`
	HECandidateRecall1   float64 `json:"he_candidate_recall@1"`
	HECandidateRecall10  float64 `json:"he_candidate_recall@10"`
	HECandidateMRR10     float64 `json:"he_candidate_mrr@10"`
	ScoreGapMin          float64 `json:"score_gap_min"`
	ScoreGapMean         float64 `json:"score_gap_mean"`
	SafetyMargin         float64 `json:"safety_margin"` // score_gap / noise
	RuntimeSecondsTotal  float64 `json:"runtime_seconds_total"`
	PeakMemoryGB         float64 `json:"peak_memory_gb"`
	Workers              int     `json:"workers"`
	Reproducibility      struct {
		Seed       int64  `json:"seed"`
		GoVersion  string `json:"go_version"`
		NumCPU     int    `json:"num_cpu"`
		LattigoVer string `json:"lattigo_version"`
	} `json:"reproducibility"`
}

// scorePair holds a vector index and its score for top-K tracking.
type scorePair struct {
	idx   int
	score float64
}

// minHeap implements a min-heap of scorePairs (for top-K tracking).
// The smallest score is at the root, so we can efficiently evict it.
type minHeap []scorePair

func (h minHeap) Len() int            { return len(h) }
func (h minHeap) Less(i, j int) bool  { return h[i].score < h[j].score }
func (h minHeap) Swap(i, j int)       { h[i], h[j] = h[j], h[i] }
func (h *minHeap) Push(x interface{}) { *h = append(*h, x.(scorePair)) }
func (h *minHeap) Pop() interface{} {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[:n-1]
	return x
}

// topKTracker maintains the top-K highest-scoring items efficiently.
type topKTracker struct {
	k    int
	heap minHeap
}

func newTopKTracker(k int) *topKTracker {
	h := make(minHeap, 0, k+1)
	return &topKTracker{k: k, heap: h}
}

func (t *topKTracker) Add(idx int, score float64) {
	if t.heap.Len() < t.k {
		heap.Push(&t.heap, scorePair{idx, score})
	} else if score > t.heap[0].score {
		t.heap[0] = scorePair{idx, score}
		heap.Fix(&t.heap, 0)
	}
}

// Results returns the top-K items sorted by score descending.
func (t *topKTracker) Results() []scorePair {
	result := make([]scorePair, len(t.heap))
	copy(result, t.heap)
	sort.Slice(result, func(i, j int) bool {
		return result[i].score > result[j].score
	})
	return result
}

// Float64ArrayFile provides read-only seek/read access to a binary float64 array file.
type Float64ArrayFile struct {
	file    *os.File
	numRows uint64
	numCols uint64
}

// OpenFloat64Array opens a binary file with header [numRows, numCols uint64] + data.
func OpenFloat64Array(path string) (*Float64ArrayFile, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}

	var numRows, numCols uint64
	if err := binary.Read(f, binary.LittleEndian, &numRows); err != nil {
		f.Close()
		return nil, fmt.Errorf("read numRows: %w", err)
	}
	if err := binary.Read(f, binary.LittleEndian, &numCols); err != nil {
		f.Close()
		return nil, fmt.Errorf("read numCols: %w", err)
	}

	return &Float64ArrayFile{
		file:    f,
		numRows: numRows,
		numCols: numCols,
	}, nil
}

func (f *Float64ArrayFile) Close() error {
	return f.file.Close()
}

func (f *Float64ArrayFile) NumRows() int { return int(f.numRows) }
func (f *Float64ArrayFile) NumCols() int { return int(f.numCols) }

// ReadRow reads a single row from the file.
func (f *Float64ArrayFile) ReadRow(idx int) ([]float64, error) {
	if idx < 0 || idx >= int(f.numRows) {
		return nil, fmt.Errorf("row index out of range: %d", idx)
	}

	offset := int64(16) + int64(idx)*int64(f.numCols)*8
	if _, err := f.file.Seek(offset, io.SeekStart); err != nil {
		return nil, err
	}

	row := make([]float64, f.numCols)
	if err := binary.Read(f.file, binary.LittleEndian, row); err != nil {
		return nil, err
	}

	return row, nil
}

// ReadRows reads a batch of rows.
func (f *Float64ArrayFile) ReadRows(startIdx, count int) ([][]float64, error) {
	if startIdx < 0 || startIdx+count > int(f.numRows) {
		return nil, fmt.Errorf("row range out of bounds: [%d, %d)", startIdx, startIdx+count)
	}

	offset := int64(16) + int64(startIdx)*int64(f.numCols)*8
	if _, err := f.file.Seek(offset, io.SeekStart); err != nil {
		return nil, err
	}

	rows := make([][]float64, count)
	for i := 0; i < count; i++ {
		rows[i] = make([]float64, f.numCols)
		if err := binary.Read(f.file, binary.LittleEndian, rows[i]); err != nil {
			return nil, fmt.Errorf("read row %d: %w", startIdx+i, err)
		}
	}

	return rows, nil
}

// ReadRowsFlat reads a batch of rows into a contiguous flat slice for cache efficiency.
// Returns flat[i*cols + j] = row[i][j].
func (f *Float64ArrayFile) ReadRowsFlat(startIdx, count int) ([]float64, error) {
	if startIdx < 0 || startIdx+count > int(f.numRows) {
		return nil, fmt.Errorf("row range out of bounds: [%d, %d)", startIdx, startIdx+count)
	}

	offset := int64(16) + int64(startIdx)*int64(f.numCols)*8
	if _, err := f.file.Seek(offset, io.SeekStart); err != nil {
		return nil, err
	}

	cols := int(f.numCols)
	flat := make([]float64, count*cols)
	if err := binary.Read(f.file, binary.LittleEndian, flat); err != nil {
		return nil, fmt.Errorf("read rows %d-%d: %w", startIdx, startIdx+count-1, err)
	}

	return flat, nil
}

func main() {
	// Parse flags
	datasetName := flag.String("dataset", "msmarco-distilbert", "Dataset: beir-cohere, msmarco-distilbert, nq")
	dataDir := flag.String("data-dir", "", "Data directory (default: auto-detect)")
	numQueries := flag.Int("queries", 0, "Number of queries (0 = use all available)")
	outputPath := flag.String("output", "", "Output JSON path")
	verbose := flag.Bool("verbose", false, "Print detailed per-query results")
	seed := flag.Int64("seed", 42, "Random seed for reproducibility")
	batchSize := flag.Int("batch", 10000, "Batch size for corpus streaming")
	heMode := flag.String("he-mode", "sample", "HE validation mode: sample or boundary")
	heSampleSize := flag.Int("he-sample", 1000, "Sample size for HE verification")
	heBoundaryK := flag.Int("he-boundary-k", 20, "Number of full-corpus top candidates per query for boundary HE validation")
	numWorkers := flag.Int("workers", runtime.NumCPU(), "Number of worker goroutines for parallel score computation")
	flag.Parse()

	rand.Seed(*seed)

	// Cap workers to reasonable range
	if *numWorkers < 1 {
		*numWorkers = 1
	}
	maxWorkers := runtime.NumCPU() * 2
	if *numWorkers > maxWorkers {
		*numWorkers = maxWorkers
	}
	if *heMode != "sample" && *heMode != "boundary" {
		fmt.Printf("ERROR: invalid --he-mode=%q; expected sample or boundary\n", *heMode)
		os.Exit(1)
	}
	if *heBoundaryK < 2 {
		fmt.Println("ERROR: --he-boundary-k must be at least 2")
		os.Exit(1)
	}

	// Auto-detect data directory
	if *dataDir == "" {
		// Check environment variable first
		if envDir := os.Getenv("CSD_DATA_DIR"); envDir != "" {
			*dataDir = envDir
		} else {
			// Try relative paths
			candidates := []string{
				"../../experiments/recall-benchmark/data",
				"../../../experiments/recall-benchmark/data",
				"./data",
			}
			for _, dir := range candidates {
				if _, err := os.Stat(dir); err == nil {
					*dataDir = dir
					break
				}
			}
			if *dataDir == "" {
				fmt.Println("ERROR: Data directory not found. Please specify --data-dir or set CSD_DATA_DIR")
				os.Exit(1)
			}
		}
	}

	if *outputPath == "" {
		*outputPath = fmt.Sprintf("results/recall_fullscale_%s_v3.json", *datasetName)
	}

	// Dataset configuration
	var corpusBinPath, queriesBinPath, modelName string
	var expectedDim int

	switch *datasetName {
	case "beir-cohere":
		corpusBinPath = *dataDir + "/beir_cohere_fullscale.corpus.bin"
		queriesBinPath = *dataDir + "/beir_cohere_fullscale.queries.bin"
		modelName = "Cohere-embed-english-v3"
		expectedDim = 1024
	case "msmarco-distilbert":
		corpusBinPath = *dataDir + "/msmarco_distilbert_fullscale.corpus.bin"
		queriesBinPath = *dataDir + "/msmarco_distilbert_fullscale.queries.bin"
		modelName = "msmarco-distilbert-cos-v5"
		expectedDim = 768
	case "nq":
		corpusBinPath = *dataDir + "/nq_distilbert.corpus.bin"
		queriesBinPath = *dataDir + "/nq_distilbert.queries.bin"
		modelName = "msmarco-distilbert-cos-v5"
		expectedDim = 768
	default:
		fmt.Printf("Unknown dataset: %s\n", *datasetName)
		os.Exit(1)
	}

	fmt.Println("=== Full-scale Recall@K Benchmark ===")
	fmt.Println("Strategy: Plaintext full-scale + HE numerical validation")
	fmt.Println("Mode: Parallel query processing (all queries scored per corpus batch)")
	fmt.Printf("\nConfiguration:\n")
	fmt.Printf("  Dataset: %s\n", *datasetName)
	fmt.Printf("  Model: %s\n", modelName)
	fmt.Printf("  Batch size: %d\n", *batchSize)
	fmt.Printf("  Workers: %d\n", *numWorkers)
	fmt.Printf("  HE mode: %s\n", *heMode)
	if *heMode == "sample" {
		fmt.Printf("  HE sample: %d\n", *heSampleSize)
	} else {
		fmt.Printf("  HE boundary candidates/query: %d\n", *heBoundaryK)
	}
	fmt.Printf("  Seed: %d\n", *seed)

	// Open corpus file
	fmt.Println("\n[1] Opening corpus file...")
	corpus, err := OpenFloat64Array(corpusBinPath)
	if err != nil {
		fmt.Printf("Error opening corpus: %v\n", err)
		os.Exit(1)
	}
	defer corpus.Close()

	numVectors := corpus.NumRows()
	dim := corpus.NumCols()

	if dim != expectedDim {
		fmt.Printf("Dimension mismatch: expected %d, got %d\n", expectedDim, dim)
		os.Exit(1)
	}

	fmt.Printf("  Corpus: %d vectors x %d dims\n", numVectors, dim)
	fmt.Printf("  Size: %.2f GB\n", float64(numVectors)*float64(dim)*8/1_000_000_000.0)

	// Open queries file
	fmt.Println("\n[2] Loading queries...")
	queries, err := OpenFloat64Array(queriesBinPath)
	if err != nil {
		fmt.Printf("Error opening queries: %v\n", err)
		os.Exit(1)
	}
	defer queries.Close()

	totalQueries := queries.NumRows()
	if *numQueries <= 0 || *numQueries > totalQueries {
		*numQueries = totalQueries
	}
	fmt.Printf("  Available: %d queries\n", totalQueries)
	fmt.Printf("  Using: %d queries\n", *numQueries)

	queryVecs, err := queries.ReadRows(0, *numQueries)
	if err != nil {
		fmt.Printf("Error loading queries: %v\n", err)
		os.Exit(1)
	}

	// Flatten query vectors for cache-friendly access
	queryFlat := make([]float64, *numQueries*dim)
	for i, q := range queryVecs {
		copy(queryFlat[i*dim:], q)
	}

	// Initialize HE for sample verification
	fmt.Println("\n[3] Initializing HE parameters...")
	params, err := he.NewParameters()
	if err != nil {
		fmt.Printf("Error creating parameters: %v\n", err)
		os.Exit(1)
	}

	kgen := rlwe.NewKeyGenerator(params)
	sk := kgen.GenSecretKeyNew()
	eval := he.NewEvaluator(params, sk)

	fmt.Printf("  Ring degree N: %d\n", params.N())
	fmt.Printf("  SIMD slots: %d\n", he.Slots(params))

	// Optional random sample for HE verification. Boundary mode derives its HE
	// candidates from the full-corpus top-k results after the plaintext scan.
	if *heMode == "sample" && *heSampleSize > numVectors {
		*heSampleSize = numVectors
	}
	var sampleVecs [][]float64
	sampleLookup := make(map[int][]int)
	if *heMode == "sample" {
		fmt.Printf("\n[4] Selecting %d random vectors for HE verification...\n", *heSampleSize)
		sampleIndices := make([]int, *heSampleSize)
		for i := range sampleIndices {
			sampleIndices[i] = rand.Intn(numVectors)
		}
		sort.Ints(sampleIndices)

		// Build sample lookup: corpus_idx -> position in sampleIndices
		sampleLookup = make(map[int][]int, *heSampleSize)
		for i, idx := range sampleIndices {
			sampleLookup[idx] = append(sampleLookup[idx], i)
		}

		// Load sampled vectors for HE verification
		sampleVecs = make([][]float64, *heSampleSize)
		for i, idx := range sampleIndices {
			sampleVecs[i], err = corpus.ReadRow(idx)
			if err != nil {
				fmt.Printf("Error reading sample vector %d: %v\n", idx, err)
				os.Exit(1)
			}
		}
	} else {
		fmt.Printf("\n[4] HE boundary mode enabled; candidates will come from full-corpus top-%d results.\n", *heBoundaryK)
	}

	baseline := benchmark.ForceGC()
	fmt.Printf("  Baseline memory: %s\n", benchmark.FormatBytes(baseline.VmRSS))

	// ==============================
	// Phase 1: Parallel plaintext scoring with top-K tracking
	// ==============================
	// Strategy: stream corpus once, compute ALL queries' scores simultaneously.
	// Each query maintains a top-K=20 heap (enough for score gap analysis).
	// Sample scores are accumulated separately for HE verification.
	topK := 20 // Track top-20 for score gap analysis (top1 vs top11)
	if *heMode == "boundary" && *heBoundaryK > topK {
		topK = *heBoundaryK
	}

	fmt.Printf("\n[5] Running %d queries against %d vectors (%d workers)...\n",
		*numQueries, numVectors, *numWorkers)

	// Per-query trackers (one per query)
	topTrackers := make([]*topKTracker, *numQueries)
	for q := 0; q < *numQueries; q++ {
		topTrackers[q] = newTopKTracker(topK)
	}

	// Per-query sample scores: sampleScores[q][sampleIdx] = dot product.
	// Boundary mode uses topResultsByQuery after the full scan instead.
	var sampleScores [][]float64
	if *heMode == "sample" {
		sampleScores = make([][]float64, *numQueries)
		for q := 0; q < *numQueries; q++ {
			sampleScores[q] = make([]float64, *heSampleSize)
		}
	}

	startTime := time.Now()

	// Stream corpus in batches, scoring all queries per batch
	totalBatches := (numVectors + *batchSize - 1) / *batchSize
	for batchIdx := 0; batchIdx < totalBatches; batchIdx++ {
		batchStart := batchIdx * *batchSize
		batchEnd := batchStart + *batchSize
		if batchEnd > numVectors {
			batchEnd = numVectors
		}
		batchCount := batchEnd - batchStart

		// Read corpus batch (single I/O operation, flat for cache efficiency)
		corpusBatchFlat, err := corpus.ReadRowsFlat(batchStart, batchCount)
		if err != nil {
			fmt.Printf("Error reading corpus batch: %v\n", err)
			os.Exit(1)
		}

		// Find which sample indices fall in this batch
		type sampleHit struct {
			corpusIdx int // absolute corpus index
			samplePos int // position in sampleIndices
			batchOff  int // offset within this batch
		}
		var batchSampleHits []sampleHit
		for corpIdx, positions := range sampleLookup {
			if corpIdx >= batchStart && corpIdx < batchEnd {
				for _, pos := range positions {
					batchSampleHits = append(batchSampleHits, sampleHit{
						corpusIdx: corpIdx,
						samplePos: pos,
						batchOff:  corpIdx - batchStart,
					})
				}
			}
		}

		// Parallel: distribute queries across workers
		var wg sync.WaitGroup
		queriesPerWorker := (*numQueries + *numWorkers - 1) / *numWorkers

		for w := 0; w < *numWorkers; w++ {
			qStart := w * queriesPerWorker
			qEnd := qStart + queriesPerWorker
			if qEnd > *numQueries {
				qEnd = *numQueries
			}
			if qStart >= qEnd {
				break
			}

			wg.Add(1)
			go func(qStart, qEnd, batchStart, batchCount, dim int) {
				defer wg.Done()
				for q := qStart; q < qEnd; q++ {
					qOff := q * dim
					tracker := topTrackers[q]

					// Compute dot products for all corpus vectors in this batch
					for i := 0; i < batchCount; i++ {
						vOff := i * dim
						var sum float64
						for j := 0; j < dim; j++ {
							sum += corpusBatchFlat[vOff+j] * queryFlat[qOff+j]
						}
						tracker.Add(batchStart+i, sum)
					}

					// Accumulate sample scores that fall in this batch
					for _, hit := range batchSampleHits {
						vOff := hit.batchOff * dim
						var sum float64
						for j := 0; j < dim; j++ {
							sum += corpusBatchFlat[vOff+j] * queryFlat[qOff+j]
						}
						sampleScores[q][hit.samplePos] = sum
					}
				}
			}(qStart, qEnd, batchStart, batchCount, dim)
		}
		wg.Wait()

		// Progress reporting (every ~5% or on last batch)
		elapsed := time.Since(startTime)
		progress := float64(batchEnd) / float64(numVectors) * 100
		prevProgress := float64(batchStart) / float64(numVectors) * 100
		if batchEnd >= numVectors || int(progress/5) > int(prevProgress/5) {
			if batchEnd < numVectors {
				eta := time.Duration(float64(elapsed) / float64(batchEnd) * float64(numVectors-batchEnd))
				fmt.Printf("  Corpus progress: %d/%d vectors (%.1f%%), ETA: %v\n",
					batchEnd, numVectors, progress, eta.Round(time.Second))
			} else {
				fmt.Printf("  Corpus progress: %d/%d vectors (100.0%%)\n", batchEnd, numVectors)
			}
		}
	}

	corpusScanTime := time.Since(startTime)
	fmt.Printf("  Corpus scan complete in %v\n", corpusScanTime.Round(time.Second))

	// ==============================
	// Phase 2: Score gap analysis (from plaintext top-K results)
	// ==============================
	fmt.Println("\n[6] Computing rank-1 to rank-11 score gaps from plaintext top-K results...")

	scoreGaps := make([]float64, *numQueries)
	topResultsByQuery := make([][]scorePair, *numQueries)
	for q := 0; q < *numQueries; q++ {
		topResults := topTrackers[q].Results()
		topResultsByQuery[q] = topResults
		if len(topResults) > 10 {
			// Gap between rank 1 and rank 11. This is not an adjacent top-k gap.
			scoreGaps[q] = topResults[0].score - topResults[10].score
		}
	}

	// Free top trackers (no longer needed)
	topTrackers = nil

	// ==============================
	// Phase 3: HE verification (serial - Lattigo not goroutine-safe)
	// ==============================
	heCandidateCountPerQuery := *heSampleSize
	heCandidateSource := "random-sample"
	if *heMode == "boundary" {
		heCandidateCountPerQuery = *heBoundaryK
		heCandidateSource = "full-corpus-topk-boundary"
	}
	resultSampleSize := *heSampleSize
	if *heMode == "boundary" {
		resultSampleSize = 0
	}
	fmt.Printf("\n[7] HE validation on %s candidates (%d/query, %d queries, serial)...\n",
		heCandidateSource, heCandidateCountPerQuery, *numQueries)

	type heResult struct {
		maxErr         float64
		sumErr         float64
		sumErrSq       float64
		corr           float64
		r1             bool
		r10            bool
		reciprocalRank float64 // 1/rank if plaintext top-1 is in HE top-10, else 0
	}

	heResults := make([]heResult, *numQueries)
	heTotalScores := 0

	for q := 0; q < *numQueries; q++ {
		// Periodic GC to reduce memory pressure during HE phase.
		// Each query creates ~1025 ciphertexts that become garbage after use.
		// Without periodic GC, the heap grows unbounded on large datasets.
		if q > 0 && q%100 == 0 {
			runtime.GC()
		}

		var candidateVecs [][]float64
		var candidateScores []float64
		if *heMode == "sample" {
			candidateVecs = sampleVecs
			candidateScores = sampleScores[q]
		} else {
			topResults := topResultsByQuery[q]
			count := *heBoundaryK
			if count > len(topResults) {
				count = len(topResults)
			}
			candidateVecs = make([][]float64, count)
			candidateScores = make([]float64, count)
			for i := 0; i < count; i++ {
				candidateVecs[i], err = corpus.ReadRow(topResults[i].idx)
				if err != nil {
					fmt.Printf("Error reading boundary candidate vector %d: %v\n", topResults[i].idx, err)
					os.Exit(1)
				}
				candidateScores[i] = topResults[i].score
			}
		}
		if len(candidateVecs) == 0 {
			fmt.Printf("FATAL: no HE validation candidates for query %d/%d\n", q+1, *numQueries)
			os.Exit(1)
		}
		heTotalScores += len(candidateVecs)

		// Compute HE scores for candidate vectors. A failure here is reported
		// directly because the result bundle should only contain completed HE
		// validations.
		heScores, heErr := computeHEScoresSample(eval, params, queryVecs[q], candidateVecs)
		if heErr != nil {
			fmt.Printf("FATAL: HE computation failed at query %d/%d: %v\n", q+1, *numQueries, heErr)
			os.Exit(1)
		}

		// Compare with plaintext candidate scores
		var maxErr, sumErr, sumErrSq float64
		for i := 0; i < len(candidateScores); i++ {
			e := math.Abs(candidateScores[i] - heScores[i])
			if e > maxErr {
				maxErr = e
			}
			sumErr += e
			sumErrSq += e * e
		}
		heResults[q].maxErr = maxErr
		heResults[q].sumErr = sumErr
		heResults[q].sumErrSq = sumErrSq

		// Rank correlation on the evaluated candidate set.
		sPlainRank := rankIndices(candidateScores)
		sHERank := rankIndices(heScores)
		heResults[q].corr = spearmanCorrelation(sPlainRank, sHERank)

		// HE recall within the evaluated candidate set.
		heResults[q].r1 = containsInTop(sHERank, sPlainRank[0], 1)
		heResults[q].r10 = containsInTop(sHERank, sPlainRank[0], 10)

		// MRR@10: find rank of plaintext top-1 in HE ranking
		heResults[q].reciprocalRank = 0.0
		for rank := 0; rank < len(sHERank) && rank < 10; rank++ {
			if sHERank[rank] == sPlainRank[0] {
				heResults[q].reciprocalRank = 1.0 / float64(rank+1) // rank is 0-indexed, MRR uses 1-indexed
				break
			}
		}

		if (q+1)%500 == 0 || q+1 == *numQueries {
			fmt.Printf("  HE progress: %d/%d queries\n", q+1, *numQueries)
		}

		if *verbose {
			fmt.Printf("  Query %d: gap=%.4f maxHEerr=%.2e\n", q+1, scoreGaps[q], maxErr)
		}
	}

	heCompletedQueries := *numQueries

	// Free sample scores (no longer needed)
	sampleScores = nil

	// ==============================
	// Phase 4: Aggregate metrics
	// ==============================
	fmt.Println("\n[8] Aggregating metrics...")

	var (
		sumScoreGap         float64
		minScoreGap         = math.MaxFloat64
		heMaxError          float64
		heSumError          float64
		heSumErrorSq        float64
		heSumCorr           float64
		heRecall1Count      int
		heRecall10Count     int
		heSumReciprocalRank float64
	)

	for q := 0; q < *numQueries; q++ {
		sumScoreGap += scoreGaps[q]
		if scoreGaps[q] < minScoreGap {
			minScoreGap = scoreGaps[q]
		}

		r := heResults[q]
		if r.maxErr > heMaxError {
			heMaxError = r.maxErr
		}
		heSumError += r.sumErr
		heSumErrorSq += r.sumErrSq
		heSumCorr += r.corr
		if r.r1 {
			heRecall1Count++
		}
		if r.r10 {
			heRecall10Count++
		}
		heSumReciprocalRank += r.reciprocalRank
	}

	var heMeanError, heStdError, heMeanCorr, heSampleR1, heSampleR10, heSampleMRR10 float64
	if heTotalScores > 0 {
		heMeanError = heSumError / float64(heTotalScores)
		heStdError = math.Sqrt(heSumErrorSq/float64(heTotalScores) - heMeanError*heMeanError)
	}
	if heCompletedQueries > 0 {
		heMeanCorr = heSumCorr / float64(heCompletedQueries)
		heSampleR1 = float64(heRecall1Count) / float64(heCompletedQueries)
		heSampleR10 = float64(heRecall10Count) / float64(heCompletedQueries)
		heSampleMRR10 = heSumReciprocalRank / float64(heCompletedQueries)
	}
	meanScoreGap := sumScoreGap / float64(*numQueries)
	var safetyMargin float64
	if heMaxError > 0 {
		safetyMargin = minScoreGap / heMaxError
	} else {
		safetyMargin = math.Inf(1) // No HE error observed
	}

	totalTime := time.Since(startTime)

	finalStats := benchmark.ForceGC()
	peakMemory := finalStats.VmHWM

	// Build result
	result := FullScaleResult{
		Implementation:       "Lattigo v5 (Full-Scale CKKS)",
		Dataset:              *datasetName,
		Model:                modelName,
		NumVectors:           numVectors,
		NumQueries:           *numQueries,
		Dim:                  dim,
		HEValidationMode:     *heMode,
		HECandidateSource:    heCandidateSource,
		HECandidateCount:     heTotalScores,
		HECandidateCountPerQ: heCandidateCountPerQuery,
		HESampleSize:         resultSampleSize,
		HEMaxError:           heMaxError,
		HEMeanError:          heMeanError,
		HEStdError:           heStdError,
		HERankCorrelation:    heMeanCorr,
		HESampleRecall1:      heSampleR1,
		HESampleRecall10:     heSampleR10,
		HESampleMRR10:        heSampleMRR10,
		PaperMetric:          "MRR@10",
		PaperMRR10:           heSampleMRR10,
		HECandidateRecall1:   heSampleR1,
		HECandidateRecall10:  heSampleR10,
		HECandidateMRR10:     heSampleMRR10,
		ScoreGapMin:          minScoreGap,
		ScoreGapMean:         meanScoreGap,
		SafetyMargin:         safetyMargin,
		RuntimeSecondsTotal:  totalTime.Seconds(),
		PeakMemoryGB:         benchmark.BytesToGB(peakMemory),
		Workers:              *numWorkers,
	}
	result.Params.N = params.N()
	result.Params.LogQ = "51"
	result.Params.Scale = "ctxt=2^26, const=2^23, product=2^49"
	result.Reproducibility.Seed = *seed
	result.Reproducibility.GoVersion = runtime.Version()
	result.Reproducibility.NumCPU = runtime.NumCPU()
	result.Reproducibility.LattigoVer = "v5.0.7"

	// Print summary
	fmt.Println("\n=== Results ===")
	fmt.Printf("Dataset: %s (%s)\n", *datasetName, modelName)
	fmt.Printf("Configuration: %d vectors, %d queries, %d-dim, %d workers\n",
		numVectors, *numQueries, dim, *numWorkers)

	fmt.Printf("\nHE Recall (within %s candidates):\n", heCandidateSource)
	fmt.Printf("  Recall@1:   %.2f%%\n", heSampleR1*100)
	fmt.Printf("  Recall@10:  %.2f%%\n", heSampleR10*100)
	fmt.Printf("  MRR@10:     %.6f\n", heSampleMRR10)
	fmt.Printf("  Paper metric: MRR@10 = %.6f\n", heSampleMRR10)

	fmt.Printf("\nHE Numerical Validation (%d total candidates):\n", heTotalScores)
	fmt.Printf("  Max Error:       %.2e\n", heMaxError)
	fmt.Printf("  Mean Error:      %.2e\n", heMeanError)
	fmt.Printf("  Std Error:       %.2e\n", heStdError)
	fmt.Printf("  Rank Corr:       %.6f\n", heMeanCorr)
	fmt.Printf("  Candidate Recall@1: %.2f%%\n", heSampleR1*100)
	fmt.Printf("  Candidate Recall@10:%.2f%%\n", heSampleR10*100)
	fmt.Printf("  Candidate MRR@10:   %.6f\n", heSampleMRR10)

	fmt.Printf("\nScore Gap Analysis:\n")
	fmt.Printf("  Min Gap (Top1-Top11): %.4f\n", minScoreGap)
	fmt.Printf("  Mean Gap:             %.4f\n", meanScoreGap)
	fmt.Printf("  Safety Margin:        %.2e (gap/noise)\n", safetyMargin)

	fmt.Printf("\nPerformance:\n")
	fmt.Printf("  Corpus Scan:  %v\n", corpusScanTime.Round(time.Second))
	fmt.Printf("  Total Time:   %v\n", totalTime.Round(time.Second))
	fmt.Printf("  Peak Memory:  %.2f GB\n", benchmark.BytesToGB(peakMemory))

	// Key finding
	fmt.Println("\n=== Key Finding ===")
	if safetyMargin > 1e6 {
		fmt.Println("HE numerical validation passed with a large plaintext score-gap margin")
		fmt.Printf("Safety margin %.2e compares the full-corpus top1-top11 gap against observed HE error\n", safetyMargin)
	} else if safetyMargin > 100 {
		fmt.Println("HE numerical validation passed with a practical score-gap margin")
	} else {
		fmt.Println("NOTE: score-gap margin is small; inspect near-tie queries separately")
	}

	// Save results
	os.MkdirAll("results", 0755)
	jsonData, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		fmt.Printf("Error marshaling JSON: %v\n", err)
		os.Exit(1)
	}

	if err := os.WriteFile(*outputPath, jsonData, 0644); err != nil {
		fmt.Printf("Error writing results: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("\nResults saved to: %s\n", *outputPath)
}

// computeHEScoresSample computes HE inner products for sampled vectors.
// Uses asymmetric scale: DB at 2^26, query at 2^23, result at 2^49.
//
// Creates a fresh encryptor and encoder per call so long validation runs keep
// Lattigo sampler state local to each query. Each fresh encryptor gets a new
// PRNG seeded from crypto/rand.
//
// Encoding and encryption in this helper use the per-call fresh instances; the
// shared Evaluator encoder/encryptor remain available for shorter helper paths.
func computeHEScoresSample(eval *he.Evaluator, params hefloat.Parameters, query []float64, sampleVecs [][]float64) ([]float64, error) {
	numVecs := len(sampleVecs)
	dim := len(query)
	slots := he.Slots(params)

	numChunks := (numVecs + slots - 1) / slots

	// Create fresh encryptor and encoder per query-sized call.
	// Each fresh encryptor gets a new PRNG seeded from crypto/rand.
	encryptor := eval.NewFreshEncryptor()
	encoder := eval.NewFreshEncoder()

	// Helper: encrypt zero ciphertext at product scale using fresh encryptor
	encryptZeroAtProductScale := func() (*rlwe.Ciphertext, error) {
		pt := hefloat.NewPlaintext(params, params.MaxLevel())
		pt.Scale = he.ScaleResult
		zeros := make([]complex128, slots)
		if err := encoder.Encode(zeros, pt); err != nil {
			return nil, err
		}
		return encryptor.EncryptNew(pt)
	}

	// Helper: encode query scalar using the per-call fresh encoder.
	encodeQueryScalar := func(scalar float64) (*rlwe.Plaintext, error) {
		pt := hefloat.NewPlaintext(params, params.MaxLevel())
		pt.Scale = he.ScaleConst
		values := make([]complex128, slots)
		for i := range values {
			values[i] = complex(scalar, 0)
		}
		if err := encoder.Encode(values, pt); err != nil {
			return nil, err
		}
		return pt, nil
	}

	results := make([]*rlwe.Ciphertext, numChunks)
	for chunk := 0; chunk < numChunks; chunk++ {
		var err error
		results[chunk], err = encryptZeroAtProductScale()
		if err != nil {
			return nil, fmt.Errorf("zero ciphertext: %w", err)
		}
	}

	for d := 0; d < dim; d++ {
		scalarPt, err := encodeQueryScalar(query[d])
		if err != nil {
			return nil, fmt.Errorf("encode query scalar dim=%d: %w", d, err)
		}

		for chunk := 0; chunk < numChunks; chunk++ {
			values := make([]complex128, slots)
			for i := 0; i < slots; i++ {
				vecIdx := chunk*slots + i
				if vecIdx < numVecs {
					values[i] = complex(sampleVecs[vecIdx][d], 0)
				}
			}

			pt := hefloat.NewPlaintext(params, params.MaxLevel())
			if err := encoder.Encode(values, pt); err != nil {
				return nil, fmt.Errorf("encode dim=%d chunk=%d: %w", d, chunk, err)
			}

			ct, err := encryptor.EncryptNew(pt)
			if err != nil {
				return nil, fmt.Errorf("encrypt dim=%d chunk=%d: %w", d, chunk, err)
			}

			if err := eval.MulConstAndAdd(results[chunk], scalarPt, ct); err != nil {
				return nil, fmt.Errorf("mulconstAndAdd dim=%d chunk=%d: %w", d, chunk, err)
			}
		}
	}

	scores := make([]float64, numVecs)
	for chunk, ct := range results {
		chunkScores, err := eval.DecryptValues(ct, slots)
		if err != nil {
			return nil, fmt.Errorf("decrypt chunk=%d: %w", chunk, err)
		}

		startIdx := chunk * slots
		for i := 0; i < slots && startIdx+i < numVecs; i++ {
			scores[startIdx+i] = chunkScores[i]
		}
	}

	return scores, nil
}

func rankIndices(scores []float64) []int {
	type pair struct {
		idx   int
		score float64
	}

	pairs := make([]pair, len(scores))
	for i, s := range scores {
		pairs[i] = pair{i, s}
	}

	sort.Slice(pairs, func(i, j int) bool {
		return pairs[i].score > pairs[j].score
	})

	indices := make([]int, len(scores))
	for i, p := range pairs {
		indices[i] = p.idx
	}
	return indices
}

func containsInTop(ranking []int, target int, k int) bool {
	if k > len(ranking) {
		k = len(ranking)
	}
	for i := 0; i < k; i++ {
		if ranking[i] == target {
			return true
		}
	}
	return false
}

func spearmanCorrelation(ranking1, ranking2 []int) float64 {
	n := len(ranking1)
	if n != len(ranking2) || n == 0 {
		return 0
	}

	rank1 := make(map[int]int)
	rank2 := make(map[int]int)
	for i, idx := range ranking1 {
		rank1[idx] = i
	}
	for i, idx := range ranking2 {
		rank2[idx] = i
	}

	var sumD2 float64
	for idx := 0; idx < n; idx++ {
		d := float64(rank1[idx] - rank2[idx])
		sumD2 += d * d
	}

	nf := float64(n)
	return 1 - 6*sumD2/(nf*(nf*nf-1))
}
