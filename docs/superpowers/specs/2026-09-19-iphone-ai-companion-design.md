# PocketServe — iPhone AI Companion: Design Spec

**Data:** 2026-09-19
**Status:** Zatwierdzona przez użytkownika (do implementacji)
**Platformy:** iOS 27 (iPhone 18 Pro Max) + macOS (Apple Silicon)

## 1. Cel

Aplikacja iPhone uruchamiająca lokalny serwer HTTP zgodny z OpenAI API, serwująca
modelem AI hostowanym na iPhonie, konsumowana przez dedykowaną aplikację
"Companion" na MacBooku przez Wi-Fi LAN. Osobisty, prywatny, zero-cost inference.

## 2. Kontekst sprzętowy (iPhone 18 Pro Max, wrzesień 2026)

- **A20 Pro** (2 nm): 6-rdzeniowy CPU (2P+4E), 7-rdzeniowy GPU (+40% vs A19 Pro),
  32-rdzeniowy Neural Engine (2× vs A19 Pro), +50% przepustowości pamięci
- **12 GB** pamięci unified → 4-bit MLX do ~8B parametrów (~5 GB) mieści się bezpiecznie
- **Vapor chamber** → utrzymanie sustained performance przy ciągłym inferowaniu
- **iOS 27** z Apple Intelligence; Foundation Models framework udostępnia on-device
  model Apple (AFM 3B) aplikacjom trzecim
- Szacowana wydajność: Qwen3-8B-4bit ~15–25 tok/s (GPU); AFM 3B ~40+ tok/s

## 3. Kluczowe decyzje projektowe

| # | Decyzja | Wybór |
|---|---------|-------|
| 1 | Silnik | **Hybryda**: MLX Swift (open-weight) + Apple AFM przez Foundation Models |
| 2 | Konsumenci | Endpoint OpenAI-kompatybilny **oraz** własna apka macOS |
| 3 | Cykl życia serwera | **On-demand**: serwer żyje gdy apka iOS na froncie |
| 4 | Zakres v1 | **Minimum**: streaming chat, lokalna historia, wybór modelu, kontrola kontekstu |
| 5 | Realizacja | **Opcja 1**: własny kod Swift od zera (bez forka SharpAI/SwiftLM) |
| 6 | Auth | **Brak** — apka testowa, LAN-only, plain HTTP |
| 7 | Modele | Wybór Apple AFM lub wyszukiwanie + pobieranie mlx-format modeli z Hugging Face |

## 4. Architektura

```
┌─ iPhone (PocketServe, foreground-only) ─────────────────────┐
│  NWListener :8080 (HTTP/1.1, LAN, bez TLS)                 │
│   ├─ GET  /v1/models                                        │
│   ├─ POST /v1/chat/completions  (stream SSE lub JSON)     │
│   ├─ POST /x/download {repo, revision}                    │
│   └─ GET  /x/download/status                              │
│  ModelRouter: "apple-afm" → FoundationModels              │
│               "mlx:<repo>" → mlx-swift (załadowany)        │
│  Bonjour: _oai._tcp. → iphone.local                       │
└──────────────▲──────────────────────────────────────────────┘
               │ Wi-Fi LAN, bez auth
┌─ MacBook (Companion, SwiftUI) ──────────────────────────────┐
│  NWBrowser discovery → APIClient (SSE) → ChatStore (GRDB) │
│  Panel Modele: Apple AFM | HF search (filtr "mlx")         │
│  Suwak max_context · picker modelu · dioda statusu         │
└─────────────────────────────────────────────────────────────┘
```

- Jeden projekt Xcode, 2 targety (iOS app + macOS app) + shared SPM pakiet
  `OpenAICompat` (DTO, SSE, truncation kontekstu) — testowany jednostkowo.
- AFM nie jest pobierany: dostępny przez framework systemowy; w `/v1/models`
  raportowany jako `apple-afm`.
- Decyzja AFM-vs-MLX należy **wyłącznie do klienta** w polu `model` requesta.

### Struktura modułów (każdy = jedna odpowiedzialność)

**`OpenAICompat` (SPM, czysty Swift, bez UI):**
- `ChatCompletionRequest/Response` DTO — subset OpenAI: `model`, `messages`,
  `stream`, `temperature`, `max_tokens`; odpowiedź: `choices[].delta.content`,
  `usage.{prompt,completion}_tokens`; błędy w OpenAI error schema
- `SSEEncoder` / `SSEParser` — `data: {...}\n\n` + `data: [DONE]`
- `ContextTruncator` — przycinanie `messages` do budżetu tokenów
- `TokenCounter` — aproksymacja (len/4) vs tokenizacja mlx po stronie serwera

**`PocketServe` (iOS):**
- `HTTPServer` — NWListener, parsowanie HTTP/1.1, routing, keep-alive, single-flight
- `ModelRouter` — mapuje `model` → `InferenceEngine`
- `AFMEngine` / `MLXEngine` — adaptery za wspólnym protokołem
  `InferenceEngine { stream(prompt, params) -> AsyncThrowingStream<Token> }`
- `ModelStore` — katalog pobranych mlx modeli, load/unload z memory guardem
- `HFDownloader` — resumable pobieranie z HF (plik `.part`, checksum, status)
- `ServerUI` — stan serwera, lista modeli, progress pobierania, ostrzeżenia RAM

**`Companion` (macOS):**
- `Discovery` — NWBrowser `_oai._tcp.`, resolve → base URL
- `APIClient` — streaming URLSession + reconnection
- `ChatStore` — GRDB/SQLite: konwersacje, wiadomości, ustawienia
- `ChatView` / `ModelPanel` / `ContextSlider` — SwiftUI

## 5. Data flow (chat round-trip)

1. Użytkownik pisze → Companion przycina historię wg suwaka `max_context`
2. `POST /v1/chat/completions {model, messages, stream:true, temperature, max_tokens}`
3. PocketServe: `apple-afm` → `LanguageModel.default`; `mlx:*` → załadowany model
4. Każdy token → SSE chunk `{choices:[{delta:{content:"..."}}]}`
5. Po `data: [DONE]` → `usage` zapisywane do SQLite, licznik kontekstu w UI się aktualizuje

### Kontrola okna kontekstu

- Suwak na macOS: liczba tokenów wejściowych (zakres: 1k → limit modelu)
- Serwer clampuje do limitu modelu: AFM = limit frameworka (odczyt z capabilities);
  mlx = `modelContextLength` konfigurowalne przy load (domyślnie 8192)
- UI live: "okno 8192 · użycie 2.1k" (z `usage.prompt_tokens`)

### Pobieranie modeli (HF)

- Wyszukiwanie: **macOS odpytuje HF API bezpośrednio** (filtry: biblioteka `mlx`,
  sort po downloads; wynik: repo id, rozmiar plików, quantization)
- iPhone dostaje tylko `POST /x/download {repo, revision}`; walidacja:
  rozmiar vs dostępne RAM (guard: wolne ≥ 1.5× pliku)
- Postęp: `GET /x/download/status` → `{state, bytesDone, bytesTotal}`; client polluje 1 s
- Pobieranie można też odpalić ręcznie w apce iOS (ten sam moduł)

## 6. Obsługa błędów

| Warstwa | Błąd | Zachowanie |
|---|---|---|
| Client | iPhone offline / brak discovery | dioda czerwona, auto-retry 5 s, historia offline OK |
| Client | puste wyniki HF search | komunikat "brak mlx-format", zachęta do zmiany frazy |
| HTTP | malformowany JSON | `400 invalid_request_error` (OpenAI schema) |
| HTTP | nieznany `model` | `404 model_not_found` |
| HTTP | drugi równoległy request | `429 server_busy` (single-flight) |
| Server | model nie załadowany / download w toku | `409 model_not_ready {status}` |
| Server | memory pressure przy load MLX | odrzucone + czerwony badge w UI iOS + sugestia mniejszego kwantyzacji |
| Server | apka iOS traci foreground w toku | SSE `event: error` + klient: "iPhone uśpił serwer" |
| Download | urwanie sieci | resume z `.part` + checksum SHA256 przed load |

## 7. Testy

- **TDD na `OpenAICompat`** (rdzeń): DTO round-trip, SSE encode/parse edge cases
  (split chunki, UTF-8 multi-byte na granicy), `ContextTruncator` (pilnuje budżetu)
- Integracja HTTP: `HTTPServer` uruchamiany w testach na macOS (ten sam kod
  `NWListener`) → testy na `127.0.0.1`; inference za mockiem `InferenceEngine`
- Manual checklist na urządzeniu: AFM smoke · load Qwen3-8B-4bit · pull kontekstu
  do sufitu · airplane mode · 10-min streaming pod sustained GPU (termal)

## 8. Poza zakresem v1 (kandydaci na v2)

Voice (STT/TTS), trwała pamięć/persona (wektor DB), background server,
TLS/ uwierzytelnianie, many-requests paralelizm, CarPlay, tool-calling /
function-calling, wiele okien czatu simultanicznie na klientach.

## 9. Znane ograniczenia i ryzyka

- **Bez auth, plain HTTP** — akceptowalne tylko dla zaufanej sieci LAN;
  w otwartej sieci ktokolwiek może używać serwera (świadoma decyzja, v1 test)
- iOS twardo ogranicza background: zamknięcie apki = koniec serwera (feature, nie bug)
- AFM przez Foundation Models ma własne limity (długość odpowiedzi, availability
  regionalna/językowa PL może być patchowa) — pierwszy smoke test zweryfikuje
- 12 GB RAM: kwantyzacja 8B/4-bit to sufit; większe modele = v2 (SSD streaming)
- `mlx-swift` na iOS wymaga A16+ — A20 Pro OK, ale API może się różnić od macOS
