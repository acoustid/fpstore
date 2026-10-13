// Generates the golden data for src/compare.zig with go-acoustid, see README.md.
package main

import (
	"bufio"
	"compress/gzip"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/acoustid/go-acoustid/pkg/chromaprint"
	pb "github.com/acoustid/go-acoustid/proto/common"
)

func readJSONL(path string, f func([]byte)) {
	file, err := os.Open(path)
	check(err)
	defer file.Close()
	gz, err := gzip.NewReader(file)
	check(err)
	sc := bufio.NewScanner(gz)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	for sc.Scan() {
		f(sc.Bytes())
	}
	check(sc.Err())
}

func check(err error) {
	if err != nil {
		panic(err)
	}
}

type entry struct {
	name   string
	hashes []uint32
}

func main() {
	corpus, testdata, out := os.Args[1], os.Args[2], os.Args[3]

	trackOf := map[int64]int64{}
	readJSONL(filepath.Join(corpus, "2026-10-01-track_fingerprint-update.jsonl.gz"), func(b []byte) {
		var r struct {
			TrackID       int64 `json:"track_id"`
			FingerprintID int64 `json:"fingerprint_id"`
		}
		check(json.Unmarshal(b, &r))
		trackOf[r.FingerprintID] = r.TrackID
	})
	byTrack := map[int64][]int64{}
	for fp, t := range trackOf {
		byTrack[t] = append(byTrack[t], fp)
	}
	wanted := map[int64]bool{}
	var tracks []int64
	for t, fps := range byTrack {
		if len(fps) > 1 {
			tracks = append(tracks, t)
		}
	}
	sort.Slice(tracks, func(i, j int) bool { return tracks[i] < tracks[j] })
	tracks = tracks[:30]
	for _, t := range tracks {
		sort.Slice(byTrack[t], func(i, j int) bool { return byTrack[t][i] < byTrack[t][j] })
		if len(byTrack[t]) > 3 {
			byTrack[t] = byTrack[t][:3]
		}
		for _, fp := range byTrack[t] {
			wanted[fp] = true
		}
	}
	hashesOf := map[int64][]uint32{}
	readJSONL(filepath.Join(corpus, "2026-10-01-fingerprint-update.jsonl.gz"), func(b []byte) {
		var r struct {
			ID          int64   `json:"id"`
			Fingerprint []int32 `json:"fingerprint"`
		}
		check(json.Unmarshal(b, &r))
		if !wanted[r.ID] {
			return
		}
		h := make([]uint32, len(r.Fingerprint))
		for i, x := range r.Fingerprint {
			h[i] = uint32(x)
		}
		hashesOf[r.ID] = h
	})

	var entries []entry
	index := map[string]int{}
	add := func(name string, h []uint32) int {
		index[name] = len(entries)
		entries = append(entries, entry{name, h})
		return len(entries) - 1
	}

	// Real fingerprints, grouped by track.
	var groups [][]int
	for _, t := range tracks {
		var g []int
		for _, fp := range byTrack[t] {
			if h, ok := hashesOf[fp]; ok {
				g = append(g, add(fmt.Sprintf("fp%d", fp), h))
			}
		}
		groups = append(groups, g)
	}
	var testFiles []int
	names, _ := filepath.Glob(filepath.Join(testdata, "*.txt"))
	sort.Strings(names)
	for _, name := range names {
		data, err := os.ReadFile(name)
		check(err)
		fp, err := chromaprint.ParseFingerprintString(strings.TrimSpace(string(data)))
		check(err)
		testFiles = append(testFiles, add(strings.TrimSuffix(filepath.Base(name), ".txt"), fp.Hashes))
	}

	// Synthetic variants of a few real fingerprints.
	rng := rand.New(rand.NewSource(1))
	type pair struct{ a, b int }
	var pairs []pair
	for gi := 0; gi < 4; gi++ {
		src := groups[gi][0]
		s := entries[src].hashes
		other := entries[groups[gi+10][0]].hashes
		variant := func(name string, h []uint32) {
			v := add(fmt.Sprintf("%s-%s", entries[src].name, name), h)
			pairs = append(pairs, pair{src, v}, pair{v, src}, pair{v, groups[gi+20][0]})
		}
		for _, k := range []int{5, 40, 79, 80, 81, 200} {
			if k < len(s) {
				variant(fmt.Sprintf("skip%d", k), append([]uint32{}, s[k:]...))
			}
		}
		for _, k := range []int{20, 60, 100, 400} {
			if k < len(s) {
				variant(fmt.Sprintf("head%d", k), append([]uint32{}, s[:k]...))
			}
		}
		for _, bits := range []int{1, 3, 6, 10} {
			h := append([]uint32{}, s...)
			for i := range h {
				for b := 0; b < bits; b++ {
					h[i] ^= 1 << uint(rng.Intn(32))
				}
			}
			variant(fmt.Sprintf("noise%d", bits), h)
		}
		// A different section in the middle, like an edit with other vocals.
		for _, frac := range []float64{0.1, 0.3, 0.6} {
			h := append([]uint32{}, s...)
			start := len(h) / 4
			end := start + int(float64(len(h))*frac)
			for i := start; i < end && i < len(h) && i < len(other); i++ {
				h[i] = other[i]
			}
			variant(fmt.Sprintf("edit%d", int(frac*100)), h)
		}
		// Repetitive: a short loop over and over.
		h := make([]uint32, len(s))
		for i := range h {
			h[i] = s[i%50]
		}
		variant("loop50", h)
		// Shifted by an offset with a few hashes inserted in front.
		ins := make([]uint32, 30)
		for i := range ins {
			ins[i] = rng.Uint32()
		}
		variant("insert30", append(ins, s...))
	}
	silence := make([]uint32, 500)
	for i := range silence {
		silence[i] = 627964279
	}
	sil := add("silence", silence)
	one := add("single", []uint32{0x12345678})

	for _, g := range groups {
		for _, a := range g {
			for _, b := range g {
				pairs = append(pairs, pair{a, b})
			}
		}
	}
	for gi, g := range groups {
		for k := 1; k <= 3; k++ {
			pairs = append(pairs, pair{g[0], groups[(gi+k)%len(groups)][len(groups[(gi+k)%len(groups)])-1]})
		}
	}
	for _, a := range testFiles {
		for _, b := range testFiles {
			pairs = append(pairs, pair{a, b})
		}
	}
	pairs = append(pairs, pair{sil, sil}, pair{sil, groups[0][0]}, pair{groups[0][0], sil}, pair{one, one}, pair{one, groups[0][0]})

	// Fingerprints, each as a u32 length and its chromaprint encoding.
	f, err := os.Create(filepath.Join(out, "fingerprints.bin"))
	check(err)
	w := bufio.NewWriter(f)
	for _, e := range entries {
		data := chromaprint.CompressFingerprint(&pb.Fingerprint{Version: 1, Hashes: e.hashes})
		check(binary.Write(w, binary.LittleEndian, uint32(len(data))))
		_, err = w.Write(data)
		check(err)
	}
	check(w.Flush())
	check(f.Close())

	// Pairs: master, query, number of offset peaks, the top one's offset and
	// count (f64 bits), and the score (f32 bits).
	f, err = os.Create(filepath.Join(out, "pairs.txt"))
	check(err)
	w = bufio.NewWriter(f)
	fmt.Fprintln(w, "# master query peaks offset count(f64 bits) score(f32 bits)  (generated by tools/compare-golden)")
	manyPeaks := 0
	for _, p := range pairs {
		a := &pb.Fingerprint{Version: 1, Hashes: entries[p.a].hashes}
		b := &pb.Fingerprint{Version: 1, Hashes: entries[p.b].hashes}
		hits := chromaprint.AlignFingerprints(a, b, 14, 1<<30, 80)
		score, err := chromaprint.CompareFingerprints(a, b)
		check(err)
		if len(hits) == 0 {
			fmt.Fprintf(w, "%d %d 0 0 0 %08x\n", p.a, p.b, math.Float32bits(score))
			continue
		}
		if len(hits) > 12 {
			manyPeaks++
		}
		check2, err := chromaprint.CompareAlignedFingerprints(a, b, hits[0])
		check(err)
		if float32(check2) != score {
			panic("CompareFingerprints does not use the first of the sorted peaks")
		}
		fmt.Fprintf(w, "%d %d %d %d %016x %08x\n", p.a, p.b, len(hits), hits[0].Offset, math.Float64bits(hits[0].Count), math.Float32bits(score))
	}
	check(w.Flush())
	check(f.Close())
	fmt.Fprintf(os.Stderr, "%d fingerprints, %d pairs, %d with more than 12 peaks\n", len(entries), len(pairs), manyPeaks)
}
