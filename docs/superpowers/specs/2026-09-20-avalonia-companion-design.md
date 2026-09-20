# Design: PocketServe Companion — cross-platform .NET (Avalonia) chat client

Date: 2026-09-20
Status: draft (approaches approved verbally "ok"; decisions recorded while user away)
Supersedes: Phase 3 "macOS Companion (SwiftUI)" from ROADMAP.md and the companion sections of `2026-09-19-iphone-ai-companion-design.md`.

## Goal

Desktop companion app in **.NET 10 + Avalonia UI** (Windows/macOS/Linux) that connects to a PocketServe iPhone over LAN:

1. User types the iPhone's IP (and optionally port, default 8080) and connects.
2. App fetches `GET /v1/models` and shows the models the phone currently offers.
3. User picks a model and chats via `POST /v1/chat/completions` with live token streaming.

This replaces the original macOS-only SwiftUI Companion idea — same server contract, cross-platform client.

## Non-goals (YAGNI)

- **No `/x/*` management actions from the companion.** Model download/load/unload stays on the iPhone (Models + API screens). The companion only *reads* status (`/health`, `/v1/models`).
- No Bonjour/mDNS auto-discovery — explicit IP entry per user request ("użytkownik powinien mieć możliwość podania ip").
- No auth (server is auth-less on LAN by design; revisit in Phase 4b together with server-side pairing).
- No chat history persistence, no temperature/max-tokens controls, no `/v1/messages` (Anthropic) client, no Markdown rendering.
- No mobile/Browser render modes — desktop only (`avalonia.mvvm` classic desktop).

## Decisions (autonomous, user away — recorded for review)

- **Scope: chat-only MVP** (approved by user "ok"). Management = non-goal.
- **Architecture: two projects + tests** (option A): `PocketServe.Companion.Core` holds all testable logic (HTTP client, SSE reader, chat state); `PocketServe.Companion.App` is thin Avalonia UI. Mirrors the iOS layer split (ModelKit/OpenAICompat vs app target): UI never contains networking logic, logic never references UI.
- **In-repo** at `companion/` (option C rejected: single tracker, spec/runbooks stay together; iOS and companion share the wire contract and it should change atomically).
- **Streaming: manual SSE line reader** over `HttpContent.ReadAsStreamAsync` — `SseReader` in Core, faithful port of `SSEParser.swift` semantics (blank-line frames, `data:` join, `:` comments ignored, `[DONE]` terminator, split-across-buffer safe). Its unit tests mirror `SSETests.swift` cases.
- **Cancellation**: Stop button cancels the `CancellationTokenSource` feeding the stream; a cancelled turn finalizes the partial assistant bubble (same UX as in-app Czat).
- **Remember last address** in `%LocalApplicationData%/PocketServe.Companion/settings.json` — convenience only, no cloud, no sync.- **MVVM plumbing: `CommunityToolkit.Mvvm`** (`ObservableObject`/`[ObservableProperty]`/`RelayCommand`) — Avalonia-friendly, no ReactiveUI complexity.- **JSON DTOs in Core** duplicate the server wire shapes (OpenAI spec is stable, cross-language; no shared source with Swift packages — deliberate, layers are language-native).

## Architecture

```
companion/
  PocketServe.Companion.slnx
  Directory.Build.props                       # net10.0, nullable, warnings-as-errors, analyzers
  Directory.Packages.props                    # CPM: Avalonia*, NUnit, Shouldly, Microsoft.Extensions.*
  src/
    PocketServe.Companion.Core/             # NO Avalonia reference — pure logic, Mac/Linux/CI testable
      PocketServeClient.cs                  # HttpClient: GetHealthAsync, GetModelsAsync, StreamChatAsync
      SseReader.cs                          # buffer-splitting SSE frame reader
      ChatState.cs                        # conversation transcript model + turn reducer
      ServerAddress.cs                    # normalize "192.168.68.27" / "http://…:8080" → base URL
      Errors.cs                           # PocketServeClientException with userMessage (PL strings)
    PocketServe.Companion.App/              # Avalonia MVVM shell
      Program.cs / App.axaml / MainWindow.axaml
      ViewModels/MainWindowViewModel.cs   # connect flow, model picker, send/stop, error banner
      Services/SettingsStore.cs           # last-address persistence
  tests/
    PocketServe.Companion.Core.Tests/      # NUnit + Shouldly; SseReaderTests mirror SSETests.swift
```

Dependency rule (enforced by review): `App → Core`; `Core →` BCL only (`System.Net.Http`, `System.Text.Json`). Nothing in Core imports Avalonia.

## Server contract consumed (already live on iOS main)

| Endpoint | Use in companion | Notes |
|---|---|---|
| `GET /health` | connect probe (● status) | `{status:"ok"}` |
| `GET /v1/models` | model picker | ids: `apple-afm`, `mlx:<repo>`; `context_window` shown in tooltip |
| `POST /v1/chat/completions` | chat, `stream:true` always | SSE `data:{chunk}` → `choices[0].delta.content`; `data: [DONE]` ends |
| Error frames / statuses | error banner | 409 `model_not_ready`, 429 `server_busy`, 404 unknown model/endpoint, 400 malformed, 500 engine |

Mid-stream `data:{"error":{...}}` frames must surface their `message` (do not render as assistant text).

## Components

### 1. `SseReader` (Core)

```csharp
public sealed class SseReader
{
    // Feed raw bytes/text as they arrive; returns completed data-payloads.
    // - frames end on blank line; multi-line data: lines joined with \n
    // - ":" comment lines ignored; "event:"/"id:" ignored
    // - "[DONE]" payload filtered out (caller ends turn on stream EOF)
    // - safe when a frame splits across Feed calls (buffer retained)
    public IEnumerable<string> Feed(ReadOnlyMemory<byte> buffer);
}
```

UTF-8 decoding holds back a trailing incomplete multi-byte sequence between feeds (parity with `SSETests` multi-byte split case).

### 2. `PocketServeClient` (Core)

```csharp
public sealed class PocketServeClient(HttpClient http)
{
    public Task<HealthStatus> GetHealthAsync(ServerAddress addr, CancellationToken ct);
    public Task<IReadOnlyList<ModelInfo>> GetModelsAsync(ServerAddress addr, CancellationToken ct);
    public IAsyncEnumerable<string> StreamChatAsync(
        ServerAddress addr, ChatRequest req, CancellationToken ct); // yields assistant text deltas
}
```

- `ChatRequest`/`ModelInfo`/`ChatCompletionChunk` are `sealed record`s with `[JsonPropertyName]` snake_case, matching `Models.swift` DTOs.
- Non-2xx: throw `PocketServeClientException(status, userMessage)`; userMessage Polish, mapped in one place (404→"Nie znaleziony model/endpoint", 409→"Model nie jest gotowy…", 429→"Serwer zajęty…", connect-refused→"Brak połączenia z iPhonem…").
- HTTP version 1.1, no special handler config needed; timeouts: connect 5 s, streaming **no** per-read timeout (long generations) but honor `ct`.

### 3. `MainWindowViewModel` (App)

States: `Disconnected → Connecting → Connected(models)`; error sets `ErrorText` + falls back gracefully (keeps transcript).
- `ConnectCommand` → GET /health + GET /v1/models; populates `Models`, selects first (prefer previously selected id if still offered).
- `SendCommand` → append user bubble, start `StreamChatAsync`; tokens accumulate into `StreamingText` (live bubble with "▌"), on `[DONE]`/EOF append assistant bubble.
- `StopCommand` → cancel CTS, finalize partial bubble.
- `RefreshModelsCommand` → re-GET models.
- `IsStreaming` gates Send↔Stop, disables model picker mid-turn.
- UI-thread marshaling via Avalonia `Dispatcher.UIThread.Post` inside the VM's stream loop (no framework deps in Core: Core stays thread-agnostic, enumeration happens in App VM).

### 4. MainWindow layout (axaml)

```
DockPanel
 ├(Top)    Connect bar: [TextBox host][TextBox port][● status][Połącz/Rozłącz]
 ├(Top)    Model bar: [ComboBox models][Odśwież]  + context_window hint
 ├(*)      ScrollViewer → ItemsControl bubbles (user right / assistant left, streaming bubble)
 └(Bottom) Error banner (collapsible) + [TextBox multiline][Wyślij/Stop]
```

Keyboard: `Enter` sends, `Shift+Enter` newline. Theme: Fluent dark default, no custom styling beyond bubble padding.

## Testing (NUnit + Shouldly, on macOS/Linux CI-capable, no UI)

`SseReaderTests` (mirror of SSETests.swift):
- single frame / split across feeds / multiple frames in one feed
- `:` comment ignored; multi-line `data:` joined
- multi-byte char split across feed boundary
- `[DONE]` filtered

`PocketServeClientTests` (fake `HttpMessageHandler`):
- GetModelsAsync parses list + snake_case `context_window`
- StreamChatAsync yields concatenated deltas == full text; stops at EOF
- mid-stream `data:{"error":…}` throws with the frame's `message`
- 409/429/404 status → mapped `userMessage`
- cancellation mid-stream → `OperationCanceledException` (VM turns it into clean finalize)

`ServerAddressTests`: bare IP, IP:port, scheme-prefixed, whitespace trimmed, invalid → parse error.

Gate: `dotnet build` + `dotnet test companion/PocketServe.Companion.slnx` green before PR.

## Acceptance criteria

1. Type iPhone IP → status ● turns green, model picker lists `apple-afm` and loaded `mlx:*`.
2. Send message → assistant tokens appear incrementally (no batching until end).
3. Stop mid-stream → partial text kept, ready for next message.
4. iPhone asleep/off → error banner Polish message, app stays alive; re-connect recovers.
5. 409 path: pick id not loaded (type into picker if free-text kept, or via re-refresh race) → banner "Model nie jest gotowy…" with the server's guidance.
6. Runs on macOS today; no platform-specific code (verified by build for `net10.0` without TFM conditionals).

## Risks / open questions

- **ATS/TLS:** plain `http://` — fine on desktop .NET (no ATS). LAN-only assumption inherited from server.
- **Picker free-text:** allow editing unknown ids or lock to fetched list? → MVP: locked to list; spec note: typing raw ids may help `mlx:none` testing — deferred.
- **Avalonia template version drift:** pin what `dotnet new avalonia.mvvm` emits on SDK 10.0.302; CPM captures exact versions.
- Companion UI language: Polish labels (user-facing), code/docs English — consistent with iOS app.

## Rollout plan (for writing-plans)

1. Scaffold `companion/` (slnx, Directory.Build.props, CPM, `avalonia.mvvm` into App, xunit→NUnit swap, Core lib, tests proj). Build green empty.
2. TDD: `ServerAddress` → `SseReader` → `PocketServeClient` → `ChatState` (each: red → green).
3. UI: MainWindow axaml + MainWindowViewModel wiring against fake client (design-time) then real.
4. Docs: update ROADMAP Phase 3 (macOS SwiftUI → Avalonia), README pointer, runbook `companion/RUN_COMPANION.md`.
5. PR → squash-merge to main after `dotnet build`/`dotnet test` proof.
