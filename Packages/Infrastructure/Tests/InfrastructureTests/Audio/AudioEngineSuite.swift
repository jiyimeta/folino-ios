import Testing

/// Parent suite for every test that builds a real `PlaybackEngine`.
///
/// `.serialized` because such a test reaches process-global state — `AVAudioSession` above all, whose category the
/// engine writes at `prepare` under any policy but `.hostManaged`. Swift Testing runs suites in parallel by default,
/// and two engine tests overlapping made a session assertion read another suite's write: the same test both failed
/// spuriously (the other suite had switched the category mid-export) and passed spuriously (it had switched it back
/// before the assertion). Serializing is the fix; comparing against a "distinctive" baseline is not, because a
/// concurrent writer can land on either side of the comparison.
///
/// Nest an engine-touching suite in an extension of this type — `.serialized` covers nested suites — rather than
/// declaring it at file scope.
@Suite(.serialized)
struct AudioEngineTests {}
