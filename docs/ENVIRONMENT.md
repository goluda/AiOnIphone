# PocketServe — Environment Notes (this machine)

## Broken shims — always work around
- `/usr/local/bin/swift` and `/usr/local/bin/rg` are **broken shims**.
- Swift → `PATH=/usr/bin:$PATH swift …`
- Search → the built-in grep tool (or `PATH=/usr/bin:$PATH grep`).

## Commands
```bash
# ModelKit tests (Foundation + CryptoKit only, runs on macOS)
PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit        # expect 22/22

# OpenAICompat tests (Foundation + Network only, runs on macOS)
PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat    # expect 50/50

# iOS app build (arm64 simulator)
xcodebuild -project PocketServe1/PocketServe1.xcodeproj -scheme PocketServe1 \
  -destination 'generic/platform=iOS Simulator' build
```

## Xcode project facts
- Sources are **synchronized root groups**: files in `PocketServe1/PocketServe1/` are compiled automatically. Editing in place is correct; **do not** create a `PocketServe/PocketServe/` mirror (removed in `ca257d6`).
- SPM pins (in `project.pbxproj`, headless-configured): `mlx-swift-examples` upToNextMajor **2.29.1**, products **MLXLLM + MLXLMCommon** (both required); `mlx-swift` **0.29.1** transitive. After clone/edit: File ▸ Packages ▸ **Resolve Package Versions**.
- Deployment target iOS **27.0** (Xcode 27 beta toolchain, SwiftUI).
- **Scheme diagnostics must stay OFF** — GPU Frame Capture: Disabled, Metal API Validation: off, and unneeded sanitizers off. With them on, every Metal-backed frame (SwiftUI text, keyboard, transitions) cost seconds — the whole UI felt broken. Confirmed live 2026-09-20: **without the debugger attached everything is fluid**.

## LSP / SourceKit noise — ignore
SourceKit reports `No such module 'UIKit' / 'MLX' / 'OpenAICompat'` and cascading `Cannot find '…' in scope` in this workspace. It does not load the Xcode build context. **`xcodebuild` succeeds** — trust `xcodebuild` + `swift test`, not the LSP diagnostics.

## Device / network
- iPhone 18 Pro Max, server on `192.168.68.27:8080`. **IP changes** — rediscover via Bonjour `_oai._tcp.`, or read the address shown on the app's home screen.
- Screen auto-dim **kills the server** (app suspension). Keep the screen awake while smoke-testing; permanent fix is Phase 2.5 (`isIdleTimerDisabled`).
- Long mlx generations (hundreds of tokens) can take **>60 s**. Use generous `curl -m` (≥120 s) and don't conclude "dead server" from a slow first token.
- Phone tethered to Wi‑Fi only for LAN; no Internet required for inference (HF download does need it).

## Model notes (Hugging Face)
- Info API needs `?blobs=true` to get `siblings[].size` and `siblings[].lfs.oid` (checksums depend on it).
- mlx fingerprint = `quantization` key in `config.json`; do not grep for the literal string "mlx".
- Verified presets (2026-09-20), safetensors totals: `mlx-community/Qwen3-0.6B-4bit` 335 MB · `Qwen3-1.7B-4bit` 968 MB · `gemma-3n-E2B-it-4bit` 4.46 GB · `gemma-3n-E4B-it-4bit` 5.82 GB (guard limit is 6 GB — tight, do not raise casually).
- Gemma 3n naming: `mlx-community/gemma-3n-E{n}B-it-4bit` (lowercase `gemma-3n` works; the capitalized variant 307-redirects).

## Safety rails
- Never commit secrets/tokens. When public auth lands (Phase 4b), keep tokens out of logs, docs and this file.
- mlx runs on the shared GPU/Metal stack — after unload, `MLX.GPU.clearCache()` releases buffers.
