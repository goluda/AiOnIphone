# PocketServe — Run on iPhone (checklist dla człowieka)

> **Zdezaktualizowane (Faza 2):** kanoniczne źródła żyją bezpośrednio w `PocketServe1/PocketServe1/` (PBXFileSystemSynchronizedRootGroup — Xcode kompiluje każdy plik tam automatycznie, kopiowanie nie jest potrzebne). Mirror `PocketServe/PocketServe/` usunięty. Instrukcje poniżej mają wartość historyczną; dla Fazy 2 patrz `RUN_ON_IPHONE_PHASE2.md`.

Pliki źródłowe były w `PocketServe/PocketServe/`. Xcode project **utwórz ręcznie** (brief Task 7, Step 1) — szkielet projektu nie jest w git.

## 1. Nowy projekt w Xcode 27
1. Xcode → **File → New → Project… → iOS → App**
2. Product Name: `PocketServe` · Interface: **SwiftUI** · Language: Swift
3. **Minimum Deployment: iOS 27** · Bundle Identifier: `com.pawel.pocketserve`
4. Location: katalog `PocketServe/` w tym repo (powstanie `PocketServe/PocketServe.xcodeproj`)
5. **File → Add Package Dependencies → Add Local…** → wybierz `Packages/OpenAICompat` → dodaj pakiet `OpenAICompat` do targetu `PocketServe`

## 2. Info.plist
Otwórz `PocketServe/PocketServe/Info.plist` i wklej zawartość `PocketServe/PocketServe/Info.plist.additions.xml` do głównego `<dict>`:
- `NSLocalNetworkUsageDescription`
- `NSBonjourServices` → `_oai._tcp`

## 3. Pliki do targetu
- **Zastąp** wygenerowany `ContentView.swift` treścią `PocketServe/PocketServe/ContentView.swift` (szablon Xcode jest nadpisywany)
- **Drag & drop** do targetu `PocketServe` (zaznacz „Copy items if needed" = OFF, pliki już są w folderze targetu):
  - `AFMEngine.swift`
  - `ServerModel.swift`
  - `BackgroundGuard.swift`
- Verify: Build Settings → *Targeted Device Families* = iPhone; *Deployment Target* = iOS 27

## 4. Build Settings
 nic specjalnego — defaults. Upewnij się tylko, że target kompiluje się dla **iOS Device** (nie simulator-only).

## 5. Run na iPhone 18 Pro Max
1. Podłącz iPhone, wybierz go jako destination, **Run (⌘R)**
2. W apce tapnij **Start**
3. Przy pierwszym starcie iOS zapyta o **Local Network** → **Allow** (bez grantu curl z LAN padnie)
4. Na ekranie: `● online :8080` + `<nazwa-iPhone>.local:8080`
5. **Potwierdź availability + capabilities AFM**: w konsoli Xcode (albo Console.app, filtr `subsystem == com.pawel.pocketserve AND category == afm`) po pierwszym żądaniu oczekiwana linia:
   `AFM available; capabilities reasoning=… toolCalling=… vision=…`
   Jeśli zamiast tego: `AFM unavailable — Apple Intelligence wyłączony` → włącz Apple Intelligence (Ustawienia → Apple Intelligence & Siri) i spróbuj ponownie.
6. IP urządzenia: Ustawienia → Wi‑Fi → (i) → Address

## 6. Smoke test z terminala Maca (ten sam LAN)
```bash
curl http://<iphone-ip>:8080/v1/models
# oczekiwane: {"object":"list","data":[{"id":"apple-afm",...}]}

curl -N -X POST http://<iphone-ip>:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"apple-afm","messages":[{"role":"user","content":"Podaj 3 fakty o Marsie"}],"stream":true}'
```
**Expected:** tokeny SSE płynące ~40 tok/s (AFM na A19 Pro). Koniec: `data: [DONE]`.

## Troubleshooting
- **Connection refused** → serwer nie wystartował (brak grantu Local Network? iPhone i Mac w innej VLAN?)
- **Apple Intelligence wyłączony** (`afm` error 1) → Ustawienia → Apple Intelligence & Siri → on
- **Brak `_oai._tcp` w `dns-sd -B _oai._tcp.`** → klucze Info.plist nie wklejone albo NetService nie opublikowany (sprawdź log `netServiceDidPublish`)
- Apka zamknięta = endpoint pada — to feature (DoD); restart przez **Start**
