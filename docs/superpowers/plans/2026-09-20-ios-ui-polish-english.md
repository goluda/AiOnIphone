# iOS UI Polish (English UI, Models Swipe UX, Request Mini-Log) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 1) Entire app UI in English; 2) Models screen: working per-operation buttons + swipe (leading = Load/Unload, trailing = Delete), truthful error messages, visible LOADING state; 3) Home screen: live request mini-log.

**Architecture:** ModelKit coordinator gets a real per-operation guard (`Idle|Loading|Deleting`) replacing the shared `loadSlotBusy` (root cause of "everything says download in progress"). OpenAICompat `HTTPServer` gains an optional `onRequest` callback (in-process, no wire change). The app renders new states/errors in English and hosts a `RequestLog` ring buffer.

**Spec:** `docs/superpowers/specs/2026-09-20-ios-ui-polish-english-design.md`

## Global Constraints

- **NO wire/spec drift:** `ServerAPIError` cases, `type` tokens and HTTP statuses stay byte-identical (`download_in_progress` → 409 etc.). `XRoutesTests` (`Packages/OpenAICompat/Tests/OpenAICompatTests/XRoutesTests.swift:118-124`) must pass unchanged. Bridge maps new coordinator errors `.loadInProgress/.deleteInProgress` → `.downloadInProgress`; only the **app's** `humanize` text becomes per-op.
- **No ChatML special-token literals anywhere** (AGENTS.md) — refer to them descriptively in all files including commit messages.
- Layer rules: ModelKit = Foundation+CryptoKit only; OpenAICompat = Foundation+Network only, never imports ModelKit; UIKit/SwiftUI only in app target.
- Test commands (this machine): `PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit`, `PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat`, `PATH=/usr/bin:$PATH swift test --package-path PocketServe1` (app tests), build: `xcodebuild -project PocketServe1/PocketServe1.xcodeproj -scheme PocketServe1 -destination 'generic/platform=iOS Simulator' build`.
- Keep flaky-sensitive timing windows as-is or more generous (KNOWN_ISSUES flaky note).
- English in all new comments/docs/commits.

---

### Task 1: ModelKit — per-operation guard + truthful error cases

Ground truth: `DownloadAPIError` is declared in `DownloadCoordinator.swift:3-5`; the flag is `private var loadSlotBusy = false` (`:27`), used by `load(id:)` (`:57-59`) and `delete(id:)` (`:79-81`). `start(repo:revision:)` keeps `downloadInProgress` (mapped from `HFDownloaderError.inProgress`) — untouched.

**Files:**
- Modify: `Packages/ModelKit/Sources/ModelKit/DownloadCoordinator.swift:3-5` (`DownloadAPIError`), `:27` (flag), `:57-69` (`load`), `:79-81` (`delete`)
- Test: `Packages/ModelKit/Tests/ModelKitTests/CoordinatorTests.swift:146-166` (`testLoadSlotRejectsConcurrentLoads`) + two new tests

- [ ] **Step 1: Add error cases** (`DownloadCoordinator.swift:3-5`):

```swift
public enum DownloadAPIError: Error, Equatable {
    case invalidRequest(String), downloadInProgress, loadInProgress, deleteInProgress,
         notReady, notLoaded, notFound, memoryPressure, downloadFailed(String), http(Int), io(String)
}
```

(The compiler will flag the non-exhaustive switches in `ModelsViewModel.bridge`/`humanize` — those are Task 3; for now ModelKit itself has no exhaustive switch over this enum outside the coordinator. Verify with `swift build --package-path Packages/ModelKit`.)

- [ ] **Step 2: Write failing tests** (append to `CoordinatorTests.swift`; fixture style copies `testLoadSlotRejectsConcurrentLoads` — store on tmp dir, `SlowLoader` holds `loader.load` for 100 ms):

```swift
func testDeleteDuringLoadRejected() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
    let store = ModelStore(root: root)
    await store.upsert(ModelRecord(id: "mlx:s", repo: "s", revision: "r", quant: nil, bytesOnDisk: 5, downloadedAt: Date(), state: .ready))
    let c = DownloadCoordinator(downloader: nil, store: store, loader: SlowLoader())
    let load = Task { try? await c.load(id: "mlx:s") }
    try await Task.sleep(nanoseconds: 50_000_000) // within SlowLoader's 100 ms window
    do { try await c.delete(id: "mlx:s"); XCTFail("delete must be rejected while loading") }
    catch DownloadAPIError.loadInProgress {}
    _ = await load.value
}
```

- [ ] **Step 3: Run, confirm red:** `PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit --filter CoordinatorTests` (delete currently hits `loadSlotBusy` → `downloadInProgress`, wrong case; enum cases don't exist yet if Step 2 ran first).

- [ ] **Step 4: Implement the operation guard.** Replace `:27` flag and the guards:

```swift
private enum Operation { case idle, loading, deleting }
private var operation: Operation = .idle
```

`load(id:)` head (`:57-59`):

```swift
public func load(id: String) async throws {
    switch operation {
    case .loading: throw DownloadAPIError.loadInProgress
    case .deleting: throw DownloadAPIError.deleteInProgress
    case .idle: operation = .loading
    }
    defer { operation = .idle }
```

`delete(id:)` head (`:79-81`):

```swift
public func delete(id: String) async throws {
    switch operation {
    case .deleting: throw DownloadAPIError.deleteInProgress
    case .loading: throw DownloadAPIError.loadInProgress
    case .idle: operation = .deleting
    }
    defer { operation = .idle }
```

All bodies below the guards stay byte-identical. `unload` stays unguarded (fast, idempotent-ish via `notLoaded`).

- [ ] **Step 5: Update existing test** `testLoadSlotRejectsConcurrentLoads` (`CoordinatorTests.swift:159`):

```swift
if (e as? DownloadAPIError) == .loadInProgress { inProgress += 1 } else { XCTFail("\(e)") }
```

(Rename local `inProgress` → `rejected` for honesty if trivial; keep assertions `successes == 1`, `rejected == 1`, `loader.loadCalls == 1`.)

- [ ] **Step 6: Run ModelKit tests green** (command as Step 3; full package too).

- [ ] **Step 7: Commit:** `git add Packages/ModelKit && git commit -m "fix(modelkit): per-operation guards — load/delete no longer masquerade as download-in-progress"`

---

### Task 2: OpenAICompat — optional onRequest event hook

Ground truth: `HTTPServer.init(engines: [any InferenceEngine], extension:)` (`HTTPServer.swift:11-15`); every terminal response goes through `sendRaw` (`:215-218`) — `sendJSON` (`:211`) and `sendError` both delegate to it. SSE header is written directly via `conn.send` (`:169-170`). Tests use XCTest + `URLSession` against `start(port: 0)`.

**Files:**
- Create: `Packages/OpenAICompat/Sources/OpenAICompat/RequestEvent.swift`
- Modify: `Packages/OpenAICompat/Sources/OpenAICompat/HTTPServer.swift:5-15,:70,:129-131,:169-170,:211-218`
- Test: `Packages/OpenAICompat/Tests/OpenAICompatTests/HTTPServerTests.swift`

- [ ] **Step 1: Failing test** (append to `HTTPServerTests.swift`, XCTest style):

```swift
func testRequestEventsRecordedPerRequest() async throws {
    actor Collector { var events: [RequestEvent] = []; func add(_ e: RequestEvent) { events.append(e) } }
    let collector = Collector()
    let s = HTTPServer(engines: [MockEngine()]) { await collector.add($0) }
    let port = try await s.start(port: 0); defer { Task { await s.stop() } }
    _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
    req.httpMethod = "POST"; req.httpBody = try JSONEncoder().encode(ChatCompletionRequest(model: "mock", messages: [ChatMessage(role: "user", content: "x")]))
    _ = try await URLSession.shared.data(for: req)
    _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/nope")!)
    try await Task.sleep(nanoseconds: 500_000_000)
    let events = await collector.events
    XCTAssertEqual(events.first { $0.path == "/health" }?.status, 200)
    XCTAssertEqual(events.first { $0.path == "/health" }?.method, "GET")
    let chat = events.first { $0.path == "/v1/chat/completions" }
    XCTAssertEqual(chat?.status, 200)
    XCTAssertEqual(chat?.model, "mock")
    XCTAssertEqual(events.first { $0.path == "/nope" }?.status, 404)
    XCTAssertTrue(events.allSatisfy { $0.durationMs >= 0 })
}
```

- [ ] **Step 2: Run → red** (`RequestEvent`/trailing-closure init unknown): `PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat --filter HTTPServerTests`

- [ ] **Step 3: Implement `RequestEvent.swift`:**

```swift
import Foundation

public struct RequestEvent: Sendable {
    public let method: String
    public let path: String
    public let status: Int
    public let durationMs: Int
    public let model: String?
    public let timestamp: Date
    public init(method: String, path: String, status: Int, durationMs: Int, model: String?, timestamp: Date = Date()) {
        self.method = method; self.path = path; self.status = status
        self.durationMs = durationMs; self.model = model; self.timestamp = timestamp
    }
}
```

- [ ] **Step 4: Instrument `HTTPServer.swift`:**

State + init (`:5-15`):

```swift
private let onRequest: (@Sendable (RequestEvent) async -> Void)?
private var responseStatus = 0
private var currentModel: String?

public init(engines: [any InferenceEngine], extension ext: ServerExtension? = nil,
            onRequest: (@Sendable (RequestEvent) async -> Void)? = nil) {
    self.engines = engines
    self.ext = ext
    self.onRequest = onRequest
}
```

`route` head (`:70`):

```swift
private func route(_ req: HTTPRequest, _ conn: NWConnection) async {
    responseStatus = 0; currentModel = nil
    let start = DispatchTime.now()
    defer { fire(req, start) }
```

Capture model after chat decode (`:129-131`, after successful decode): `currentModel = request.model`.

SSE header (`:169-170`, just before `conn.send(content: header, ...)`): `responseStatus = 200` (mid-stream engine throws keep 200 — header was already sent; honest).

Chokepoint in `sendRaw` (`:215`) first line: `responseStatus = status` (covers `sendJSON`, `sendError`, all `/x/*` sends).

Emit helper:

```swift
private func fire(_ req: HTTPRequest, _ start: DispatchTime) {
    guard let onRequest else { return }
    let ms = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    let event = RequestEvent(method: req.method, path: req.path, status: responseStatus, durationMs: ms, model: currentModel)
    Task { await onRequest(event) }
}
```

One event per request guaranteed: `Connection: close` per response (`:217`), one `route` per parsed request, `defer` fires exactly once. Unparseable garbage never reaches `route` → no event (fine).

- [ ] **Step 5: Run full OpenAICompat suite** — new test + `XRoutesTests`/`HTTPServerTests` all green: `PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat`

- [ ] **Step 6: Commit:** `git add -A && git commit -m "feat(openai-compat): optional onRequest hook emitting RequestEvent per handled request"`

---

### Task 3: ModelsViewModel — bridge, English humanize, in-process operation state

Ground truth: VM methods `load(_ id: String)` / `unload(_ id: String)` / `deleteFiles(_ id: String)`; `humanize` is `static func humanize(_ e: DownloadAPIError) -> String`; bridge is `nonisolated static func bridge(_ e: DownloadAPIError, op: Op) -> ServerAPIError`; alert state = `@Published var alert: String?`. HF session wired in `init`: `HFDownloader(store:client:HFClient(session:.shared),session:.shared,root:root)`.

**Files:**
- Modify: `PocketServe1/PocketServe1/ModelsViewModel.swift`

- [ ] **Step 1: Bridge maps new cases, wire unchanged** (`bridge`, after `case .downloadInProgress`):

```swift
case .loadInProgress, .deleteInProgress: return .downloadInProgress // wire token nie zmienia się (spec §5)
```

- [ ] **Step 2: In-process op flags** (visible LOADING… without new polling):

```swift
@Published var loadingId: String?
@Published var deletingId: String?
```

Rewire the three actions (same shape as existing, flags around the await):

```swift
func load(_ id: String) { Task { loadingId = id
    do { try await coordinator.load(id: id) } catch let e as DownloadAPIError { alert = Self.humanize(e) }
    loadingId = nil; await refresh() } }
func deleteFiles(_ id: String) { Task { deletingId = id
    do { try await coordinator.delete(id: id) }
    catch let e as DownloadAPIError { alert = Self.humanize(e) }
    catch { alert = "Delete failed" }
    deletingId = nil; await refresh() } }
```

(`unload` unchanged.)

- [ ] **Step 3: English `humanize`, truthful per-op** (replace Polish bodies at `:118-131`):

```swift
static func humanize(_ e: DownloadAPIError) -> String {
    switch e {
    case .invalidRequest: return "Not a valid mlx repo"
    case .memoryPressure: return "Model too large — pick a smaller quantization"
    case .downloadInProgress: return "Download already in progress"
    case .loadInProgress: return "Model is already loading"
    case .deleteInProgress: return "Cannot delete — another operation in progress"
    case .notReady: return "Download incomplete — resume it first"
    case .notFound: return "Model not found locally"
    case .notLoaded: return "Unload the model first"
    case .downloadFailed: return "Download failed — retry the import"
    case .http(let c): return "HF server replied with error \(c)"
    case .io: return "Disk error"
    }
}
```

- [ ] **Step 4: HFDownloader timeouts at the composition root** (`init`, replace `.shared` sessions):

```swift
let cfg = URLSessionConfiguration.default
cfg.timeoutIntervalForRequest = 60
cfg.timeoutIntervalForResource = 3600 // large weights need room; stalls die at 60 s idle
let session = URLSession(configuration: cfg)
let dl = HFDownloader(store: store, client: HFClient(session: session), session: session, root: root)
```

Fixes KNOWN_ISSUES R-2 (stalled download parking the coordinator in `.downloading` forever).

- [ ] **Step 5: English presets notes** (`:28-31`): `"fastest start — test model"`, `"good Polish — recommended first model"`, `"smaller, higher quality"`, `"largest — just under the 6 GB limit"`. `deleteFiles` fallback `"Delete failed"` (Step 2).

- [ ] **Step 6: Commit:** `git add PocketServe1/PocketServe1/ModelsViewModel.swift && git commit -m "feat(app): truthful English operation errors, in-process loading/deleting state, downloader timeouts"`

---

### Task 4: ModelsView — swipe actions + chips

Ground truth: rows are inline in `Section("Modele")` `ForEach(vm.records, id: \.id)`; `rec.loaded` is `Bool`; chip exists (`ZAŁADOWANY` capsule); buttons: `Odładuj`/`Wczytaj`/`Ponów import`/`Usuń pliki` (`.disabled(rec.loaded)`); alert binding via `vm.alert`.

**Files:**
- Modify: `PocketServe1/PocketServe1/ModelsView.swift`
- Create: `PocketServe1/PocketServe1/ModelRow.swift` (extract row so `.swipeActions` can live on a top-level list row)

- [ ] **Step 1: Extract `ModelRow`** (new file, `struct ModelRow: View { let rec: ModelRecord; @ObservedObject var vm: ModelsViewModel; @State private var confirmDelete = false }`) with body = the current inline VStack, translated, plus:

```swift
.contentShape(Rectangle())
.swipeActions(edge: .leading) {
    if rec.loaded {
        Button("Unload") { vm.unload(rec.id) }.tint(.orange)
    } else if rec.state == .ready {
        Button(vm.loadingId == rec.id ? "Loading…" : "Load") { vm.load(rec.id) }
            .tint(.green).disabled(vm.loadingId != nil)
    }
}
.swipeActions(edge: .trailing) {
    Button("Delete", role: .destructive) { confirmDelete = true }
        .disabled(vm.deletingId == rec.id || rec.loaded)
}
.confirmationDialog("Delete model files?", isPresented: $confirmDelete, titleVisibility: .visible) {
    Button("Delete files", role: .destructive) { vm.deleteFiles(rec.id) }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("Removes downloaded files from this device. Re-import from Hugging Face anytime.")
}
```

- [ ] **Step 2: Status chip line** (replaces `\(rec.quant) ?? "?" · … · \(rec.state.rawValue)`):

```swift
Text("\(rec.quant ?? "?") · \(format(rec.bytesOnDisk))")
    .font(.caption).foregroundStyle(.secondary)
Text(chip)                            // capsule, monospace caption
```

```swift
private var chip: String {
    if vm.loadingId == rec.id { return "LOADING…" }
    if vm.deletingId == rec.id { return "DELETING…" }
    if rec.loaded { return "LOADED" }
    switch rec.state {
    case .ready: return "READY"
    case .downloading:
        let pct = Int((Double(vm.status.bytesDone) / Double(max(1, vm.status.bytesTotal)) * 100).rounded())
        return vm.status.repo == rec.repo ? "DOWNLOADING \(pct)%" : "QUEUED"
    case .verifying: return "VERIFYING…"
    case .failed: return "FAILED"
    case .idle: return "NOT DOWNLOADED"
    }
}
```

Chip colors: LOADED green, LOADING/VERIFYING/QUEUED blue, READY secondary, DOWNLOADING blue, FAILED red, NOT DOWNLOADED gray.

- [ ] **Step 3: Keep visible buttons row but truthful** (accessibility — swipe-only is not enough): `Wczytaj`→`Load` (shows `Loading…` + `ProgressView().controlSize(.imageSize)` while `vm.loadingId == rec.id`), `Odładuj`→`Unload`, `Ponów import`→`Retry import`, `Usuń pliki`→`Delete` (opens `confirmDelete`, no longer directly destructive), delete `.disabled(rec.loaded)` replaced by `.disabled(vm.deletingId == rec.id)` — the *coordinator* now gives the truthful error if the user races it.

- [ ] **Step 4: Section headers/chrome English:** `Section("Hugging Face import")`, `Section("Models")`, `"No models downloaded yet"`, preset dialog `"Which model to import?"`/`"Sample models from mlx-community. Sizes approximate."`/`"Cancel"`, `navigationTitle("Models")`, subtitle fallback `"apple-afm only"`, memory banner `"Low memory — model unloaded automatically"`, `TextField("e.g. mlx-community/Qwen3-1.7B-4bit"…)`.

- [ ] **Step 5: Add `ModelRow` to Xcode target** (synchronized root group — file drop is enough; verify build).

- [ ] **Step 6: Build simulator** (Global Constraints).

- [ ] **Step 7: Commit:** `git add PocketServe1 && git commit -m "feat(app): Models screen — swipe load/unload/delete, truthful English chips"`

---

### Task 5: Home mini-log + RequestLog + server wiring

Ground truth: `ServerModel.init()` does `server = HTTPServer(engines: [AFMEngine(), MLXEngine.shared])` (`ServerModel.swift:14`); ContentView is a `VStack` in `NavigationStack` with Start/Stop button and three NavigationLinks (`:13-17`).

**Files:**
- Create: `PocketServe1/PocketServe1/RequestLog.swift`
- Modify: `PocketServe1/PocketServe1/ServerModel.swift:14`, `ContentView.swift`

- [ ] **Step 1: `RequestLog.swift`:**

```swift
import Foundation
import SwiftUI
import OpenAICompat

@MainActor
final class RequestLog: ObservableObject {
    static let shared = RequestLog()
    @Published private(set) var events: [RequestEvent] = []
    private init() {}
    func record(_ e: RequestEvent) {
        events.append(e)
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
    func clear() { events = [] }
}

extension RequestEvent {
    var timeLabel: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: timestamp)
    }
    var statusColor: Color {
        if (200..<300).contains(status) { return .green }
        if (400..<500).contains(status) { return .orange }
        return .red
    }
}
```

- [ ] **Step 2: Wire in `ServerModel.init` (`:14`):**

```swift
override init() {
    server = HTTPServer(engines: [AFMEngine(), MLXEngine.shared]) { await RequestLog.shared.record($0) }
}
```

- [ ] **Step 3: `ContentView` mini-log** — add below the NavigationLinks (visible only while running):

```swift
if model.running {
    RequestLogView()
}
```

New `RequestLogView` (same file): `@ObservedObject private var log = RequestLog.shared` (`init` `_observedObject`), a `GroupBox`-free simple VStack:

```swift
struct RequestLogView: View {
    @ObservedObject private var log: RequestLog
    init() { _log = ObservedObject(wrappedValue: .shared) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Requests").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                if !log.events.isEmpty { Button("Clear") { log.clear() }.font(.caption) }
            }
            if log.events.isEmpty {
                Text("Waiting for requests…").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(log.events.suffix(8).enumerated()), id: \.offset) { _, e in
                    HStack(spacing: 6) {
                        Text(e.timeLabel).foregroundStyle(.secondary)
                        Text(e.method).bold()
                        Text(e.path).lineLimit(1)
                        Spacer()
                        Text("\(e.status)").foregroundStyle(e.statusColor)
                        Text("\(e.durationMs)ms").foregroundStyle(.secondary)
                    }.font(.system(.caption2, design: .monospaced))
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }
}
```

- [ ] **Step 4: Build + app tests:** full simulator build (Global Constraints); `xcodebuild … test` only if the scheme's test action already works headless — otherwise compile-gate + package suites are the CI proof (device smoke is the user's gate).

- [ ] **Step 5: Commit:** `git add PocketServe1 && git commit -m "feat(app): live request mini-log on home screen"`

---

### Task 6: Final English sweep + i18n config + gate

**Files:**
- Modify: `ContentView.swift`, `ChatView.swift`, `EndpointsView.swift`, `ChatService.swift`, `ServerModel.swift`, `AFMEngine.swift`, `MLXEngine.swift`, `Info.plist`
- Test: `PocketServe1/PocketServe1Tests/PocketServe1Tests.swift`

- [ ] **Step 1: Translate remaining strings (grep-verified inventory):**
  - `ContentView.swift`: `"Modele"`→`"Models"`, `"Czat"`→`"Chat"` (API stays). Stop/Start already English.
  - `ChatView.swift:19,:21,:29,:57,:65`: `"Server offline"` / `"Start the server to chat."` / `"Start server"` / `"Type a message…"` / `navigationTitle("Chat")`.
  - `EndpointsView.swift:10-15,:16-19,:30,:32,:35,:37-39,:46`: rows → `"server health"`, `"model list"`, descriptions `"OpenAI shape — stream + JSON"` (ok), `"list + model states"`, `"import from Hugging Face"`, `"download progress"`, `"load engine"`, `"unload engine"`, `"delete model files"`; `"Base URL"` ok; `"server off"`; `Section("Management (/x/*)")`; error-code rows `"429 — server busy"`, `"409 — model not loaded"`, `"404 — unknown model / endpoint"`, `"400 — bad request"`.
  - `ChatService.swift:34,:60,:73-76`: `"Unexpected server response"`, `"No connection to the server — start it on the home screen"`, `mapError`: 404 `detail ?? "Unknown model"`, 409 `"Model not loaded — load it in the Models view"`, 429 `"Server busy — wait for the current request to finish"`, 400 `"Bad request"`, default `detail ?? "Server error (\(status))"`.
  - `ServerModel.swift:26`: `"brak LAN"` → `"no LAN"`.
  - `AFMEngine.swift:44-45`: → `"Apple Intelligence is turned off"` (log + NSError description).
  - `MLXEngine.swift:87`: `"model nie załadowany"` → `"model not loaded"`.
- [ ] **Step 2: `Info.plist`:** add `CFBundleDevelopmentRegion = en` (key currently absent — verified).
- [ ] **Step 3: `PocketServe1Tests.swift`** (Swift Testing, `@testable import PocketServe1` already present):

```swift
@Test func humanizeDistinguishesLoadFromDelete() {
    #expect(ModelsViewModel.humanize(.loadInProgress) == "Model is already loading")
    #expect(ModelsViewModel.humanize(.deleteInProgress) == "Cannot delete — another operation in progress")
    #expect(ModelsViewModel.humanize(.downloadInProgress) == "Download already in progress")
}
@Test func bridgeKeepsWireTokenForNewOps() {
    #expect(ModelsViewModel.bridge(.loadInProgress, op: .load) == .downloadInProgress)
    #expect(ModelsViewModel.bridge(.deleteInProgress, op: .delete) == .downloadInProgress)
}
```

(`ServerAPIError` must become `Equatable` — add the conform in Task 2's file or Task 3; it is a plain enum with associated String/Int values, synthesis works.)

- [ ] **Step 4: i18n gate:** `grep -rn '[ąćęłńóśźż]' PocketServe1/PocketServe1/*.swift` — zero hits in string literals (Polish comments: translate any in files you touched; leave untouched files' comments for Phase 4a per LOCALIZATION.md).
- [ ] **Step 5: Full verification:** ModelKit + OpenAICompat suites green, simulator build `BUILD SUCCEEDED`.
- [ ] **Step 6: Commit:** `git commit -am "feat(app): complete English UI; CFBundleDevelopmentRegion=en"`

---

### Task 7: Docs, PR, handoff

- [ ] **Step 1: Update docs:** `docs/LOCALIZATION.md` — in-place English done 2026-09-20, String catalogs deferred to Phase 4b. `docs/KNOWN_ISSUES.md` — add new rows: R-1 (delete-after-cancel dead state) and R-2 (downloader no timeouts) → FIXED by this work if the change landed; otherwise keep open with cause noted honestly.
- [ ] **Step 2: Push + open PR** (`gh` broken → GitHub MCP `create_pull_request`; fallback: hand user the compare URL).
- [ ] **Step 3: Report:** spec/plan/PR links, gates output, device-smoke checklist for the user (swipe load/unload/delete, mini-log with 2-3 chats).
