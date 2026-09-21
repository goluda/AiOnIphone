# /v1/messages endpoint implemented (2026-09-20)

- Branch `feat/messages-endpoint` → PR #1 (goluda/AiOnIphone). Commits: dee4ff9 (DTOs+encoder), b285d14 (route), 88968b3 (runbook 3a).
- Shared pipeline: `HTTPServer.runInference(_:conn:wire:)` + `enum WireFormat`; `sendError` wire-aware (429→rate_limit_error, 404→not_found_error, 400/409→invalid_request_error, mid-stream→`event: error`, no [DONE] on anthropic).
- OpenAICompat now 62/62; ModelKit 22/22; simulator BUILD SUCCEEDED.
- Swift traps hit during TDD (repeat here for future):
  - `try` cannot appear on the right side of a `+` concat → bind `let json = try ...` first.
  - `XCTAssertEqual` on `[Any]` fails ('Any' cannot conform to Equatable) → use `.isEmpty`.
  - JSONSerialization gives `NSNull` for JSON null → assert `value as? String == nil`, not `XCTAssertNil(dict[key])`.
  - Optional `String?` stored property is dropped by synthesized encoder when nil → custom `encode(to:)` with `encodeNil` to keep `stop_sequence:null` on the wire.
- Local `gh` binary is broken (`bad CPU type`) → use GitHub MCP tools for PR ops.
- Device smoke 3a (manual): phone awake, re-scan Bonjour `_oai._tcp.`.
