# Avalonia Companion Phase 3 — ukończono 2026-09-20

## Stan
- PR #3 merged do main (`3cdb4cc`, no-ff). Branch `feat/avalonia-companion` skasowany lokalnie + zdalnie.
- `dotnet test companion/PocketServe.Companion.slnx` → 41/41 green. Build czysty przy `TreatWarningsAsErrors` + latest-recommended.
- **Pending: device smoke** against iPhone (192.168.68.27:8080) — checklista w `companion/RUN_COMPANION.md`.

## Warstwy
- Core = BCL-only (`System.Net.Http`/`System.Text.Json`, zero Avalonia): `ServerAddress`, `SseReader`, `PocketServeClient`, `ChatState`.
- App = Avalonia 12 UI, kod EN / UI stringi PL.

## Pułapki (zmierzone)
- **FakeHandler**: HttpClient rozporządza `request.Content` po wysłaniu → bufferuj `ReadAsStringAsync` WEWNĄTRZ `SendAsync` do rekordu `RecordedRequest`, inaczej ObjectDisposedException przy assertach na ciele.
- Chunk SSE w testach: dokładny JSON OpenAI (`choices[0].delta.content`), jeden zbędny nawias = JsonReaderException byte 67.
- **Avalonia 12**: `TextBox.Watermark` → `PlaceholderText`; `StringConverters.IsNotEmpty` nie istnieje → `IsNotNullOrEmpty` (x:Static musi mieć dokładną wielkość liter); `Run Text="{Binding}"` inline działa w bubble.
- **CA1001 + sealed**: owning CTS → `sealed class` + plain `IDisposable` buduje się czysto; non-sealed odpala CA1063 "+2 locations".
- **CS9105**: primary-ctor param nie może być użyty w łańcuchu `this(...)` → readonly fields + jawne konstruktory.
- CA1826/CA1305: `FirstOrDefault` na indexowalnej liście → ekstrakcja lokalnej; `int.ToString()` → `CultureInfo.InvariantCulture`.
- ** Artefakty w historii**: `git add companion` wrzucił 345 plików bin/obj (w tym 3× 80 MB libSkiaSharp.pdb). Branch niezmrgowany → `git filter-branch --index-filter 'git rm -r --cached --ignore-unmatch ...' base..HEAD` + force-push (solo dev, bezpieczne pre-merge). git-filter-repo NIE zainstalowany; filter-branch dziala. Wczesniej commit .gitignore z `bin/`+`obj/`.
- `dotnet` na tej maszynie: `/usr/local/share/dotnet` (export PATH), `swift` wymaga `PATH=/usr/bin:$PATH`.

## BACKLOG (nietknięty, nie zgubić)
F1 think-span leak (HIGH), F2 error message leak (MED), keep-awake (HIGH), AFM card (MED), i18n iOS (REQUIRED), Phase 4b.
