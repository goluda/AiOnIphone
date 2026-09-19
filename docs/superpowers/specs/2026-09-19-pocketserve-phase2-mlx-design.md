# PocketServe Faza 2 — Silnik MLX + pobieranie modeli z Hugging Face

Data: 2026-09-19 · Status: zatwierdzona · Poprzedza: Faza 3 (Companion macOS) · Baza: Faza 1 (scalona, device-verified)

## 1. Cel

Drugi silnik推理 `mlx:<repo>` obok `apple-afm`: pobieranie open-weight modeli
w formacie MLX z Hugging Face prosto na iPhone (12 GB unified), zarządzanie nimi z
UI iOS (lista / import po ID / unload / usuwanie plików), inference przez ten sam
OpenAI-kompatybilny endpoint z Fazy 1. Model dev-testowy:
`mlx-community/Qwen3-1.7B-4bit-4bit` (~1 GB); docelowo Qwen3-8B-4bit (~4.7 GB).

Poza zakresem: GUI Companion (Faza 3), wyszukiwarka HF na macOS (Faza 3 — tu tylko
import po wpisanym ID), kwantyzacja on-device, wiele modeli załadowanych naraz.

## 2. Architektura (podejście A — 3 warstwy)

```
Packages/ModelKit        (nowy SPM, czysty Foundation — w pełni testowany na Mac)
  HFDownloader           .part + resume (HTTP Range) + SHA256, maszyna stanów
  ModelStore             Models.json catalog, memory guard, unload/delete
  DownloadCoordinator    spin downloader+store; single-download-at-a-time
Packages/OpenAICompat    (bez nowych zależności)
  ServerExtension        wstrzykiwany: DownloadAPI? + loadedModelId provider
  HTTPServer             nowe route'y /x/* -> delegacja do extension; brak
                         extension => 501
PocketServe1/ (target iOS)
  MLXEngine.swift        adapter mlx-swift -> InferenceEngine (device-only)
  ModelsViewModel.swift  UI state: katalog + pobieranie + load
  ModelsView.swift       drugi ekran aplikacji
```

Zasada: nic co zależy od `mlx-swift` nie wchodzi do pakietów SPM z testami CI;
cała logika stanu jest w ModelKit i jest testowalna bez MLX.

## 3. Komponenty

### HFDownloader (ModelKit)
- Katalog: `Documents/models/<repo-safe>/` (`/` → `_` w nazwie foldera; repo
  oryginalne trzymane w recordzie).
- Kontrakt plików: pobranie `model.safetensors.index.json` + wskazanych shardów
  + `config.json` + `tokenizer*`; brak index → pojedynczy `model.safetensors`.
- Resume: GET z `Range: bytes=<done>-` gdy serwer HF zwróci 206; inaczej od zera;
  pliki tymczasowe `<name>.part`.
- Weryfikacja: SHA256 całości plików modelu przed oznaczeniem `ready`
  (checksum z indexa jeśli jest, inaczej raportowany hash z listy HF API).
- Maszyna stanów: `idle → downloading(bytesDone, bytesTotal) → verifying →
  ready | failed(reason, retryable)`. `failed(retryable)` → `start()` wznawia
  z `.part`.

### ModelStore (ModelKit)
- Trwały katalog `Documents/Models.json`: `ModelRecord(id: "mlx:<repo>", repo,
  revision, quant (parsowany z nazwy, np. "4bit"), bytesOnDisk, downloadedAt,
  state: odwzorowanie MachineState, loaded: Bool)`.
- API: `records()`, `add(record)`, `delete(id)`, `unload(id)`, `bytesFree()`.
- Memory guard (twarde wartości początkowe, konfigurowalne init):
  - load odrzucony gdy `bytesOnDisk > 6_000_000_000`
  - `DispatchSource.makeMemoryPressureSource(.warning)` → natychmiast unload
    aktywnego modelu + banner w UI.
- Restart apki: katalog czytany z dysku; każdy record `loaded: false`; pliki
  zachowane; AFM gotowy.

### DownloadCoordinator (ModelKit)
- Single-download-at-a-time; drugi `start` → `.throwing DownloadError.inProgress`.
- Nagłaśnia `ProgressSnapshot` (Combine/currentValue) — UI subskrybuje lokalnie,
  **nie** polluje własnego HTTP.
- Po `ready` → auto `ModelStore.add`; plików `.part` nie zostawia.

### MLXEngine (target iOS, device-only)
- `id = "mlx:<repo>"`; `contextWindow = model.modelContextLength ?? 8192`
  (Global constraint speca v1: mlx default 8192, konfigurowalne przy load —
  UI nie wystawia jeszcze w tej fazie, init param).
- `load()`: `LLMModel.load(modelFolder, configuration:)` asynchronicznie;
  `unload()`: zwolnienie referencji + `MXLClearMalloc`.
- `stream(prompt:params:)`: ChatML prompt z `PromptBuilder` (Fazy 1) →
  `streamGeneration` → delta fragmenty; `temperature`/`maxTokens` →
  `GenerateParameters`. Zmiana API mlx-swift: adapter jedyny bufor, sygnatury
  weryfikowane typecheckiem iOS SDK w każdym tasku (mechanizm z Fazy 1).
- `loadedModelId` (statyczny, MainActor) źródłem prawdy dla /v1/models.

### ServerExtension (OpenAICompat)
- `struct ServerExtension { let download: DownloadAPI?; let dynamicModels: () -> [ModelInfo] }`
- `protocol DownloadAPI` (Sendable): `start(repo:revision:)`, `status()`,
  `load(id:)`, `unload(id:)`, `delete(id:)`, `records()`.
- HTTPServer: route'y `/x/*` przed busy-gate'iem (download/manager NIE są
  gate'owane 429); `extension == nil` → `501 not_implemented` (domyślne
  zachowanie w testach pakietu Fazy 1 bez zmian).
- `/v1/models`: statyczny rejestr inżynów + `dynamicModels()` (mlx gdy loaded).

## 4. Przepływy

1. **Import** (UI pole "HF repo ID"+Import ⇄ `POST /x/download`): walidacja
   `^[\w.-]+/[\w.-]+$` → fetch HF API (config/index/lista plików) → stan
   `downloading` z paskiem postępu → `.part` → `verifying` (SHA256) → `ready`.
   Serwer w tym czasie normalnie serwuje `apple-afm`.
2. **Load** (UI toggle ⇄ `POST /x/models/load`): guard → `MLXEngine.load` async
   → `loaded=true`, poprzedni `mlx` unload (1 naraz).
3. **Inference**: `model:"mlx:<repo>"` → załadowany silnik → SSE identycznie jak
   Faza 1; prompt niezaładowany/zły id → `409 model_not_ready`.
4. **Odładuj** ⇄ `POST /x/models/unload`; **Usuń pliki** ⇄ `DELETE /x/models/<id>`
   tylko gdy `!loaded` (2 akcje osobne — decyzja usera).
5. **Restart apki**: katalog z dysku, 0 modeli załadowanych, AFM gotowy.

## 5. API (endpointy `/x/*` poza OpenAI-kompatybilnymi)

| Endpoint | Sukces | Błędy |
|---|---|---|
| `GET /x/models` | 200 `[ModelRecord+]` | — |
| `POST /x/download {repo, revision?}` | 202 | 400 `invalid_request_error`, 409 `download_in_progress` |
| `GET /x/download/status` | 200 `{state, bytesDone, bytesTotal, repo?}` | — |
| `POST /x/models/load {id}` | 202 | 400 unknown, 409 `memory_pressure`, 409 `download_not_ready` |
| `POST /x/models/unload {id}` | 200 | 409 `model_not_loaded` |
| `DELETE /x/models/{id}` (ścieżka: `/x/models/` + URL-encoded repo) | 200 | 409 `model_loaded`, 404 |

Błędy w shape OpenAI: `{"error":{"message","type"}}`. Chat single-flight 429 bez zmian.

## 6. UI iOS (ekran "Modele")

- Nawigacja: z głównego ekranu "Modele" (NavigationStack).
- Nagłówek: aktualnie załadowany model (zielony badge) lub "tylko apple-afm".
- Pole `TextField` repo-id + przycisk **Import** (disabled gdy download w toku).
- Karty modeli: nazwa repo, quant, rozmiar (GB), stan badge (downloading pasek
  / ready / failed + ponów), akcje per karta: **Wczytaj**/**Odładuj**,
  **Usuń pliki** (disabled gdy loaded).
- Czerwony banner: memory pressure → model odładowany (auto).
- ModelKit→UI przez Combine `@Published`; zero HTTP self-pollingu.

## 7. Obsługa błędów (uzupełnienie §6 speca v1)

| Warstwa | Sytuacja | Zachowanie |
|---|---|---|
| Download | urwana sieć | `.part` + resume; retry z UI/`POST`; błąd ≠ kasowanie postępu |
| Download | SHA256 fail | stan `failed(retryable)`, plik usuwany, ponowne pobranie |
| Download | repo bez mlx formatu | walidacja HF API przed startem → `400`/banner "brak plików mlx" |
| Store | load > 6 GB | odrzucony + czerwony badge w UI iOS + sugestia mniejszej kwantyzacji (spec v1 §6) |
| Store | memory pressure warning | auto-unload załadowanego modelu + banner; trwający chat: stream dokańczany przez BackgroundGuard (Faza 1) |
| Server | mlx niezaładowany | `409 model_not_ready` (spec v1 §6) |
| Server | mlx-swift throw w streamie | SSE `data: {"error":...}` chunk + `[DONE]`, bez zerwania TCP (nowe: silnik może umrzeć w trakcie) |
| UI | repo-id niepoprawny format | inline walidacja, request nie wychodzi |

## 8. Testy i DoD

**ModelKit (Mac, `swift test`):**
- HFDownloader: lokalny stub HTTP (FakeHF, port 0): pełny pobór, resume po
  urwanym Range, SHA256 fail→retry, stany maszyny, retry po failed.
- ModelStore: katalog zapis/odczyt, guard 6 GB, unload, delete-only-if-not-loaded,
  restart-recovery.
- DownloadCoordinator: single-flight, kolejka odrzucona, progress snapshots.

**OpenAICompat:** routing `/x/*` z mock `DownloadAPI`; 501 bez extension;
/v1/models z dynamicModels; 409/400 shapes; testy Fazy 1 bez zmian.

**Device smoke (iPhone 18 Pro Max, checklist RUN_ON_IPHONE_PHASE2.md):**
import Qwen3-1.7B → watch pasek → load → curl `model:"mlx:mlx-community/Qwen3-1.7B-4bit-4bit"`
stream (poprawne PL, ~szybszy niż AFM?) → unload → delete plików → memory
pressure nieosiągalna-testem, ale guard unit-testowany.

**DoD:** pętla import→ready→load→inference→unload→delete działa end-to-end z UI i z
curl; /v1/models odzwierciedla stan; 0 crashy; `swift test` ModelKit +
OpenAICompat zielone; mlx-swift integracja builduje się na target iOS 26+.

## 9. Ryzyka

- `mlx-swift` API dryf (iOS vs macOS, A20 Pro): bufor = MLXEngine + typecheck w
  każdym tasku; fallback: wersja tagowana SPM pinowana.
- RAM: 8B 4bit ~4.7 GB + system ~6 GB margines — guard 6 GB twardy; Qwen3-8B
  może wymagać obniżenia contextWindow przy load (init param, UI Faza 3).
- HF rate limiting przy index fetch: backoff 2^n, max 3 próby, potem failed
  (retryable).
