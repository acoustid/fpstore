# fpstore

AcoustID fingerprint store: search and submission handling on top of the
fingerprint database and [fpindex](https://github.com/acoustid/acoustid-index).

Work in progress. So far it has:

- the codec for Chromaprint's compressed fingerprint format
  (`src/encoding.zig`), the format clients submit and the one fingerprints
  are cached in,
- the similarity score (`src/compare.zig`), tested against scores from the
  previous implementation with data from `tools/compare-golden`.

## Build

Requires Zig 0.17.

    zig build unit-tests   # unit tests

The codec picks its implementation from the build target: PDEP/PEXT and AVX2
on x86-64 CPUs that have them and do PDEP/PEXT in hardware (not AMD Zen 1/2),
plain Zig everywhere else. The default build targets the machine it is built
on; a build for another machine needs its CPU, e.g. `-Dcpu=x86_64_v3`, or the
portable path is used.
