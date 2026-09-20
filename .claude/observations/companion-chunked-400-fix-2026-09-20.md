# Companion chat 400 invalid_request_error — chunked body (2026-09-20)

## Symptom
Companion (Avalonia) connects OK (`/health`, `/v1/models`), but every `POST /v1/chat/completions` returns `invalid_request_error`. First device smoke of Phase 3 failed here.

## Root cause (proven, not guessed)
- .NET `HttpClient` + `JsonContent` sends **`Transfer-Encoding: chunked`** and **no `Content-Length`** (verified with a raw TCP capture probe — see method below).
- iOS `RequestParser.parse` computes `need = Int(headers["content-length"] ?? "0")` → treats the body as empty → `JSONDecoder` throws → 400 `invalid_request_error`.
- Banner showed the raw type token because `HTTPServer.sendError` maps `message` = error type (that is F2, separate).

## Fix (client-side, PR #4)
`PocketServeClient.StreamChatAsync`: serialize explicitly and use `StringContent` (forces `Content-Length`):
`var jsonBody = new StringContent(JsonSerializer.Serialize(request, JsonOptions), Encoding.UTF8, "application/json");`
Server-side chunked decoding stays open as **F4** (KNOWN_ISSUES): decode chunked or return 411.

## Regression test trap (IMPORTANT)
`FakeHandler` must capture `request.Content?.Headers.ContentLength` **BEFORE** `ReadAsStringAsync`. `JsonContent` populates `Headers.ContentLength` lazily only after the body is read → capturing after the read yields a false green test. Recorded in `RecordedRequest(Uri, Body, ContentLength)`.

## Proof / repro recipes (reusable)
- Raw-wire proof: tiny probe csproj with `TcpListener` printing request headers — shows `Transfer-Encoding: chunked` for `JsonContent`, `Content-Length: 81` for `StringContent`.
- Live repro against iPhone: `curl -H 'Transfer-Encoding: chunked' -d '{...}' http://192.168.68.27:8080/v1/chat/completions` → 400; same body via `StringContent` → 200 + SSE.
- File-based `dotnet run x.cs` throws `JsonSerializerIsReflectionDisabled` on this machine — always use a real csproj for probes.

## Result
Core 42/42 green (new test: `StreamChatAsync_PostsContentLength_ServersRejectChunked`). Live device smoke passed: streaming `apple-afm` reply "I am a foundation model created by Apple…". Merged to `main` as `ed828ef` (PR #4); ROADMAP Phase 3 → ✅.
