# PocketServe — kontekst projektu dla agentów

iOS app serwujący OpenAI-kompatybilny endpoint (LAN) z Apple AFM + modele MLX; klient: "Companion" na macOS (Faza 3).

## BACKLOG (prośby użytkownika — do zrealizowania w przyszłości)
- [ ] **Blokada wygaszania ekranu**: przełącznik „ekran zawsze aktywny gdy serwer działa" (`UIApplication.shared.isIdleTimerDisabled`, reset przy stop/background). Bez tego wygaszenie telefonu wiesza serwer (potwierdzone na urządzeniu 2026-09-20).
- [ ] **Serwowanie modeli Apple jako pełnoprawny wybór**: widoczna karta/selektor „Apple Intelligence (apple-afm)" w UI MODELE + gwarancja serwowania (status dostępności AFM, onboarding gdy wyłączony w ustawieniach). Dziś apple-afm działa implicit.
- [ ] F1: `<|im_start|>` leak — Qwen3 chain-of-thought wylewa się do `content` i SSE; wyciąć span think w MLXEngine lub wyłączyć thinking w szablonie (potwierdzone live 2026-09-20).
- [ ] F2: leak enuma w JSON — `"invalidRequest(\"...\")"` zamiast czystego komunikatu; opis `ServerAPIError` z associated values.

## Konwencje
- Źródła appki: **bezpośrednio `PocketServe1/PocketServe1/`** (PBXFileSystemSynchronizedRootGroup — kopiowanie/mirror NIE jest potrzebne; stary mirror `PocketServe/PocketServe/` usunięty w ca257d6).
- Runbook: `PocketServe/RUN_ON_IPHONE_PHASE2.md` (device smoke §4).
- Architektura A: `Packages/ModelKit` (bez UIKit/MLX), `Packages/OpenAICompat` (bez ModelKit — wstrzykiwany `ServerExtension`), MLXEngine tylko w targetcie iOS.
- Ids: `mlx:<repo>` end-to-end; `apple-afm`; placeholder `mlx:none` nielista/nierutowalny.

## Środowisko (quirks)
- `/usr/local/bin/swift` i `rg` zepsute → zawsze `PATH=/usr/bin:$PATH swift ...`.
- Testy: `PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit` (22/22), `.../OpenAICompat` (50/50).
- Build: `xcodebuild -project PocketServe1/PocketServe1.xcodeproj -scheme PocketServe1 -destination 'generic/platform=iOS Simulator' build`.
-mlx pin: mlx-swift-examples 2.29.1 (MLXLLM+MLXLMCommon), mlx-swift 0.29.1; `chunk` inkrementalny; contextWindow=8192 (konserwatywna stała).
- Device: iPhone 18 Pro Max `192.168.68.27:8080`, Bonjour `_oai._tcp.`; debug Xcode (GPU capture/validation) powoduje globalne lag — trzymać wyłączone w scheme.
