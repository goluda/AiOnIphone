# Run the PocketServe Companion (desktop, .NET Avalonia)

Cross-platform (macOS / Windows / Linux) desktop client for the PocketServe iPhone server.
Requires **.NET 10 SDK**.

## 1. Build & test

```bash
dotnet build companion/PocketServe.Companion.slnx
dotnet test companion/PocketServe.Companion.slnx   # 41 Core tests
```

## 2. Run

```bash
dotnet run --project companion/src/PocketServe.Companion.App
```

## 3. Connect to the iPhone

1. On the iPhone: start PocketServe and note the address shown on the **API** screen
   (default port `8080`). Keep the screen awake or the server dies (see ROADMAP Phase 2.5).
2. In the Companion window: type the iPhone IP (e.g. `192.168.68.27`) and press **Połącz**.
3. Status dot turns green and the model ComboBox fills from `GET /v1/models`
   (`apple-afm` + any loaded `mlx:<repo>`).
4. Pick a model, type a message, **Enter** sends (Shift+Enter = newline). Tokens stream live
   into a bubble with a `▌` cursor; **Stop** cancels mid-generation.
5. The last working address is remembered in `settings.json` (LocalApplicationData / `~/.local/share`).

## Troubleshooting

| Symptom (UI) | Cause | Fix |
|---|---|---|
| `Brak połączenia z iPhonem…` | wrong IP / server not started / different Wi-Fi | start PocketServe on the iPhone, re-check IP (API screen), same LAN |
| `Przekroczono czas łączenia…` | host reachable but no answer within 5 s | start the server, retry |
| `Serwer zajęty — poczekaj na koniec generowania.` | HTTP 429 (single-flight) | wait for the running generation to finish |
| `Model nie jest gotowy — pobierz i załaduj go na iPhonie.` | HTTP 409 | download + load the model on the iPhone, then **Odśwież** |
| `Błąd silnika na iPhonie.` | HTTP 500 / mid-stream error frame | unload/reload the model on the iPhone, retry |

## Smoke checklist (device)

- [ ] Connect → green dot, models listed (≥ `apple-afm`).
- [ ] Chat `apple-afm` → tokens stream, bubble finalizes.
- [ ] Load `mlx:*` on phone → Odśwież → chat streams.
- [ ] While generating, second send is blocked (Stop instead of 429 spam).
- [ ] Unload model on phone → send → Polish 409 message, UI stays responsive.
