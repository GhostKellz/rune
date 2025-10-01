# Rune Delivery Roadmap

Extensive milestone checklist for bringing Rune from the current MVP through public release. Use this as the authoritative plan when coordinating work across engineering, documentation, benchmarks, and release management.

---

## Snapshot

| Stage | Focus | Status | Notes |
| ----- | ----- | ------ | ----- |
| MVP | Core runtime + essential MCP tools | ✅ Complete (pending benchmarking + CI hardening) | All foundational modules implemented in Zig |
| Alpha | Advanced performance features | 🚧 Planned | SIMD, parallel, caching, compression layers |
| Beta | Integration, QA, and developer experience | 🚧 Planned | Glyph bindings, testing matrix, documentation |
| Theta | Production hardening & observability | 🚧 Planned | Distributed features, telemetry, operational readiness |
| RC1–RC6 | Release stabilization cadence | 🚧 Planned | Regression, bug triage, release notes, go/no-go |
| Release | Public launch and LTS plan | 🚧 Planned | Packaging, comms, support hand-off |

---

## MVP ✅
Goal: Deliver a feature-complete, high-performance Rune core with essential MCP tooling ready for integration experiments.

### Core Platform
- [x] FFI boundary (`src/ffi.zig`, `include/rune.h`) with error codes, versioning, and thread-safety guarantees
- [x] Memory subsystem (`src/memory.zig`) covering arena + pool allocators with tracking hooks
- [x] Zero-copy buffers (`src/buffer.zig`) including ring buffer, rope scaffolding, and memory-mapped file support
- [x] SIMD-friendly string engine (`src/strings.zig`) with UTF-8 validation, line index, Boyer-Moore & Aho-Corasick search

### Essential MCP Tools
- [x] File operations module (`src/tools/file_ops.zig`) with mmap reader, batch loader, incremental saver, watcher, metadata cache
- [x] Text selection engine (`src/tools/selection.zig`) supporting multi-cursor, history, zero-copy extraction, visual modes
- [x] Workspace operations (`src/tools/workspace.zig`) for fast enumeration, symbol indexing, parallel search, relationship mapping
- [x] Diagnostics engine (`src/tools/diagnostics.zig`) handling pattern extraction, syntax validation, performance & security scanning

### Validation & Documentation
- [ ] Publish baseline benchmarks against pure Rust reference (>3× file ops, <1 ms selection latency)
- [ ] Establish CI workflow running `zig build`, unit tests, and lint/static analysis on merges
- [ ] Expand `README.md`/`docs/` with quick-start integration guide and tool capability matrix
- [ ] Capture architectural overview diagram and decision log for core modules

### MVP Exit Criteria
- [ ] All above validation items complete
- [ ] Known critical bugs triaged with clear owners
- [ ] Glyph integration spike successfully exercises each tool via FFI

---

## Alpha 🚧
Goal: Elevate performance profile with SIMD, parallelism, caching, and compression foundations; prepare for sustained workloads.

### SIMD Optimizations
- [ ] Create `src/simd/text_search.zig` with vectorized pattern search (AVX2/NEON) and scalar fallback
- [ ] Implement SIMD-based UTF-8 validation/refinement in `src/simd/utf8_ops.zig`
- [ ] Add content hashing acceleration (`src/simd/hash_compute.zig`)
- [ ] Prototype diff engine leveraging SIMD-friendly chunking (`src/simd/diff_engine.zig`)
- [ ] Integrate runtime feature detection and configuration flags

### Parallel Processing
- [ ] Implement work-stealing thread pool in `src/parallel.zig`
- [ ] Provide lock-free queues or ring buffers for tool pipelines
- [ ] Parallelize workspace scans & diagnostics pipelines with configurable concurrency limits
- [ ] Expose affinity tuning APIs for Glyph to hint CPU pinning strategies

### Caching Layer
- [ ] Build `src/cache.zig` with LRU cache supporting invariant hashing & SIMD lookup
- [ ] Add disk-backed persistence for large analyses with eviction policies
- [ ] Implement cache invalidation hooks for file system events
- [ ] Instrument cache hit/miss metrics for later telemetry ingestion

### Compression & Serialization
- [ ] Add `src/compress.zig` with fast compression (e.g., LZ4/Zstd) for large payloads
- [ ] Support streaming compression for incremental responses
- [ ] Define binary serialization for high-volume MCP messages & diffs
- [ ] Provide benchmarking harness to compare serialization strategies

### Alpha Exit Criteria
- [ ] Alpha feature set implemented with regression benchmarks recorded
- [ ] Performance deltas documented vs MVP baseline
- [ ] API stability review ensuring no breaking changes required post-Alpha

---

## Beta 🚧
Goal: Deliver a polished developer experience, thorough testing, and seamless integration with Glyph.

### Glyph Integration
- [ ] Automate Rust binding generation from `include/rune.h` (bindgen + CI artifact)
- [ ] Publish safe Rust wrapper crate (`glyph-rune`) with ergonomic APIs and error translation
- [ ] Configure build system for cross-platform static/dynamic linking (Linux, macOS, Windows)
- [ ] Integrate Rune into Glyph’s tool orchestration flow with sample MCP commands

### Testing & Quality Assurance
- [ ] Achieve >90% unit test coverage for public Zig APIs (FFI, tools, utilities)
- [ ] Add integration tests exercising Glyph ↔ Rune flows (read, edit, diagnostics, search)
- [ ] Introduce performance regression harness with golden thresholds
- [ ] Run long-haul stability tests (24h continuous load) to detect leaks & drift
- [ ] Stand up fuzzing/quickcheck suite for FFI boundary and parsers

### Documentation & Developer Experience
- [ ] Produce end-to-end tutorial (Markdown + screencast outline) for adding new MCP tools in Rune
- [ ] Document tuning knobs (thread pool sizing, cache policies, SIMD toggles)
- [ ] Expand examples/ folder with realistic client+server demos
- [ ] Provide troubleshooting guide for common integration pitfalls

### Beta Exit Criteria
- [ ] All blocking bugs resolved; bug backlog triaged by severity
- [ ] Beta adopters (internal) successfully run Glyph+Rune in daily workflows
- [ ] Release readiness review signed off by engineering & product stakeholders

---

## Theta 🚧
Goal: Harden the platform for production workloads with observability, distributed capabilities, and operational tooling.

### Distributed & Collaborative Features
- [ ] Implement advanced rope/CRDT structures with incremental parsing support
- [ ] Explore Tree-sitter or LSP integration for language-aware tooling
- [ ] Add distributed cache options (e.g., Redis/KeyDB integration layer)
- [ ] Prototype custom binary transport for high-throughput deployments

### Monitoring, Telemetry & Operations
- [ ] Embed metrics collection (latency, throughput, cache stats, memory) with pluggable sinks
- [ ] Add structured logging with correlation IDs across FFI boundary
- [ ] Implement tracing spans for major tool operations (OpenTelemetry compatible)
- [ ] Provide health check and diagnostics endpoints callable from Glyph
- [ ] Deliver operational runbook covering deployment, scaling, rollback procedures

### Security & Compliance
- [ ] Perform third-party security audit / penetration testing
- [ ] Add configurable security policies (allowlists, sandboxing hooks)
- [ ] Document data-handling guarantees and compliance considerations (PII, audit logs)

### Theta Exit Criteria
- [ ] Observability stack validated in staging environment
- [ ] All critical security findings remediated
- [ ] Operational readiness review completed (SRE + security sign-off)

---

## Release Candidate Cycle (RC1 – RC6) 🚧
Goal: Drive a disciplined stabilization cadence with clear acceptance gates for each RC. Duplicate checklist per RC as needed.

### RC Preparation (applies to each RC)
- [ ] Tag RC build from release branch with changelog and semantic version bump
- [ ] Run full automated test + benchmark matrix on supported platforms
- [ ] Execute manual spot checks for top 5 MCP workflows (read, edit, search, diagnostics, batch ops)
- [ ] Freeze new feature development; accept critical fixes only
- [ ] Publish draft release notes and upgrade guidance

### RC Exit Criteria (per iteration)
- [ ] All critical/major bugs discovered in RC resolved or deferred with explicit sign-off
- [ ] Performance metrics meet or exceed Beta baselines
- [ ] No regressions in Glyph integration smoke tests
- [ ] Documentation updates merged and staging docs site refreshed

_Repeat the RC loop (RC1 through RC6) until exit criteria can be met without new critical regressions._

---

## Release 🚧
Goal: Ship Rune publicly with confidence and ensure long-term support readiness.

### Final Launch Tasks
- [ ] Finalize semantic version (1.0.0 or appropriate) and tag release in git
- [ ] Publish artifacts: static libraries, headers, Rust crate, documentation site, Docker images if applicable
- [ ] Announce release (blog post, community channels, internal comms)
- [ ] Deliver migration guide from MVP/Alpha/Beta builds to GA
- [ ] Archive RC documentation and update support SLAs

### Post-Release Support
- [ ] Establish bug triage cadence and community support process
- [ ] Stand up metrics dashboard for production usage monitoring
- [ ] Plan 1.0.x patch cadence and roadmap for 1.1/1.2 features
- [ ] Gather feedback from early adopters to prioritize next iterations

### Release Exit Criteria
- [ ] No P0/P1 issues outstanding within two weeks of launch
- [ ] Support & operations teams trained and on-call rotations updated
- [ ] Product/leadership sign-off on launch impact review

---

## How to Use This Document
- Update checkbox states during weekly status reviews.
- Append new tasks beneath the appropriate stage to maintain chronological discipline.
- Mirror any changes into `RUNE_TODO.md` or deprecate once this document fully replaces it.
- When creating issues, reference the relevant checklist item (e.g., `TODO.md :: Beta :: Testing`).
