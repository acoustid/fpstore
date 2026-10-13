# fpstore

AcoustID fingerprint store: search and submission handling on top of the
fingerprint database and [fpindex](https://github.com/acoustid/acoustid-index).

Work in progress. So far it has:

- an HTTP server (`src/server.zig`) that answers in JSON or MessagePack like
  fpindex does,
- the changelog feed fpindex nodes replicate from (`src/feed.zig`), under
  `/fpindex`, read from the fingerprint database,
- the query fpindex indexes a fingerprint under (`src/query.zig`), ported from
  pg_acoustid's `acoustid_extract_query` and tested against it with data from
  `zig build query-golden`,
- the codec for Chromaprint's compressed fingerprint format
  (`src/encoding.zig`), the format clients submit and the one fingerprints
  are cached in,
- the similarity score (`src/compare.zig`), tested against scores from the
  previous implementation with data from `tools/compare-golden`.

## Running

    fpstore --host 0.0.0.0 --port 4659 \
        --postgres-host db --postgres-user acoustid --postgres-database acoustid

The Postgres settings can also come from `FPSTORE_POSTGRES_HOST`, `_PORT`,
`_USER`, `_PASSWORD` and `_DATABASE`, which is how the password is best given.
Connections are opened as needed, so fpstore starts while the database is
down; `/fpindex/_health` says whether it answers.

An fpindex node replicates from it with
`--coordinator-url http://<fpstore>:4659/fpindex`, without a trailing slash.

## Build

Requires Zig 0.17.

    zig build              # builds zig-out/bin/fpstore
    zig build run -- --port 4659
    zig build unit-tests   # unit tests

The codec picks its implementation from the build target: PDEP/PEXT and AVX2
on x86-64 CPUs that have them and do PDEP/PEXT in hardware (not AMD Zen 1/2),
plain Zig everywhere else. The default build targets the machine it is built
on; a build for another machine needs its CPU, e.g. `-Dcpu=x86_64_v3`, or the
portable path is used.
