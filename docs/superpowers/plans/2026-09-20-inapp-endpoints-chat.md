# In-App Endpoints Info + Chat Window — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "API" screen listing all supported endpoints (with live copyable base URL) and a minimal chat window that tests the loaded model directly on the phone via self-request to the built-in server.

**Architecture:** Chat consumes `POST /v1/chat/completions` over loopback HTTP (`127.0.0.1:<port>`) with `stream: true`, framed by the existing `SSEParser` from `OpenAICompat`. All new UI + networking client live in app target `PocketServe1`; `Packages/` is NOT touched. New files are auto-included by the Xcode synchronized root group — never edit `project.pbxproj`.

**Tech Stack:** SwiftUI (iOS 26 target, Xcode 27 beta), URLSession bytes streaming, OpenAICompat public DTOs (`ChatCompletionRequest`, `ChatCompletionChunk`, `OpenAIErrorBody`, `ModelsList`, `SSEParser`), swift-testing (`import Testing`) in app tests.

## Global Constraints

- NEVER write raw ChatML special-token literals (`<|`…`|>`) into any file, chat message, or commit — refer descriptively ("im_start/im_end special tokens"). Replace `<|` with `__|`, `|>` with `|__` if ever needed.
- Layer rules: `Packages/OpenAICompat` = Foundation only; `Packages/ModelKit` = Foundation+CryptoKit; UIKit/SwiftUI only in app target `PocketServe1`. **This feature changes ZERO files under `Packages/`.**
- Environment: always `PATH=/usr/bin:$PATH swift …` (bare swift/rg are broken shims). `gh` CLI broken — use local git merge; GitHub MCP PR tools may be disabled → fallback is `git merge --no-ff` + `git push origin main`.
- UI strings in Polish (app translated to English later in Phase 4a). Code comments may be Polish (match existing style). Commit messages in English.
- Xcode scheme diagnostics stay OFF (GPU Frame Capture: Disabled) — do not re-enable.
- No new dependencies. ATS is not evaluated for literal-IP URLs (`http://127.0.0.1` allowed) — verify on simulator.
- Branch: `feat/inapp-endpoints-chat` (already exists, spec @ its HEAD).
- Specs: `docs/superpowers/specs/2026-09-20-inapp-endpoints-chat-design.md`.

---

### Task 1: ChatService — loopback streaming client (app target)

**Files:**
- Create: `PocketServe1/PocketServe1/ChatService.swift`
- Test: `PocketServe1/PocketServe1Tests/ChatServiceTests.swift`

**Interfaces:**
- Consumes: `OpenAICompat` public: `HTTPServer(engines:)`, `MockEngine(id:contextWindow:tokens:latency:)`, `SSEParser.feed(Data) -> [String]`, `ChatCompletionRequest(model:messages:stream:temperature:maxTokens:)`, `ChatCompletionChunk`, `OpenAIErrorBody`, `ModelsList`, `ChatMessage(role:content:)`, `InferenceEngine` protocol.
- Produces: `@MainActor final class ChatService` with:
  - `func models(port: UInt16) async throws -> [String]`
  - `func stream(port: UInt16, request: ChatCompletionRequest) -> AsyncThrowingStream<String, any Error>`
  - `func stop()`
  - `struct ChatServiceError: LocalizedError { let userMessage: String }`
  - `static func mapError(status: Int, detail: String?) -> String`

- [ ] **Step 1: Write the failing tests**

`ChatServiceTests.swift` — spin up the REAL `HTTPServer` on an ephemeral loopback port inside the test (proves end-to-end framing on simulator):

```swift
import Testing
import Foundation
import OpenAICompat
@testable import PocketServe1

@MainActor
@Test struct ChatServiceTests {
    // Serwer in-process na porcie losowym — prawdziwy HTTP przez loopback.
    private func withServer(_ block: (UInt16) async throws -> Void) async throws {
        let server = HTTPServer(engines: [MockEngine(id: "apple-afm", tokens: ["To", " jest", " mock"])])
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        try await block(port)
    }

    @Test func modelsReturnsIds() async throws {
        try await withServer { port in
            let ids = try await ChatService().models(port: port)
            #expect(ids == ["apple-afm"])
        }
    }

    @Test func streamCollectsTokens() async throws {
        try await withServer { port in
            let req = ChatCompletionRequest(model: "apple-afm",
                messages: [ChatMessage(role: "user", content: "czość")], stream: true)
            var out = ""
            for try await tok in ChatService().stream(port: port, request: req) { out += tok }
            #expect(out == "To jest mock")
        }
    }

    @Test func unknownModelThrowsUserMessage() async throws {
        try await withServer { port in
            let req = ChatCompletionRequest(model: "mlx:none",
                messages: [ChatMessage(role: "user", content: "hej")], stream: true)
            do {
                for try await _ in ChatService().stream(port: port, request: req) {}
                Issue.record("oczekiwano rzucenia błędu")
            } catch let e as ChatServiceError {
                #expect(e.userMessage.contains("404") || e.userMessage.lowercased().contains("model"))
            }
        }
    }

    @Test func midStreamErrorSurfacesMessage() async throws {
        let server = HTTPServer(engines: [ThrowingMidStreamEngine()])
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        let req = ChatCompletionRequest(model: "boom",
            messages: [ChatMessage(role: "user", content: "x")], stream: true)
        do {
            for try await _ in ChatService().stream(port: port, request: req) {}
            Issue.record("oczekiwano rzucenia błędu")
        } catch let e as ChatServiceError {
            #expect(e.userMessage == "engine padł")
        }
    }
}

private struct ThrowingMidStreamEngine: InferenceEngine {
    var id: String { "boom" }
    var contextWindow: Int { 4096 }
    func stream(prompt: String, params: GenerationParams) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { c in
            c.yield("ok ")
            struct Boom: Error, LocalizedError { var errorDescription: String? { "engine padł" } }
            c.finish(throwing: Boom())
        }
    }
}
```

Note: `mlx:none` is never routable (placeholder rule) → 404 path. If dispatch returns 409 instead, accept both in the assertion (done above).

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project PocketServe1/PocketServe1.xcodeproj -scheme PocketServe1 -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -A2 "ChatService\|error:" | head -30`
Expected: FAIL — "cannot find 'ChatService' in scope" (compile error is the red state).

- [ ] **Step 3: Implement ChatService**

`ChatService.swift`:

```swift
import Foundation
import OpenAICompat

struct ChatServiceError: LocalizedError {
    let userMessage: String
    var errorDescription: String? { userMessage }
}

// Klient loopback-API własnego serwera: czat w aplikacji przechodzi przez ten sam HTTP co zewnętrzni klienci.
@MainActor
final class ChatService {
    private var activeTask: Task<Void, Never>?

    func models(port: UInt16) async throws -> [String] {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(ModelsList.self, from: data).data.map(\.id)
    }

    func stream(port: UInt16, request: ChatCompletionRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 300 // mlx: pierwsze tokeny mogą trwać długo
                do {
                    req.httpBody = try JSONEncoder().encode(request)
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw ChatServiceError(userMessage: "Nieoczekiwana odpowiedź serwera")
                    }
                    if http.statusCode != 200 {
                        var body = Data()
                        for try await b in bytes { body.append(b) }
                        let detail = try? JSONDecoder().decode(OpenAIErrorBody.self, from: body)
                        throw ChatServiceError(userMessage: Self.mapError(status: http.statusCode, detail: detail?.error.message))
                    }
                    var parser = SSEParser()
                    for try await b in bytes {
                        for payload in parser.feed(Data([b])) {
                            let data = Data(payload.utf8)
                            // Ramka błędu w trakcie streamu (serwer: SSEEncoder.encodeError) → odrzuć strumień z komunikatem.
                            if let err = try? JSONDecoder().decode(OpenAIErrorBody.self, from: data) {
                                throw ChatServiceError(userMessage: err.error.message)
                            }
                            if let tok = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data),
                               let content = tok.choices.first?.delta.content {
                                continuation.yield(content)
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish() // Stop przycisku — normalne zakończenie
                } catch let e as ChatServiceError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: ChatServiceError(userMessage: "Brak połączenia z serwerem — uruchom go na ekranie głównym"))
                }
            }
            activeTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() { activeTask?.cancel(); activeTask = nil }

    static func mapError(status: Int, detail: String?) -> String {
        switch status {
        case 404: return detail ?? "Nieznany model"
        case 409: return "Model nie załadowany — wczytaj go w widoku Modele"
        case 429: return "Serwer zajęty — poczekaj na koniec bieżącego żądania"
        case 400: return "Złe zapytanie do serwera"
        default: return detail ?? "Błąd serwera (\(status))"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same xcodebuild test command as Step 2.
Expected: PASS — 4/4 ChatServiceTests. Also confirm existing PocketServe1Tests example still passes.

- [ ] **Step 5: Commit**

`git add PocketServe1/PocketServe1/ChatService.swift PocketServe1/PocketServe1Tests/ChatServiceTests.swift && git commit -m "feat: add loopback ChatService with SSE streaming and typed errors"`

---

### Task 2: Chat UI — ChatViewModel + ChatView + EndpointsView + navigation

**Files:**
- Create: `PocketServe1/PocketServe1/ChatViewModel.swift`
- Create: `PocketServe1/PocketServe1/ChatView.swift`
- Create: `PocketServe1/PocketServe1/EndpointsView.swift`
- Modify: `PocketServe1/PocketServe1/ContentView.swift` (add two NavigationLinks after "Modele")

**Interfaces:**
- Consumes: `ChatService` (Task 1, exact signatures above), `ServerModel` (`@Published running/port/address`, `start()`).
- Produces: `ChatViewModel(serverModel:)`, `ChatView(model: ServerModel)`, `EndpointsView(model: ServerModel)` — consumed by ContentView links.

- [ ] **Step 1: ChatViewModel**

`ChatViewModel.swift`:

```swift
import SwiftUI
import Combine
import OpenAICompat

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var streamingText = ""
    @Published var isStreaming = false
    @Published var availableModels: [String] = []
    @Published var selectedModel = "apple-afm"
    @Published var errorText: String?

    private let service = ChatService()
    private weak var serverModel: ServerModel?

    init(serverModel: ServerModel) { self.serverModel = serverModel }

    func refreshModels() async {
        guard let sm = serverModel, sm.running else { return }
        do {
            availableModels = try await service.models(port: sm.port)
            if !availableModels.contains(selectedModel), let first = availableModels.first { selectedModel = first }
        } catch { /* serwer wyłączony — placeholder UI pokrywa stan */ }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, let sm = serverModel, sm.running else { return }
        let port = sm.port
        draft = ""
        messages.append(ChatMessage(role: "user", content: text))
        errorText = nil
        streamingText = ""
        isStreaming = true
        let history = messages
        let model = selectedModel
        Task {
            do {
                let req = ChatCompletionRequest(model: model, messages: history, stream: true)
                for try await token in service.stream(port: port, request: req) { streamingText += token }
                messages.append(ChatMessage(role: "assistant", content: streamingText))
            } catch let e as ChatServiceError {
                errorText = e.userMessage
                if !streamingText.isEmpty { messages.append(ChatMessage(role: "assistant", content: streamingText)) }
            } catch { errorText = "\(error)" }
            streamingText = ""
            isStreaming = false
        }
    }

    func stop() { service.stop() }
}
```

- [ ] **Step 2: ChatView**

`ChatView.swift` — bubbles, auto-scroll, cursor while streaming, offline placeholder, model picker:

```swift
import SwiftUI

struct ChatView: View {
    @ObservedObject var model: ServerModel
    @StateObject private var vm: ChatViewModel

    init(model: ServerModel) { _vm = StateObject(wrappedValue: ChatViewModel(serverModel: model)) }

    var body: some View {
        VStack(spacing: 0) {
            if !model.running {
                ContentUnavailableView("Serwer wyłączony", systemImage: "wifi.slash",
                    description: Text("Uruchom serwer, aby czatować."))
                    .frame(maxHeight: .infinity)
                Button("Start serwera") { model.start() }.buttonStyle(.borderedProminent).padding(.bottom)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(vm.messages.enumerated()), id: \.offset) { _, m in
                                bubble(m)
                            }
                            if vm.isStreaming {
                                Text(vm.streamingText + "▌")
                                    .padding(10).frame(maxWidth: 280, alignment: .leading)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                                    .id("streaming")
                            }
                        }.padding()
                    }
                    .onChange(of: vm.streamingText) { _, _ in proxy.scrollTo("streaming", anchor: .bottom) }
                    .onChange(of: vm.messages.count) { _, _ in
                        if let last = vm.messages.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                if let err = vm.errorText {
                    Text(err).font(.footnote).foregroundStyle(.white)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal)
                }
                HStack {
                    TextField("Napisz wiadomość…", text: $vm.draft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { vm.send() }
                    if vm.isStreaming {
                        Button("Stop") { vm.stop() }
                    } else {
                        Button { vm.send() } label: { Image(systemName: "arrow.up.circle.fill") }
                            .font(.title2)
                            .disabled(vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.availableModels.isEmpty)
                    }
                }.padding()
            }
        }
        .navigationTitle("Czat")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Model", selection: $vm.selectedModel) {
                    ForEach(vm.availableModels, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).disabled(!model.running)
            }
        }
        .task { await vm.refreshModels() }
        .onChange(of: model.running) { _, on in if on { Task { await vm.refreshModels() } } }
        .onDisappear { vm.stop() }
    }

    @ViewBuilder private func bubble(_ m: ChatMessage) -> some View {
        if m.role == "user" {
            HStack { Spacer(); Text(m.content).padding(10)
                .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 280, alignment: .trailing) }.id(vm.messages.count)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("assistant").font(.caption2).foregroundStyle(.secondary)
                Text(m.content).textSelection(.enabled).padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 280, alignment: .leading)
            }.id(vm.messages.firstIndex(of: m))
        }
    }
}
```

Note on `.id(...)`: ids must be stable per row; enumerated offset used for user bubbles is acceptable here (append-only history). If `id` collisions appear in console, switch `ForEach` to `Array(vm.messages.enumerated()), id: \.offset` uniformly.

- [ ] **Step 3: EndpointsView**

`EndpointsView.swift` — mirrors README table, live base URL + copy:

```swift
import SwiftUI

struct EndpointsView: View {
    @ObservedObject var model: ServerModel

    private struct Row: Identifiable { let id = UUID(); let method: String; let path: String; let desc: String }
    private let inferenceRows: [Row] = [
        .init(method: "GET", path: "/health", desc: "zdrowie serwera"),
        .init(method: "GET", path: "/v1/models", desc: "lista modeli"),
        .init(method: "POST", path: "/v1/chat/completions", desc: "OpenAI shape — stream + JSON"),
        .init(method: "POST", path: "/v1/messages", desc: "Anthropic shape — stream + JSON"),
    ]
    private let mgmtRows: [Row] = [
        .init(method: "GET", path: "/x/models", desc: "lista + stany modeli"),
        .init(method: "POST", path: "/x/download", desc: "import z Hugging Face"),
        .init(method: "GET", path: "/x/download/status", desc: "postęp pobierania"),
        .init(method: "POST", path: "/x/models/load", desc: "wczytaj silnik"),
        .init(method: "POST", path: "/x/models/unload", desc: "odładuj silnik"),
        .init(method: "DELETE", path: "/x/models/{id}", desc: "usuń pliki modelu"),
    ]

    var body: some View {
        List {
            Section("Baza URL") {
                if model.running {
                    HStack {
                        Text("http://\(model.address):\(model.port)")
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button { UIPasteboard.general.string = "http://\(model.address):\(model.port)" } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                } else {
                    Text("serwer wyłączony").foregroundStyle(.secondary)
                }
            }
            Section("Inference") { rows(inferenceRows) }
            Section("Zarządzanie (/x/*)") { rows(mgmtRows) }
            Section("Kody błędów") {
                Text("429 — serwer zajęty (busy)").font(.caption)
                Text("409 — model nie załadowany").font(.caption)
                Text("404 — nieznany model / endpoint").font(.caption)
                Text("400 — złe zapytanie").font(.caption)
            }
        }
        .navigationTitle("API")
    }

    @ViewBuilder private func rows(_ rows: [Row]) -> some View {
        ForEach(rows) { r in
            HStack(alignment: .top) {
                Text(r.method).font(.system(.caption, design: .monospaced)).bold()
                    .padding(4).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    .frame(width: 60, alignment: .leading)
                VStack(alignment: .leading) {
                    Text(r.path).font(.system(.body, design: .monospaced))
                    Text(r.desc).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Wire ContentView**

Insert after the existing `NavigationLink("Modele")` line:

```swift
                NavigationLink("API") { EndpointsView(model: model) }
                NavigationLink("Czat") { ChatView(model: model) }
```

- [ ] **Step 5: Build + test verification**

Run: `xcodebuild build -project PocketServe1/PocketServe1.xcodeproj -scheme PocketServe1 -destination 'generic/platform=iOS Simulator' 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`
Run: `xcodebuild test ... (same as Task 1 Step 4)` → all green including ChatServiceTests.

- [ ] **Step 6: Commit**

`git add -A PocketServe1/PocketServe1/ PocketServe1/PocketServe1Tests/ && git commit -m "feat: add chat window and API endpoints screen to app UI"`

---

### Task 3: Docs, full verification, PR + merge

**Files:**
- Modify: `README.md` (Status bullets + endpoints section: mention in-app screens)
- Modify: `PocketServe/RUN_ON_IPHONE_PHASE2.md` (add manual chat smoke step)
- Modify: `AGENTS.md` (Current state line — Phase 2.5 chat screen merged)

**Interfaces:** none (docs only).

- [ ] **Step 1: Regression gates unchanged**

Run: `PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit` → 22/22
Run: `PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat` → 62/62
Verify `git diff main --stat -- Packages/` → EMPTY (Packages untouched rule).

- [ ] **Step 2: Update README + runbook + AGENTS status**

README: under "HTTP endpoints" add note that the app itself now hosts an in-app chat tester ("Czat") and endpoints screen ("API"); Status section: add bullet "In-app chat tester + API info screen: implemented (this PR)". Runbook: add step after step 3a: open Czat tab, pick apple-afm, send message, expect streamed reply; verify Stop mid-stream; verify /v1/messages external smoke unchanged. AGENTS.md "Current state": keep truthful.

- [ ] **Step 3: Commit docs**

`git commit -am "docs: document in-app chat and API screens in README, runbook, agents guide"`

- [ ] **Step 4: Push + PR + merge**

`git push origin feat/inapp-endpoints-chat` → create PR via GitHub MCP if enabled; otherwise the established fallback:
`git checkout main && git pull && git merge --no-ff feat/inapp-endpoints-chat -m "Merge branch 'feat/inapp-endpoints-chat' (in-app endpoints info + chat window)" && git push origin main`
Then delete the branch remote+local.

- [ ] **Step 5: Device smoke (user, manual)**

On iPhone: Start → Czat → apple-afm → message → streamed tokens visible; Stop works; mlx loaded model selectable after Wczytaj; API screen shows LAN URL and copy works. Report deviations as new backlog items (do not fix in this PR).
