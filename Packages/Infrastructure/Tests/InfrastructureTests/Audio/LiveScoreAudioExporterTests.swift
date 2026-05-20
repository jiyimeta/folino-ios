import Testing

/// LiveScoreAudioExporter no longer does per-patch prefetching — the GM soundfont (bundled or downloaded) covers all
/// programs, so there is no prefetch gate to test. End-to-end export tests are covered at the integration level via
/// the share flow; unit tests that exercised the old domain-resolver dependency are removed in Task 6.
struct LiveScoreAudioExporterTests {}
