# compare-golden

Generates `src/testdata/compare/`, which `src/compare.zig` is tested against:
what go-acoustid's `AlignFingerprints` and `CompareFingerprints` give for pairs
of fingerprints, and the orders Go's `sort.Slice` leaves offset peaks in.

The fingerprints are real ones from the AcoustID public data, those of tracks
that got more than one new fingerprint on 2026-10-01, the ones in
`src/testdata/`, and variants of a few of them that are shifted, cut, noisy,
edited in the middle, or a short loop.

    mkdir corpus && cd corpus
    curl -O https://data.acoustid.org/2026/2026-10/2026-10-01-fingerprint-update.jsonl.gz
    curl -O https://data.acoustid.org/2026/2026-10/2026-10-01-track_fingerprint-update.jsonl.gz
    cd ..
    go run . corpus ../../src/testdata ../../src/testdata/compare
