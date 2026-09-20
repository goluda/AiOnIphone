# PocketServe — English Localization Plan (Phase 4a — REQUIRED before public release)

**User intent (2026-09-20):** the iPhone app will be released **publicly**, so the UI must be **English by default**. Keep Polish as a secondary locale. English is already canonical for docs/comments/commits.

## Current state
- No localization infrastructure: zero `.strings` / `.xcstrings` catalogs; `Info.plist` has **no** `CFBundleDevelopmentRegion` / `CFBundleLocalizations`.
- UI is **hardcoded Polish**. Inventory (real strings, 2026-09-20):

| File | Polish strings to localize |
|---|---|
| `ContentView.swift` | "Modele", "online/offline" state label text, Start/Stop (already EN) |
| `ModelsView.swift` | "Import z Hugging Face", "Import", "Modele", "Brak pobranych modeli", "ZAŁADOWANY", "Odładuj", "Wczytaj", "Ponów import", "Usuń pliki", "Co pobrać?", "Anuluj", "Błąd", "Niska pamięć — model odładowany automatycznie", dialog message "Przykładowe modele…", preset notes ("dobry polski, polecany na start", "tuż pod limitem 6 GB", "mniejszy, jakość wyższa", "najszybszy start, testowy") |
| `ModelsViewModel.swift` | `humanize(_:)` returns Polish for every `DownloadAPIError`; preset `note` fields; "mlx" strings |
| `AFMEngine.swift` | user-facing `NSError` description "Apple Intelligence wyłączony" |
| `MLXEngine.swift` | user-facing `NSError` descriptions "model nie załadowany" |
| `ModelsViewModel.swift` bridge | `invalidRequest("model nie znaleziony")`, "id wymagane" |
| `Info.plist` | `NSBonjourServices` comment fine; add usage-description strings if server touches local network prompts |
| App display name | "PocketServe" (keep) |

## Approach
1. Introduce String catalogs: `PocketServe1/PocketServe1/Localizable.xcstrings` (Xcode 15+; works with 27).
2. Replace every user-facing literal with `Text("Models")` / `String(localized:)`. **Default (base) language = English.** Move Polish into the `pl` locale.
3. `Info.plist`: `CFBundleDevelopmentRegion = en`; `CFBundleLocalizations = [en, pl]`.
4. Localize `humanize(_:)` and `NSError` descriptions via localized keys (do not hardcode).
5. Localize the `ServerAPIError.userMessage` strings too — they surface over HTTP **and** in UI (keep server-side tokens English regardless: OpenAI-compatible `type` tokens stay as-is).
6. Format numbers/bytes with `ByteCountFormatter` / `.formatted()` under the active locale (already used).

## Also for public launch (bundle into 4a/4b)
- App Store: English metadata, screenshots, privacy nutrition label, support URL.
- Re-verify on device with **iOS language = English** that no Polish leaks (system-permission dialogs, this app's copy).
- Keep docs/runbooks English (done).

## Acceptance
- [ ] iPhone set to English → every screen, alert, button, error, empty-state reads English.
- [ ] Polish locale still renders Polish (regression, not removal).
- [ ] No untranslated `Text("…")` literals remain (grep gate: no Polish diacritics in `PocketServe1/PocketServe1/*.swift` outside `pl` catalog).
- [ ] `CFBundleDevelopmentRegion = en`.

## Suggested sequencing
This can land as its own small PR **after** Phase 2 merges and (optionally) alongside Phase 2.5, but **must ship before** any public/TestFlight distribution beyond personal use.
