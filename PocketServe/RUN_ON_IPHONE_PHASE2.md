# PocketServe Phase 2 — RUN on iPhone: mlx-swift (checklist dla człowieka)

Dotyczy: `MLXEngine.swift` (adapter `mlx-swift-examples` / `MLXLMCommon.ModelContainer`).
App target: `PocketServe1/PocketServe1.xcodeproj` → target `PocketServe1`.

## 0. Stan headless (zrobione w repo — NIE rób ponownie, tylko zweryfikuj)
Zależność **mlx-swift-examples** została wpięta headless do `project.pbxproj`
(`XCRemoteSwiftPackageReference` + produkty **MLXLLM** + **MLXLMCommon** w targetie `PocketServe1`).

Pin zapisany w pbxproj (requirement `upToNextMajorVersion`):

| Pakiet | Wymaganie | Rozwiązano na | SHA checkout |
|---|---|---|---|
| mlx-swift-examples (ident: `mlx-libraries`) | up to next major od **2.29.1** | **2.29.1** | `9bff95ca5f0b9e8c021acc4d71a2bbe4a7441631` |
| mlx-swift (transytywny, nie dodawać ręcznie!) | `.upToNextMinor(from: "0.29.1")` narzucony przez mlx-libraries | **0.29.1** | `072b684acaae80b6a463abab3a103732f33774bf` |

> Uwaga: plan zakładał mlx-swift 0.31.6 — w rzeczywistości mlx-libraries@2.29.1 wymusza
> `upToNextMinor(0.29.1)`. Zostaw jak jest. **Nie dodawaj osobno pakietu mlx-swift** —
> i tak nie da się (konflikt wymagań), a `MLXLLM` wnosi go transitwnie.

**Weryfikacja w GUI (bez resolve):** otwórz `PocketServe1.xcodeproj` → projekt → zakładka
**Package Dependencies**: powinny widnieć `mlx-swift-examples` (2.29.1) obok lokalnego `OpenAICompat`.
Target `PocketServe1` → **Frameworks, Libraries, and Embedded Content** / *packageProductDependencies*:
`MLXLLM` + `MLXLMCommon`. Jeśli Xcode zaproponuje "Resolve" — kliknij **Resolve** (pobierze
prebuildowany binary xcframework mlx do DerivedData; brak wpływu na pbxproj poza ewentualnym `Package.resolved`).

## 1. Fallback GUI — jeśli pbxproj headless by się rozjedzie (dokładne klikania)
1. Xcode → projekt `PocketServe1` → target niepotrzebny na tym ekranie: **Project** (nie Targets) → zakładka **Package Dependencies**
2. Kliknij **`+`** (dodaj zależność pakietu)
3. W prawym dolnym polu URL wpisz: `https://github.com/ml-explore/mlx-swift-examples.git` → **Return / Add to Project** (poczekaj na sklonowanie i wyszukanie wersji)
4. **Dependency Rule**: wybierz **Up to Next Major Version** i wpisz dokładnie `2.29.1` (UI pokaże najnowszy tag — jeśli będzie nowszy niż 2.29.1 i tak zostaw 2.29.1 = pin z tabeli wyżej)
5. **Add to Project** → w oknie "Choose Package Products for mlx-libraries": oba produkty (`MLXLLM`, `MLXLMCommon`) → **Add to target: PocketServe1** → **Finish**
6. **File → Packages → Resolve Package Versions** (tylko gdy pakiety czerwone)
7. Commit powstałego `pbxproj` + `Package.resolved`

## 2. Build / smoke na symulatorze (arm64 sim wspierany)
```bash
xcodebuild -project PocketServe1/PocketServe1.xcodeproj -scheme PocketServe1 \
  -destination 'generic/platform=iOS Simulator' build
```
Oczekiwane: `** BUILD SUCCEEDED **` (pierwszy build ściąga binary xcframework mlx — kilka minut).

## 3. Uruchomienie MLX na urządzeniu (Task 7)
- Wymagane: iPhone z Apple Silicon (arm64) — deployment iOS 27 (pakiet: iOS 16+).
- `MLXEngine.loadRecord(_:revision:folder:)` ładuje **wyłącznie z lokalnego katalogu**
  (`ModelConfiguration(directory:)` — zero pobierania z HF; folder dostarcza ModelKit/DownloadCoordinator).
- `contextWindow` = 8192 (stała — 2.29.1 nie ekspozuje `modelContextLength`; potwierdzić realne okno na urządzeniu).
- Generowanie na silniku: `mlx-swift` Metal — pierwszy token wolny (prefill), potem strumień SSE jak AFM.

## 4. Smoke UI + /x/* (Task 7 — po wbudowaniu wersji z Task 6)
Na iPhonie: Start serwera → **Modele** (NavigationLink) → kolejno:
1. **Import**: `mlx-community/Qwen3-1.7B-4bit` (mały model na start) → pasek postępu
   (`downloading x/y GB`) → `verifying` → rekord z badge stanu `ready` na liście.
   Potwierdź w terminalu: `curl http://<IP>:8080/x/download/status` → pola snake_case: `state`,`bytes_done`,`bytes_total`.
2. **Wczytaj** → badge **ZAŁADOWANY**. `curl http://<IP>:8080/v1/models` → na liście pojawił się
   `mlx:mlx-community/Qwen3-1.7B-4bit` z `context_window: 8192` (potwierdź realne okno → Task 7 finding).
3. **Chat MLX**:
   `curl -N http://<IP>:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"mlx:mlx-community/Qwen3-1.7B-4bit","messages":[{"role":"user","content":"Napisz wiersz o Wiśle"}],"stream":true}'`
   → tokeny SSE → `data: [DONE]`. Bez strumienia (`stream:false`) → JSON `message.content` + `usage`.
4. **409 przed załadowaniem** (przed krokiem 2 albo po kroku 5): model `mlx:coh/any` →
   `HTTP 409` z `"type":"model_not_ready"` (NIE 404 — prefiks `mlx:` jest czyj).
   Obok: `apple-afm` działa dalej; zły id bez prefiksu → 404 jak w Fazie 1.
5. **Odładuj** → badge znika, `mlx:...` znika z `/v1/models`, chat na nim → 409.
6. **Single-flight**: dwa równoległe chat (jeden mlx) → drugi dostaje `429 server_busy`.
7. **Memory pressure**: załaduj duży model → obróć/obciąż urządzenie (lub Xcode Debug → Simulate Memory
   Warning na symulatorze) → banner „Niska pamięć…" + auto-unload (badge znika).
8. **Usuń pliki**: przycisk nieaktywny gdy ZAŁADOWANY; po odładowaniu → rekord znika,
   `curl -X DELETE http://<IP>:8080/x/models/mlx%3A<repo>` → `{"deleted":true}`.
Uwaga: otwarcie **Modele** przy działającym serwerze = chwilny restart nasłuchu na tym samym porcie
(attach wymienia rejestr silników) — żądania w tym oknie ~ms mogą wypaść; odpytaj ponownie.
