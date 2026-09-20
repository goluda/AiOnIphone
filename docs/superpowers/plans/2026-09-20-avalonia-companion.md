# PocketServe Companion (Avalonia) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cross-platform (.NET 10 + Avalonia) desktop companion that connects to a PocketServe iPhone by IP, lists `/v1/models`, and chats via streaming `/v1/chat/completions`.

**Architecture:** Two projects: `PocketServe.Companion.Core` (pure BCL: `HttpClient` client, SSE frame reader, chat state) and `PocketServe.Companion.App` (thin Avalonia MVVM shell via CommunityToolkit.Mvvm). Core has zero Avalonia references and is fully unit-tested on macOS/Linux with NUnit+Shouldly.

**Tech Stack:** .NET 10 (SDK 10.0.302 verified), Avalonia 12.1.0 (`avalonia.mvvm` template), CommunityToolkit.Mvvm 8.4.2, System.Text.Json, NUnit + Shouldly, slnx solution, CPM (`Directory.Packages.props`).

Spec: `docs/superpowers/specs/2026-09-20-avalonia-companion-design.md`

## Global Constraints

- All code under `companion/` at repo root; solution `companion/PocketServe.Companion.slnx` (slnx format only).
- `TargetFramework=net10.0`, `Nullable=enable`, `TreatWarningsAsErrors=true`, file-scoped namespaces, sealed classes, 4-space indent, LF.
- CPM: all NuGet versions live in `companion/Directory.Packages.props`; `<PackageReference>` carries no `Version`.
- `PocketServe.Companion.Core` references **no** Avalonia packages (BCL only). Enforced by review.
- User-facing strings in Polish; identifiers/comments/commits in English.
- **NEVER write ChatML special-token literals (`<|`…`|>`)** in any file — refer descriptively.
- dotnet CLI for project/package operations; after every task: `dotnet build companion/PocketServe.Companion.slnx` and `dotnet test companion/PocketServe.Companion.slnx` green, then commit.
- Work on branch `feat/avalonia-companion` (already created).

---

### Task 1: Scaffold `companion/` — solution, props, projects, green build

**Files:**
- Create: `companion/PocketServe.Companion.slnx`, `companion/Directory.Build.props`, `companion/Directory.Packages.props`
- Create: `companion/src/PocketServe.Companion.Core/` (classlib, empty placeholder `Placeholder.cs`)
- Create: `companion/src/PocketServe.Companion.App/` (from `avalonia.mvvm` template, renamed namespaces)
- Create: `companion/tests/PocketServe.Companion.Core.Tests/` (nunit template + Shouldly)

**Interfaces:**
- Produces: buildable 3-project solution; namespace roots `PocketServe.Companion.Core`, `PocketServe.Companion.App`, `PocketServe.Companion.Core.Tests`.

- [ ] **Step 1: Create solution and projects via CLI**

```bash
cd companion
dotnet new sln -f slnx -n PocketServe.Companion
dotnet new classlib -n PocketServe.Companion.Core -o src/PocketServe.Companion.Core && rm src/PocketServe.Companion.Core/Class1.cs
dotnet new avalonia.mvvm -n PocketServe.Companion.App -o src/PocketServe.Companion.App
dotnet new nunit -n PocketServe.Companion.Core.Tests -o tests/PocketServe.Companion.Core.Tests
dotnet sln add src/PocketServe.Companion.Core src/PocketServe.Companion.App tests/PocketServe.Companion.Core.Tests
dotnet add src/PocketServe.Companion.App reference src/PocketServe.Companion.Core
dotnet add tests/PocketServe.Companion.Core.Tests reference src/PocketServe.Companion.Core
dotnet add tests/PocketServe.Companion.Core.Tests package Shouldly
```

- [ ] **Step 2: Add `Directory.Build.props`** (`companion/Directory.Build.props`)

```xml
<Project>
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <AnalysisLevel>latest-recommended</AnalysisLevel>
    <EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>
  </PropertyGroup>
</Project>
```

- [ ] **Step 3: Enable CPM.** Create `companion/Directory.Packages.props`:

```xml
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>
  <ItemGroup>
    <PackageVersion Include="Avalonia" Version="12.1.0" />
    <PackageVersion Include="Avalonia.Desktop" Version="12.1.0" />
    <PackageVersion Include="Avalonia.Themes.Fluent" Version="12.1.0" />
    <PackageVersion Include="Avalonia.Fonts.Inter" Version="12.1.0" />
    <PackageVersion Include="AvaloniaUI.DiagnosticsSupport" Version="2.2.3" />
    <PackageVersion Include="CommunityToolkit.Mvvm" Version="8.4.2" />
    <PackageVersion Include="NUnit" Version="4.3.2" />
    <PackageVersion Include="NUnit3TestAdapter" Version="4.6.0" />
    <PackageVersion Include="Microsoft.NET.Test.Sdk" Version="17.12.0" />
    <PackageVersion Include="Shouldly" Version="4.2.1" />
  </ItemGroup>
</Project>
```

Then strip `Version="..."` attributes from every `<PackageReference>` in `src/*/*.csproj` and `tests/*/*.csproj` (NU1008 will fail the build otherwise; per dotnet.md §4 references must be versionless under CPM). Keep the `IncludeAssets/PrivateAssets` condition on `AvaloniaUI.DiagnosticsSupport` intact. Remove `<TargetFramework>` lines from csproj files (props provide it).

- [ ] **Step 4: Fix namespaces.** Template emits `namespace Probe` — rename all `Probe` → `PocketServe.Companion.App` in App files (Program.cs, App.axaml `x:Class`/`xmlns:local`, ViewLocator.cs, ViewModels/, Views/). `RequestedThemeVariant="Dark"`.

- [ ] **Step 5: Build green.**

Run: `dotnet build companion/PocketServe.Companion.slnx` — expect 0 warnings/errors. If analyzers flag template code, fix minimally in place.

- [ ] **Step 6: Run tests (empty suite passes).** `dotnet test companion/PocketServe.Companion.slnx` → PASS.

- [ ] **Step 7: Commit** `git add companion && git commit -m "feat(companion): scaffold Avalonia companion solution (Core/App/Tests, CPM, slnx)"`

---

### Task 2: `ServerAddress` (TDD)

**Files:**
- Create: `companion/src/PocketServe.Companion.Core/ServerAddress.cs`
- Test: `companion/tests/PocketServe.Companion.Core.Tests/ServerAddressTests.cs`

**Interfaces:**
- Produces: `sealed record ServerAddress(string Host, int Port)` with `string BaseUrl { get; }` (`http://host:port`) and `static bool TryParse(string? hostInput, string? portInput, out ServerAddress? address)`. Default port 8080; accepts bare host, host:port (portInput wins), full pasted URL in hostInput.

- [ ] **Step 1: Write failing tests** — cases: bare IP + empty port → 8080; host + "8081" → 8081; `"http://192.168.68.27:8080"` in hostInput → Host=ip, Port=8080; trailing slash trimmed; empty host → false; port "0"/"70000"/"abc" → false; whitespace trimmed. Use Shouldly.

- [ ] **Step 2: Run → compile fails** (`dotnet test ... --filter ServerAddress` — "type not found").

- [ ] **Step 3: Implement** per spec sketch: strip scheme via `Uri.TryCreate(Absolute)` when it yields a Host, prefer explicit `portInput`, then URL port (if URL not default), else 8080; reject host containing space/`/`.

- [ ] **Step 4: Run → PASS.** **Step 5: Commit** `"feat(companion): ServerAddress parsing with tests"`

---

### Task 3: `SseReader` (TDD — mirror `Packages/OpenAICompat/Tests/OpenAICompatTests/SSETests.swift` semantics)

**Files:**
- Create: `companion/src/PocketServe.Companion.Core/SseReader.cs`
- Test: `companion/tests/PocketServe.Companion.Core.Tests/SseReaderTests.cs`

**Interfaces:**
- Produces: `sealed class SseReader { IEnumerable<string> Feed(ReadOnlyMemory<byte> buffer); }` — blank-line-terminated frames; multi-line `data:` joined with `\n`; leading single space after `data:` stripped; `:` comment lines ignored; `event:`/`id:` ignored; `[DONE]` payload filtered; frames split across `Feed` calls buffered (byte-accurate, multi-byte UTF-8 split safe).

- [ ] **Step 1: Write failing tests:**
  - `Feed_FullFrame_ReturnsPayload` — `"data: {\"a\":1}\n\n"` → one payload `{"a":1}`
  - `Feed_SplitAcrossFeeds_JoinsFrame` — split same frame at arbitrary byte offsets incl. inside UTF-8 3-byte char (`ż`)
  - `Feed_MultipleFramesInOneFeed_ReturnsBoth`
  - `Feed_CommentLine_Ignored` — `": keep-alive\ndata: x\n\n"` → only `"x"`
  - `Feed_MultiLineData_JoinedWithNewline` — `data: a` + `data: b` → `"a\nb"`
  - `Feed_DoneMarker_Filtered` — `data: [DONE]\n\n` → empty
  - `Feed_CRLF_Accents_Work` — CRLF line endings produce same payloads.

- [ ] **Step 2: Run → compile fails. Step 3: Implement** byte-buffered state machine (pending line bytes + current-frame data MemoryStream; on `\n`: line extract; empty line = flush frame; leading-space strip; `[DONE]` exact-match filter; CRLF: ignore trailing `\r`). Code sketch in spec §SseReader.

- [ ] **Step 4: Run → PASS. Step 5: Commit** `"feat(companion): SSE frame reader mirroring iOS SSEParser semantics"`

---

### Task 4: DTOs + `PocketServeClient` (TDD with fake `HttpMessageHandler`)

**Files:**
- Create: `companion/src/PocketServe.Companion.Core/WireTypes.cs`, `Errors.cs`, `PocketServeClient.cs`
- Test: `companion/tests/PocketServe.Companion.Core.Tests/PocketServeClientTests.cs`, `TestSupport/FakeHandler.cs`

**Interfaces:**
- Consumes: `ServerAddress`, `SseReader`.
- Produces:
  - `sealed record HealthStatus(string status)`
  - `sealed record ModelInfo(string id, [property: JsonPropertyName("context_window")] int ContextWindow)`
  - `sealed record WireMessage(string role, string content)`; `sealed record ChatRequest(string model, IReadOnlyList<WireMessage> messages, bool stream = true)`
  - `sealed class PocketServeClient(HttpClient http)`:
    - `Task<HealthStatus> GetHealthAsync(ServerAddress, CancellationToken)`
    - `Task<IReadOnlyList<ModelInfo>> GetModelsAsync(ServerAddress, CancellationToken)`
    - `IAsyncEnumerable<string> StreamChatAsync(ServerAddress, ChatRequest, CancellationToken)` — yields `choices[0].delta.content` deltas; mid-stream `data:{"error":…}` → throw `PocketServeClientException` carrying frame `message`; EOF ends.
  - `sealed class PocketServeClientException(int status, string userMessage) : Exception(userMessage)` + `static string MapError(int status, string? serverDetail)` — Polish strings: 404 "Nie znaleziono modelu lub endpointu.", 409 "Model nie jest gotowy — pobierz i załaduj go na iPhonie.", 429 "Serwer zajęty — poczekaj na koniec generowania.", 400 "Złe zapytanie.", 500 "Błąd silnika na iPhonie.", other/connect-fail (status 0) "Brak połączenia z iPhonem. Sprawdź adres i czy serwer działa."; server-provided `error.message` wins over default when present.

- [ ] **Step 1: Write failing tests** (fake handler returning canned JSON/SSE bytes):
  - `GetModelsAsync_ReturnsIdsAndContextWindow` — body `{"object":"list","data":[{"id":"apple-afm","object":"model","created":1,"context_window":4096}]}`
  - `StreamChatAsync_YieldsConcatenatedDeltas` — canned SSE with 3 chunk frames + `[DONE]`; feed via stream, assert concat == expected
  - `StreamChatAsync_MidStreamError_ThrowsWithMessage` — `data:{"error":{"message":"engine padł","type":"server_error"}}` → ex.Message == "engine padł"
  - `GetModelsAsync_409_MapsPolishMessage`, `StreamChatAsync_429_MapsPolishMessage`, non-2xx with `{"error":{"message":"X"}}` → message "X" wins
  - `HttpRequestException_WrappedAsStatus0_AndPolishConnectMessage`
- [ ] **Step 2: Run → compile fails. Step 3: Implement** — `PostAsync` helper reads body on non-2xx, parses `OpenAIErrorBody(error{message,type})`, throws mapped; `StreamChatAsync` uses `ReadAsStreamAsync` + 4096-byte loop + `SseReader`; error-frame detection via `JsonDocument` root `error` property; `[EnumeratorCancellation]` on ct.
- [ ] **Step 4: Run → PASS. Step 5: Commit** `"feat(companion): PocketServeClient with SSE streaming and error mapping"`

---

### Task 5: `ChatState` (TDD)

**Files:**
- Create: `companion/src/PocketServe.Companion.Core/ChatState.cs`
- Test: `companion/tests/PocketServe.Companion.Core.Tests/ChatStateTests.cs`

**Interfaces:**
- Produces: `enum ChatRole { User, Assistant }`; `sealed record ChatMessage(ChatRole Role, string Content)`; `sealed class ChatState { IReadOnlyList<ChatMessage> Messages; string StreamingText; bool IsStreaming; void AddUser(string); void BeginAssistantTurn(); void AppendStreaming(string); ChatMessage EndAssistantTurn(); }` — `EndAssistantTurn` moves `StreamingText` → Messages, clears streaming; empty text finalizes to empty assistant message (kept — visible proof turn happened).

- [ ] **Step 1–4:** tests: user-add; begin/append×n/end → message list `[User, Assistant(joined)]`, StreamingText empty, IsStreaming false; AppendStreaming without Begin → InvalidOperationException; EndAssistantTurn without Begin → InvalidOperationException. Then implement, run PASS.
- [ ] **Step 5: Commit** `"feat(companion): chat transcript state machine"`

---

### Task 6: Avalonia UI — MainWindow + `MainWindowViewModel` + `SettingsStore`

**Files:**
- Modify: `companion/src/PocketServe.Companion.App/ViewModels/MainViewModel.cs` (rewrite), `Views/MainWindow.axaml` (+`.axaml.cs`), `App.axaml.cs` (ctor wiring)
- Create: `companion/src/PocketServe.Companion.App/Services/SettingsStore.cs`, `Converters.cs`

**Interfaces:**
- Consumes: `PocketServeClient`, `ServerAddress`, `ChatState` from Core.
- Produces: running app window (connect bar, model picker, streaming chat, Stop, error banner).

- [ ] **Step 1: `SettingsStore`** — `sealed class SettingsStore` : `%LocalApplicationData%/PocketServe.Companion/settings.json` ↔ `record SavedSettings(string Host, int Port)`; `Load()` tolerant of missing/corrupt file (returns null); `Save(ServerAddress)`. No tests required beyond compilation (thin IO; behavior covered by compile + smoke).
- [ ] **Step 2: `MainWindowViewModel` (CommunityToolkit `[ObservableProperty]`/`[RelayCommand]`)**:
  - props: `Host`, `PortText`, `StatusText`/`IsConnected`, `Models` (`ObservableCollection<ModelInfo>`), `SelectedModel`, `Draft`, `StreamingText`, `ErrorText`, `IsStreaming`, computed `CanConnect/CanSend`.
  - `ConnectAsync`: `ServerAddress.TryParse` → invalid → ErrorText; else `GetHealthAsync`+`GetModelsAsync` (each in try/catch → `ex is PocketServeClientException or OperationCanceledException` → ErrorText=ex.UserMessage, disconnect state); on success refresh picker, keep prior selection by id, save settings.
  - `SendAsync`: guard `IsStreaming`/no selection; `AddUser`; `BeginAssistantTurn`; `await foreach (var delta in client.StreamChatAsync(...))` → `Dispatcher.UIThread.Post(AppendStreaming)`; on normal end `EndAssistantTurn` → append bubble to `Messages` (`ObservableCollection<ChatMessage>`); `catch OperationCanceledException` → finalize partial silently; `catch PocketServeClientException` → ErrorText + finalize partial bubble with what arrived.
  - `Stop`: `_cts.Cancel()`. `RefreshModels`: GET models, preserve selection.
  - ctor `MainWindowViewModel(PocketServeClient client, SettingsStore store)` seeds Host/Port from store.
- [ ] **Step 3: `MainWindow.axaml`** — DockPanel per spec §4: connect bar (host TextBox, port TextBox width 60, `●` ellipse green/gray, Connect/Disconnect button), model bar (ComboBox `ItemsSource="{Binding Models}"` `DisplayMemberBinding="{Binding id}"`, Refresh button, context_window hint TextBlock on SelectedModel), `ScrollViewer`+`ItemsControl` bubbles — DataTemplate: `Border` background via `ChatRoleToBrushConverter` (user: accent dark, assistant: surface), alignment via `ChatRoleToAlignmentConverter`, `TextWrapping=Wrap`; streaming bubble = separate Border bound to `StreamingText` + suffix "▌", `IsVisible="{Binding IsStreaming}"`; auto-scroll: code-behind `PropertyChanged` on `StreamingText`/`Messages.Count` → `ScrollToEnd`. Bottom: `TextBlock` error banner (`IsVisible` when ErrorText non-empty, warning foreground) + `TextBox AcceptsReturn=True` (Enter=Send via KeyDown code-behind, Shift+Enter newline) + Wyślij/Stop button toggle.
- [ ] **Step 4: `App.axaml.cs`** — construct `HttpClient` (Timeout = infinite: `Timeout = System.Threading.Timeout.InfiniteTimeSpan`, connect timeout enforced per-request via CTS 5s on health), `SettingsStore`, `MainViewModel(client, store)` → MainWindow.DataContext. Delete template `Models/` empty folder + `Greeting` remnants.
- [ ] **Step 5: Build green** (`dotnet build`, warnings fixed) **and tests still pass**.
- [ ] **Step 6: Smoke run** `dotnet run --project companion/src/PocketServe.Companion.App` — window opens; connect to `192.168.68.27:8080` (iPhone PocketServe running per runbook) → models listed; send → tokens stream. If device unavailable: connect attempt shows Polish connect error, UI responsive → acceptable for CI-less check.
- [ ] **Step 7: Commit** `"feat(companion): Avalonia chat UI wired to live client"`

---

### Task 7: Docs — Phase 3 re-point + runbook + PR

**Files:**
- Modify: `docs/ROADMAP.md` (Phase 3: macOS SwiftUI Companion → cross-platform .NET Avalonia Companion; acceptance: IP entry, model picker from `/v1/models`, streaming chat, 429/409 UX in Polish; drop Bonjour zero-config requirement), `README.md` (companion section pointer), `AGENTS.md` (Current state bullet + layer note: `companion/` .NET code = Core/App split, English code, Polish UI strings).
- Create: `companion/RUN_COMPANION.md` (build/run, connect steps, troubleshooting: wrong IP → connect error message, server busy 429, model not ready 409).

- [ ] **Step 1:** Write docs; re-read ROADMAP/AGENTS before editing (external-edit watch).
- [ ] **Step 2:** `dotnet build` + `dotnet test` final proof.
- [ ] **Step 3:** Commit `"docs(companion): Phase 3 Avalonia companion roadmap, runbook"`; push branch; create PR via GitHub MCP (`create_pull_request`, base `main`); merge locally `git merge --no-ff` + `git push origin main` (merge-workaround memo), delete branch.
