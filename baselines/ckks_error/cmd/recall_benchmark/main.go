// Recall@K benchmark for encrypted vector similarity search.
// Measures retrieval accuracy of HE-based inner product computation.
//
// Key metrics:
//   - Recall@1, @10, @100: fraction of queries where true top-K appears in HE top-K
//   - Max absolute error: worst-case deviation in similarity scores
//   - Rank correlation: Spearman correlation between plaintext and HE rankings
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"math/rand"
	"os"
	"runtime"
	"sort"
	"time"

	"github.com/tuneinsight/lattigo/v5/core/rlwe"
	"github.com/tuneinsight/lattigo/v5/he/hefloat"

	"github.com/ndesscs-resa/resa/baselines/ckks_error/pkg/benchmark"
	"github.com/ndesscs-resa/resa/baselines/ckks_error/pkg/database"
	"github.com/ndesscs-resa/resa/baselines/ckks_error/pkg/he"
)

// RecallResult holds comprehensive benchmark results.
type RecallResult struct {
	Implementation string `json:"implementation"`
	Dataset        string `json:"dataset"`
	NumVectors     int    `json:"num_vectors"`
	NumQueries     int    `json:"num_queries"`
	Dim            int    `json:"dim"`
	Params         struct {
		N     int    `json:"N"`
		LogQ  string `json:"logQ"`
		Scale string `json:"scale"`
	} `json:"params"`
	Recall1             float64 `json:"recall@1"`
	Recall10            float64 `json:"recall@10"`
	Recall100           float64 `json:"recall@100"`
	MRR10               float64 `json:"mrr@10"`
	MaxError            float64 `json:"max_error"`
	MeanError           float64 `json:"mean_error"`
	StdError            float64 `json:"std_error"`
	RankCorrelation     float64 `json:"rank_correlation"`
	RuntimeSecondsAvg   float64 `json:"runtime_seconds_avg"`
	RuntimeSecondsTotal float64 `json:"runtime_seconds_total"`
	EncryptionSeconds   float64 `json:"encryption_seconds"`
	MemoryGB            float64 `json:"memory_gb"`
}

func main() {
	// Parse command-line flags
	numVectors := flag.Int("vectors", 1000, "Number of vectors in database")
	numQueries := flag.Int("queries", 100, "Number of queries to run")
	embeddingDim := flag.Int("dim", 768, "Embedding dimension")
	seed := flag.Int64("seed", 42, "Random seed for reproducibility")
	outputPath := flag.String("output", "", "Output JSON path (default: results/recall_lattigo.json)")
	verbose := flag.Bool("verbose", false, "Print detailed per-query results")
	flag.Parse()

	if *outputPath == "" {
		*outputPath = "results/recall_lattigo.json"
	}

	fmt.Println("=== Recall@K Benchmark ===")
	fmt.Printf("Configuration: %d vectors, %d queries, d=%d, seed=%d\n",
		*numVectors, *numQueries, *embeddingDim, *seed)

	// Initialize HE parameters
	fmt.Println("\n[1] Initializing HE parameters...")
	params, err := he.NewParameters()
	if err != nil {
		fmt.Printf("Error creating parameters: %v\n", err)
		return
	}

	fmt.Printf("  Ring degree N: %d\n", params.N())
	fmt.Printf("  SIMD slots: %d\n", he.Slots(params))
	fmt.Printf("  Ciphertext size: %s\n", benchmark.FormatBytes(uint64(he.CiphertextSize(params))))

	// Force GC and measure baseline memory
	baseline := benchmark.ForceGC()
	fmt.Printf("\nBaseline memory: %s\n", benchmark.FormatBytes(baseline.VmRSS))

	// Key generation
	fmt.Println("\n[2] Generating keys...")
	kgen := rlwe.NewKeyGenerator(params)
	sk := kgen.GenSecretKeyNew()
	fmt.Println("  Secret key generated")

	// Create evaluator
	eval := he.NewEvaluator(params, sk)

	// Generate normalized synthetic embedding vectors.
	fmt.Println("\n[3] Generating normalized database...")
	dbTimer := benchmark.NewTimer("DB Generation")
	db := generateNormalizedDB(*numVectors, *embeddingDim, *seed)
	dbTimer.Stop()

	// Encrypt database
	fmt.Println("\n[4] Encrypting database...")
	encTimer := benchmark.NewTimer("DB Encryption")

	progressFn := func(dim, total int) {
		if dim%100 == 0 || dim == total {
			pct := float64(dim) / float64(total) * 100
			stats := benchmark.GetMemoryStats()
			fmt.Printf("  Progress: %d/%d dims (%.1f%%), Memory: %s\n",
				dim, total, pct, benchmark.FormatBytes(stats.VmRSS))
		}
	}

	encDB, err := database.EncodeDB(db, params, sk, progressFn)
	if err != nil {
		fmt.Printf("Error encoding database: %v\n", err)
		return
	}
	encryptionTime := encTimer.Stop()

	// Measure memory after encryption
	afterDB := benchmark.ForceGC()
	dbMemory := afterDB.VmRSS - baseline.VmRSS
	fmt.Printf("\nEncrypted database memory: %s (%.2f GB)\n",
		benchmark.FormatBytes(dbMemory),
		benchmark.BytesToGB(dbMemory))

	// Generate queries
	fmt.Printf("\n[5] Running %d queries...\n", *numQueries)
	queries := generateNormalizedQueries(*numQueries, *embeddingDim, *seed+1000)

	// Metrics accumulators
	var (
		recall1Count   int
		recall10Count  int
		recall100Count int
		sumMRR10       float64 // MRR@10 accumulator
		maxError       float64
		sumError       float64
		sumErrorSq     float64 // For std error calculation
		totalScores    int
		sumCorrelation float64
		totalLatency   time.Duration
	)

	for q := 0; q < *numQueries; q++ {
		query := queries[q]

		// Compute plaintext scores (ground truth)
		plaintextScores := computePlaintextScores(db, query)
		groundTruth := rankIndices(plaintextScores)

		// Compute encrypted scores
		queryTimer := time.Now()
		encScores := computeEncryptedScores(eval, params, query, encDB)
		heScores := decryptScores(eval, encScores, encDB.NumVectors, encDB.Slots)
		queryLatency := time.Since(queryTimer)
		totalLatency += queryLatency

		heRanking := rankIndices(heScores)

		// Compute Recall@K
		if containsInTop(heRanking, groundTruth[0], 1) {
			recall1Count++
		}
		if containsInTop(heRanking, groundTruth[0], 10) {
			recall10Count++
		}
		if containsInTop(heRanking, groundTruth[0], 100) {
			recall100Count++
		}

		// Compute MRR@10: reciprocal rank of ground truth top-1 in HE ranking
		sumMRR10 += computeReciprocalRank(heRanking, groundTruth[0], 10)

		// Compute error statistics
		for i := 0; i < *numVectors; i++ {
			err := math.Abs(plaintextScores[i] - heScores[i])
			if err > maxError {
				maxError = err
			}
			sumError += err
			sumErrorSq += err * err
			totalScores++
		}

		// Compute rank correlation (Spearman)
		corr := spearmanCorrelation(groundTruth, heRanking)
		sumCorrelation += corr

		if *verbose {
			fmt.Printf("  Query %d: Recall@1=%v, MaxErr=%.6f, Corr=%.4f, Latency=%v\n",
				q+1,
				containsInTop(heRanking, groundTruth[0], 1),
				maxError,
				corr,
				queryLatency)
		} else if (q+1)%10 == 0 {
			fmt.Printf("  Completed %d/%d queries\n", q+1, *numQueries)
		}
	}

	// Calculate final metrics
	recall1 := float64(recall1Count) / float64(*numQueries)
	recall10 := float64(recall10Count) / float64(*numQueries)
	recall100 := float64(recall100Count) / float64(*numQueries)
	mrr10 := sumMRR10 / float64(*numQueries)
	meanError := sumError / float64(totalScores)
	// Std error: sqrt(E[X^2] - E[X]^2)
	stdError := math.Sqrt(sumErrorSq/float64(totalScores) - meanError*meanError)
	meanCorrelation := sumCorrelation / float64(*numQueries)
	avgLatency := totalLatency / time.Duration(*numQueries)

	// Final memory measurement
	finalStats := benchmark.ForceGC()
	peakMemory := finalStats.VmHWM - baseline.VmRSS

	// Build result
	result := RecallResult{
		Implementation:      "Lattigo v5",
		Dataset:             fmt.Sprintf("Synthetic-%d-normalized", *embeddingDim),
		NumVectors:          *numVectors,
		NumQueries:          *numQueries,
		Dim:                 *embeddingDim,
		Recall1:             recall1,
		Recall10:            recall10,
		Recall100:           recall100,
		MRR10:               mrr10,
		MaxError:            maxError,
		MeanError:           meanError,
		StdError:            stdError,
		RankCorrelation:     meanCorrelation,
		RuntimeSecondsAvg:   avgLatency.Seconds(),
		RuntimeSecondsTotal: totalLatency.Seconds(),
		EncryptionSeconds:   encryptionTime.Seconds(),
		MemoryGB:            benchmark.BytesToGB(peakMemory),
	}
	result.Params.N = params.N()
	result.Params.LogQ = "51"
	result.Params.Scale = "ctxt=2^26, const=2^23, product=2^49"

	// Print summary
	fmt.Println("\n=== Results ===")
	fmt.Printf("Recall@1:   %.2f%% (%d/%d)\n", recall1*100, recall1Count, *numQueries)
	fmt.Printf("Recall@10:  %.2f%% (%d/%d)\n", recall10*100, recall10Count, *numQueries)
	fmt.Printf("Recall@100: %.2f%% (%d/%d)\n", recall100*100, recall100Count, *numQueries)
	fmt.Printf("MRR@10:     %.4f\n", mrr10)
	fmt.Printf("\nError Statistics:\n")
	fmt.Printf("  Max Error:  %.9f\n", maxError)
	fmt.Printf("  Mean Error: %.9f\n", meanError)
	fmt.Printf("  Std Error:  %.9f\n", stdError)
	fmt.Printf("  Rank Correlation: %.6f\n", meanCorrelation)
	fmt.Printf("\nPerformance:\n")
	fmt.Printf("  Avg Query Latency: %v\n", avgLatency)
	fmt.Printf("  Total Query Time:  %v\n", totalLatency)
	fmt.Printf("  Encryption Time:   %v\n", encryptionTime)
	fmt.Printf("  Peak Memory:       %.2f GB\n", benchmark.BytesToGB(peakMemory))
	fmt.Printf("\nCPU cores: %d\n", runtime.NumCPU())

	// Save results to JSON
	jsonData, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		fmt.Printf("Error marshaling JSON: %v\n", err)
		return
	}

	if err := os.WriteFile(*outputPath, jsonData, 0644); err != nil {
		fmt.Printf("Error writing results: %v\n", err)
		return
	}
	fmt.Printf("\nResults saved to: %s\n", *outputPath)
}

// generateNormalizedDB creates a database of L2-normalized vectors.
// Simulates normalized embeddings like MS-MARCO.
func generateNormalizedDB(numVectors, embeddingDim int, seed int64) [][]float64 {
	rng := rand.New(rand.NewSource(seed))

	db := make([][]float64, numVectors)
	for i := 0; i < numVectors; i++ {
		db[i] = make([]float64, embeddingDim)

		// Generate random vector
		var norm float64
		for j := 0; j < embeddingDim; j++ {
			db[i][j] = rng.NormFloat64()
			norm += db[i][j] * db[i][j]
		}

		// Normalize to unit length
		norm = math.Sqrt(norm)
		for j := 0; j < embeddingDim; j++ {
			db[i][j] /= norm
		}
	}

	return db
}

// generateNormalizedQueries creates normalized query vectors.
func generateNormalizedQueries(numQueries, embeddingDim int, seed int64) [][]float64 {
	rng := rand.New(rand.NewSource(seed))

	queries := make([][]float64, numQueries)
	for i := 0; i < numQueries; i++ {
		queries[i] = make([]float64, embeddingDim)

		var norm float64
		for j := 0; j < embeddingDim; j++ {
			queries[i][j] = rng.NormFloat64()
			norm += queries[i][j] * queries[i][j]
		}

		norm = math.Sqrt(norm)
		for j := 0; j < embeddingDim; j++ {
			queries[i][j] /= norm
		}
	}

	return queries
}

// computePlaintextScores computes dot product scores in plaintext.
func computePlaintextScores(db [][]float64, query []float64) []float64 {
	scores := make([]float64, len(db))
	for i, vec := range db {
		var sum float64
		for j := range vec {
			sum += vec[j] * query[j]
		}
		scores[i] = sum
	}
	return scores
}

// computeEncryptedScores performs encrypted inner product for all vectors.
// Uses asymmetric scale: DB at 2^26, query at 2^23, result at 2^49.
func computeEncryptedScores(eval *he.Evaluator, params hefloat.Parameters, query []float64, encDB *database.EncodedDB) []*rlwe.Ciphertext {
	// Initialize result ciphertexts (one per chunk) at scale 2^49
	results := make([]*rlwe.Ciphertext, encDB.NumChunks)
	for chunk := 0; chunk < encDB.NumChunks; chunk++ {
		var err error
		results[chunk], err = eval.NewZeroCiphertext()
		if err != nil {
			panic(fmt.Sprintf("Error creating zero ciphertext: %v", err))
		}
	}

	// Core computation: Const x Ctxt for each dimension
	// Pre-encode each query scalar as plaintext at scale 2^23
	for dim := 0; dim < encDB.EmbedDim; dim++ {
		scalarPt, err := eval.EncodeQueryScalar(query[dim])
		if err != nil {
			panic(fmt.Sprintf("Error encoding query scalar: %v", err))
		}

		for chunk := 0; chunk < encDB.NumChunks; chunk++ {
			ct := encDB.Ciphertexts[dim][chunk]
			if err := eval.MulConstAndAdd(results[chunk], scalarPt, ct); err != nil {
				panic(fmt.Sprintf("Error in MulConstAndAdd: %v", err))
			}
		}
	}

	return results
}

// decryptScores decrypts result ciphertexts and extracts scores.
func decryptScores(eval *he.Evaluator, resultCts []*rlwe.Ciphertext, numVectors, slots int) []float64 {
	scores := make([]float64, numVectors)

	for chunk, ct := range resultCts {
		chunkScores, err := eval.DecryptValues(ct, slots)
		if err != nil {
			panic(fmt.Sprintf("Error decrypting: %v", err))
		}

		startIdx := chunk * slots
		for i := 0; i < slots && startIdx+i < numVectors; i++ {
			scores[startIdx+i] = chunkScores[i]
		}
	}

	return scores
}

// rankIndices returns indices sorted by score (descending).
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

// containsInTop checks if target is in the top-K of ranking.
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

// computeReciprocalRank returns 1/rank if target is found in top-K, else 0.
// Rank is 1-indexed (first position = rank 1).
func computeReciprocalRank(ranking []int, target int, k int) float64 {
	if k > len(ranking) {
		k = len(ranking)
	}
	for i := 0; i < k; i++ {
		if ranking[i] == target {
			return 1.0 / float64(i+1)
		}
	}
	return 0.0
}

// spearmanCorrelation computes Spearman rank correlation.
func spearmanCorrelation(ranking1, ranking2 []int) float64 {
	n := len(ranking1)
	if n != len(ranking2) || n == 0 {
		return 0
	}

	// Convert rankings to rank positions
	rank1 := make(map[int]int)
	rank2 := make(map[int]int)
	for i, idx := range ranking1 {
		rank1[idx] = i
	}
	for i, idx := range ranking2 {
		rank2[idx] = i
	}

	// Compute sum of squared rank differences
	var sumD2 float64
	for idx := 0; idx < n; idx++ {
		d := float64(rank1[idx] - rank2[idx])
		sumD2 += d * d
	}

	// Spearman correlation: 1 - 6*sum(d^2) / (n*(n^2-1))
	nf := float64(n)
	return 1 - 6*sumD2/(nf*(nf*nf-1))
}
