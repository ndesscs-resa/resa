// Package benchmark provides memory and timing measurement utilities.
package benchmark

import (
	"os"
	"runtime"
	"strconv"
	"strings"
)

// MemoryStats holds memory usage information.
type MemoryStats struct {
	HeapAlloc uint64 // Go heap allocation (bytes)
	HeapSys   uint64 // Go heap system memory (bytes)
	VmRSS     uint64 // Resident Set Size from /proc/self/status (bytes)
	VmHWM     uint64 // High Water Mark - peak RSS (bytes)
	VmSize    uint64 // Virtual memory size (bytes)
}

// GetMemoryStats returns current memory usage.
func GetMemoryStats() MemoryStats {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	stats := MemoryStats{
		HeapAlloc: m.HeapAlloc,
		HeapSys:   m.HeapSys,
	}

	// Read from /proc/self/status for accurate RSS (Linux only)
	if data, err := os.ReadFile("/proc/self/status"); err == nil {
		lines := strings.Split(string(data), "\n")
		for _, line := range lines {
			if strings.HasPrefix(line, "VmRSS:") {
				stats.VmRSS = parseMemoryField(line)
			} else if strings.HasPrefix(line, "VmHWM:") {
				stats.VmHWM = parseMemoryField(line)
			} else if strings.HasPrefix(line, "VmSize:") {
				stats.VmSize = parseMemoryField(line)
			}
		}
	}

	return stats
}

// ForceGC forces garbage collection and returns memory stats.
// Use this before measuring memory to get accurate results.
func ForceGC() MemoryStats {
	runtime.GC()
	runtime.GC() // Run twice for thorough cleanup
	return GetMemoryStats()
}

// BytesToGB converts bytes to decimal GB.
func BytesToGB(bytes uint64) float64 {
	return float64(bytes) / 1_000_000_000.0
}

// BytesToMB converts bytes to decimal MB.
func BytesToMB(bytes uint64) float64 {
	return float64(bytes) / 1_000_000.0
}

// FormatBytes formats bytes using decimal units.
func FormatBytes(bytes uint64) string {
	const unit = 1000
	if bytes < unit {
		return strconv.FormatUint(bytes, 10) + " B"
	}

	div, exp := uint64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}

	val := float64(bytes) / float64(div)
	suffix := "kMGTPE"[exp : exp+1]
	return strconv.FormatFloat(val, 'f', 2, 64) + " " + suffix + "B"
}

// FormatBytesDecimal is kept for older callers; it uses the same decimal units
// as FormatBytes.
func FormatBytesDecimal(bytes uint64) string {
	return FormatBytes(bytes)
}

// parseMemoryField parses a memory field from /proc/self/status.
// Format: "VmRSS:   12345 kB"
func parseMemoryField(line string) uint64 {
	fields := strings.Fields(line)
	if len(fields) >= 2 {
		if val, err := strconv.ParseUint(fields[1], 10, 64); err == nil {
			return val * 1024 // kB to bytes
		}
	}
	return 0
}
