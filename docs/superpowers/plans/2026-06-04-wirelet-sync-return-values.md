# swift-wirelet: synchronous return values for @WireletExpose — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` checkboxes.

**Goal:** Let a Swift `@WireletExpose func f(...) -> T` return its value across JNI to the generated Kotlin ViewModel method, for `T ∈ { String, primitive scalar, [WireFormat] }`. Unblocks Folino's `exportScore(...) -> String` and `exportFormats(...) -> [ScoreExportFormatWire]`.

**Architecture:** Today every exposed method's JNI signature is hardcoded `(J<args>)V` (`JNISidecarBuilder.swift:196`) and the `@_cdecl` invoke drops the return. We thread a `returnTypeText` through the schema and emit: (a) the right JNI return descriptor, (b) Swift `@_cdecl` that captures the return and marshals it (reusing the exact helpers the `_track` observable-property bridges already use — `NewStringUTF` for String, `WireletObservableJNI.encode/encodeArray` for wire types), (c) a Kotlin `external fun` with a return type and a `return`/decode. The Kotlin decode of a returned `[B]` reuses the same `WireletList.decode` + `<Wire>Codec` the observable StateFlows already use.

**Tech Stack:** Swift (SwiftSyntax macros + emitter targets), Kotlin runtime (gradle, mavenLocal publish), JNI.

**Worktree:** `/Users/kiichi/Developer/Personal/swift-packages/swift-wirelet/.claude/worktrees/sync-return-values` (branch `sync-return-values`, off `main` @ 971ffb6). ALL wirelet work happens here. Folino worktree stays at `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-library-export`.

**Scope (YAGNI):** Support return types **String**, **primitive scalars** (Int32/Int64/Bool/Float/Double → Kotlin Int/Long/Boolean/Float/Double), and **[WireFormat]** (array of a `@WireFormat` struct). Single `WireFormat` and optionals are out of scope unless trivial to include for coherence — if a case is one line via the existing track-bridge helper, include it; otherwise emit a clear compile-time diagnostic for unsupported return types. `Void`/`Unit` returns keep working exactly as today.

---

## Build / test command reference
- Swift emitter tests (in the wirelet worktree): `swift test` from the worktree root. (swift-wirelet's package builds host-side with the default toolchain; use `xcrun swift test` if a toolchain issue appears.)
- Kotlin runtime build/test: `kotlin/gradlew -p kotlin :observable-runtime:test :runtime:test --no-daemon` (from the worktree root).
- Kotlin publish to mavenLocal (after bumping version): `kotlin/gradlew -p kotlin :runtime:publishToMavenLocal :observable-runtime:publishToMavenLocal :gradle-plugin:publishToMavenLocal -PwireletVersion=<X.Y.Z> --no-daemon`.
- All wirelet commits end with the standard `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.

---

## Phase W1 — Schema: thread the return type

### Task W1: `ObservableMethod.returnTypeText` + parser
**Files (wirelet worktree):**
- Modify: `Sources/WireletObservableSchema/ObservableSchema.swift` (`ObservableMethod` struct)
- Modify: the parser that builds `ObservableMethod` from the `@WireletExpose` `FunctionDeclSyntax` — FIND it: `grep -rn "ObservableMethod(" Sources` (likely under `Sources/WireletObservableSchema/Internal/` or a macro/extractor). It currently reads `name` + `parameters` from the func decl; add reading `signature.returnClause?.type` (trimmed text), `nil` when absent or `Void`/`()`.
- Test: the schema/parser test target (find it under `Tests/`).

- [ ] **Step 1:** Write a failing parser test: a `@WireletExpose func foo(_ a: String) -> String` parses to an `ObservableMethod` with `returnTypeText == "String"`; a `func bar()` parses to `returnTypeText == nil`; a `func baz() -> Void` / `-> ()` → `nil`.
- [ ] **Step 2:** Run the schema test target, confirm FAIL.
- [ ] **Step 3:** Add `public var returnTypeText: String?` to `ObservableMethod` (after `parameters`), update its `init` (add a defaulted `returnTypeText: String? = nil` param to avoid breaking existing call sites), and update the parser to populate it from the func decl's return clause (normalize `Void`/`()` → `nil`, trim whitespace).
- [ ] **Step 4:** Run the schema test target, confirm PASS, and run full `swift test` to confirm no existing test broke (the defaulted init keeps call sites compiling).
- [ ] **Step 5:** Commit: `feat(schema): thread @WireletExpose return type into ObservableMethod`.

---

## Phase W2 — JNI descriptor

### Task W2: return descriptor in `JNISidecarBuilder`
**Files:**
- Modify: `Sources/WireletObservableKotlinEmitter/JNISidecarBuilder.swift`
- Test: `Tests/WireletObservableKotlinEmitterTests/JNISidecarBuilderTests.swift`

- [ ] **Step 1:** Write failing tests in `JNISidecarBuilderTests.swift`: a method with `returnTypeText == "String"` produces signature `(J...)Ljava/lang/String;`; `"Int32"` → `(J...)I`; `"Bool"` → `(J...)Z`; `"[ScoreExportFormatWire]"` (an array) → `(J...)[B`; `nil` return → `(J...)V` (unchanged). (Match the existing test style in that file for constructing an `ObservableMethod` + asserting the emitted `signature`.)
- [ ] **Step 2:** Run `swift test --filter JNISidecarBuilder`, confirm FAIL.
- [ ] **Step 3:** In `JNISidecarBuilder.methodEntry` (~line 196), replace `"(J\(argDescriptors))V"` with `"(J\(argDescriptors))\(returnDescriptor(method.returnTypeText))"`. Add `private static func returnDescriptor(_ swiftType: String?) -> String`: `nil`/`Void`/`()` → `"V"`; otherwise classify via the SAME `InvokeArgClassifier` used by `jniArgDescriptor` (String → `Ljava/lang/String;`, primitives → `I/J/Z/F/D`, `.bool` → `Z`, `.wireFormat`/`.array`/optionals → `[B`).
- [ ] **Step 4:** Run `swift test --filter JNISidecarBuilder`, confirm PASS.
- [ ] **Step 5:** Commit: `feat(kotlin-emitter): emit JNI return descriptor for exposed methods`.

---

## Phase W3 — Swift @_cdecl marshaling

### Task W3: `InvokeBridgeEmitter` returns the value
**Files:**
- Modify: `Sources/WireletObservableSwiftBridgesEmitter/Internal/InvokeBridgeEmitter.swift`
- Test: `Tests/WireletObservableSwiftBridgesEmitterTests/...` (the invoke-bridge test file)

Reference the EXACT marshaling already used by `Sources/WireletObservableSwiftBridgesEmitter/Internal/TrackBridgeEmitter.swift`:
- String property bridge returns `jstring?` via `snapshot.withCString { envValue.pointee.NewStringUTF(env, $0) }`.
- WireFormat → `jbyteArray?` via `WireletObservableJNI.encode(snapshot, env: env)`.
- WireFormat array → `jbyteArray?` via `WireletObservableJNI.encodeArray(snapshot, env: env)`.

- [ ] **Step 1:** Write failing emitter tests: (a) zero-arg `func f() -> String` emits an `@_cdecl ... -> jstring?` that binds `let result = me.f()` and returns `result.withCString { envValue.pointee.NewStringUTF(env, $0) }` (with the `guard let env, let envValue = env.pointee else { return nil }` preamble — String/wire returns need `env`); (b) n-arg `func g(_ a: String) -> [TodoItem]` emits `-> jbyteArray?` returning `WireletObservableJNI.encodeArray(me.g(...), env: env)`; (c) `func h(_ a: Int32) -> Int32` emits `-> jint` returning `jint(me.h(...))` (no env needed); (d) a `Void` method is byte-for-byte unchanged from today. Match the existing test assertions' style (they compare emitted Swift source substrings).
- [ ] **Step 2:** Run the bridges emitter test target, confirm FAIL.
- [ ] **Step 3:** Update `InvokeBridgeEmitter`:
  - Add `private static func jniReturnType(for swiftType: String?) -> String?` → `nil` for Void (emit no return clause), else `jint`/`jlong`/`jboolean`/`jfloat`/`jdouble`/`jstring?`/`jbyteArray?` via `InvokeArgClassifier`.
  - In `renderZeroArg`/`renderNArg`: when a return type is present, (1) add the JNI return type to the `@_cdecl` func signature, (2) ensure the `env`/`envValue` unwrap preamble exists when the return needs it (String/wire/array) — reuse/extend `envUnwrapStatement` (String/wire args already force the preamble; if a method has NO such args but a String/wire RETURN, add the `guard let env, let envValue = env.pointee else { return nil }`), (3) bind `let result = me.method(callArgs)`, (4) marshal: primitive → `return jint(result)` etc.; `Bool` → `return result ? 1 : 0` (jboolean); String → `return result.withCString { envValue.pointee.NewStringUTF(env, $0) }`; wireFormat → `return WireletObservableJNI.encode(result, env: env)`; array → `return WireletObservableJNI.encodeArray(result, env: env)`. Void → unchanged (no return).
  - Emit a clear `#error`/diagnostic (or `fatalError` in the generated guard) for an unsupported return classification so it surfaces at build time rather than silently dropping.
- [ ] **Step 4:** Run the bridges emitter test target, confirm PASS. Run full `swift test`, confirm green.
- [ ] **Step 5:** Commit: `feat(swift-bridges): marshal @WireletExpose return values across JNI`.

---

## Phase W4 — Kotlin emitter + decode

### Task W4: `ViewModelEmitter` + `ObservableKotlinTypeMap` return path
**Files:**
- Modify: `Sources/WireletObservableKotlinEmitter/Internal/ViewModelEmitter.swift`
- Modify: `Sources/WireletObservableKotlinEmitter/Internal/ObservableKotlinTypeMap.swift`
- Test: `Tests/WireletObservableKotlinEmitterTests/ViewModelEmitterTests.swift`

- [ ] **Step 1:** Write failing tests: for `func f() -> String`, the generated Kotlin is `fun f(): String = nativeF(nativePtr)` + `private external fun nativeF(self: Long): String`. For `func g(_ a: String) -> [TodoItem]`: public `fun g(a: String): List<TodoItem> = TodoItemCodec.let { WireletList.decode(nativeG(nativePtr, a)) { TodoItemCodec.decodePayload(it) } }` (adapt to the real decode entry point — see Step 3) and `external fun nativeG(self: Long, arg0: String): ByteArray`. For `func h(_ a: Int32) -> Int32`: `fun h(a: Int): Int = nativeH(nativePtr, a)` + `external fun nativeH(self: Long, arg0: Int): Int`. Void method unchanged.
- [ ] **Step 2:** Run `swift test --filter ViewModelEmitter`, confirm FAIL.
- [ ] **Step 3:** Add `static func invokeReturn(forReturnType:config:) -> (kotlinType: String, externalFunType: String, decodeExpr: (String) -> String)?` to `ObservableKotlinTypeMap` (parallel to `invokeArg`, returning `nil` for Void): primitive → (`Int`/`Long`/…, same, `{ call in call }`); `.bool` → (`Boolean`, `Boolean`, identity); `.string` → (`String`, `String`, identity); `.array(elem)` of a wire type → (`List<Kt>`, `ByteArray`, `{ call in "WireletList.decode(\(call)) { \(codec).decodePayload(it) }" }` — VERIFY the exact decode entry point by reading how the OBSERVABLE StateFlow decodes a wire array today: `grep -rn "WireletList.decode\|decodePayload" Sources kotlin` and match it precisely); `.wireFormat` → (`Kt`, `ByteArray`, `{ call in "\(codec).decode(\(call))" }` — match the observable single-wire decode). In `ViewModelEmitter.methodWrapper`, when `method.returnTypeText` is non-nil: append `: <externalFunType>` to the `external fun`, and make the public fn `fun name(...) : <kotlinType> = <decodeExpr(nativeCall)>`. Add any needed import (`WireletList`, the codec) to the wrapper's `extraImports`.
- [ ] **Step 4:** Run `swift test --filter ViewModelEmitter`, confirm PASS; full `swift test` green.
- [ ] **Step 5:** Commit: `feat(kotlin-emitter): return type + decode for exposed methods`.

---

## Phase W5 — Example + end-to-end conformance

### Task W5: exercise a returning method in the example/conformance app
**Files:**
- Modify: the example VM `examples/observable-counter/swift/Sources/ObservableCounterJNI/TodoListVM.swift` (or whichever example the emitter snapshot/conformance tests use) — add `@WireletExpose func describe() -> String` and `@WireletExpose func snapshot() -> [TodoItem]` (a returning array of an existing wire type).
- Modify/add: the conformance test under `kotlin/conformance-tests/` (or the example's instrumented test) asserting the round-trip returns the right String / List.

- [ ] **Step 1:** Add the two returning methods to the example VM with trivial bodies (e.g. `describe()` returns a String built from state; `snapshot()` returns the current items list).
- [ ] **Step 2:** Regenerate the example's bridges (build the example per its README/build script) and confirm the generated Kotlin VM exposes `fun describe(): String` and `fun snapshot(): List<TodoItem>`.
- [ ] **Step 3:** Add/extend a conformance test that calls them across the real JNI bridge and asserts the returned values. Run the conformance test suite. If the conformance harness can't run locally (needs a device/emulator), note it and rely on the Folino device verification (Task 13) as the end-to-end check — but STILL confirm the generated Kotlin signatures are correct.
- [ ] **Step 4:** Commit: `test(observable): example + conformance for returning @WireletExpose methods`.

---

## Phase W6 — Publish

### Task W6: version bump + publish Kotlin runtime to mavenLocal, push branch
- [ ] **Step 1:** Bump the wirelet version to `0.3.3` (find the version source — `kotlin/build.gradle.kts` uses `findProperty("wireletVersion") ?: "0.0.0-SNAPSHOT"`; publishing passes `-PwireletVersion=0.3.3`). Update any docs/CHANGELOG if the repo keeps one (mirror the v0.3.2 release commit style `060f527`).
- [ ] **Step 2:** Publish to mavenLocal: `kotlin/gradlew -p kotlin :runtime:publishToMavenLocal :observable-runtime:publishToMavenLocal :gradle-plugin:publishToMavenLocal -PwireletVersion=0.3.3 --no-daemon`. Confirm artifacts land under `~/.m2/repository/io/github/jiyimeta/...0.3.3`.
- [ ] **Step 3:** Commit any version/doc changes: `release: wirelet 0.3.3 — synchronous @WireletExpose return values`. Then push the branch: `git -C <wirelet-worktree> push -u origin sync-return-values`. **(Push is a confirm-first action — the controller will confirm with the user before this step.)** Capture the pushed commit SHA (Folino re-pins to it).

---

## Phase W7 — Integrate into Folino + finish Task 12

### Task W7: re-pin, regenerate, complete the export UI
**Files (Folino worktree `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-library-export`):**
- Modify: every `Package.swift` that pins swift-wirelet by revision — `grep -rn "swift-wirelet.git" Packages` (at least `Packages/Features/Library/Package.swift`; also Reader/Settings if they pin it). Update the `revision:` to the new pushed wirelet SHA.
- Modify: the Android gradle wirelet version — `grep -rn "wirelet-observable-runtime\|io.github.jiyimeta:wirelet\|wireletVersion" Android` and bump `0.3.2` → `0.3.3` (build.gradle.kts files + settings if pinned). Ensure `mavenLocal()` is in the repo list (it is, per the Reader/Library dev setup).

- [ ] **Step 1:** Re-pin the Swift revision(s) and bump the Android gradle wirelet version to 0.3.3.
- [ ] **Step 2:** Resolve + regenerate: `FOLINO_ANDROID=1 xcrun swift package resolve --package-path Packages/Features/Library` then rebuild the Library bindings/.so: `Scripts/android-build-library-libs.sh` (release toolchain on PATH). Inspect the regenerated Kotlin: `exportFormats(scoreId): List<ScoreExportFormatWire>` and `exportScore(scoreId, format, outDir): String` (NOT `Unit`). Confirm `find Android -path '*generated*' -name '*.kt' | xargs grep -n "exportScore\|exportFormats"` shows the return types.
- [ ] **Step 3:** The Task 12 `LibraryScreen.kt` edits are already in the Folino working tree (uncommitted from the blocked attempt). Verify they now compile against the returning methods: `PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH Android/gradlew -p Android :app:compileDebugKotlin --no-daemon` → BUILD SUCCESSFUL. Fix any residual mismatch (e.g. the `withContext(Dispatchers.Default)` wrap, the `exportFormats` call site).
- [ ] **Step 4:** Commit (Folino): `feat(android-library): export from row menu + bulk CAB, share on success` (the original Task 12 message) — staging `LibraryScreen.kt`; and a separate commit `chore(android-library): re-pin swift-wirelet 0.3.3 for sync return values` staging the Package.swift + Android gradle bumps. (Two commits: the dependency bump separate from the feature wiring.)

---

## Phase W8 — Device verification (the original Task 13)
Proceed with the original plan Task 13 (rebuild `.so`, `:app:installDebug`, launch on Pixel, verify all 5 formats single + bulk end-to-end, including the JNI return-value round-trip for `exportFormats`/`exportScore`). This is the true end-to-end check of the wirelet return-value marshaling.

---

## Self-review notes
- The Kotlin decode of a returned `[B]` MUST use the same codec entry points as observable wire-array StateFlows (`WireletList.decode` + `<Wire>Codec.decodePayload`). Verify the exact symbol names in W4 Step 3 against real generated observable code before asserting test expectations.
- String/wire/array returns require the `env`/`envValue` unwrap in the `@_cdecl`; primitive returns do not. W3 must add the preamble for return-only env needs (a method with only primitive args but a String return).
- Keep `Void` returns byte-for-byte identical to today (regression-guard test in W2/W3/W4).
- Unsupported return types must fail at build time with a clear diagnostic, never silently drop the value.
