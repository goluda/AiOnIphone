# Handoff — Close Phase 2, then start Phase 2.5

**Start a fresh session on this file.** Do not re-derive history.

## Ground truth (verified 2026-09-20)
- Branch `feat/pocketserve-phase2`, **19 commits ahead of `master`, unmerged**. No git remote configured.
- Green: ModelKit **22/22**, OpenAICompat **50/50**, iOS Simulator `** BUILD SUCCEEDED **`.
- Device smoke (iPhone 18 Pro Max, `192.168.68.27:8080`) — **passed**: `/health`, `/x/models`, `/x/download/status` (non-zero `bytes_total` → `?blobs=true` confirmed), `/v1/models` (apple-afm + `mlx:…`, context_window 8192), mlx non-stream chat (296 tok) + SSE (82 frames + `[DONE]`), **429** single-flight, **409** `model_not_ready` after unload, DELETE 200/404 semantics, unknown-id load → 400.

## What blocks merge
1. **F2 — Swift enum leak in error envelope (MED).** `HTTPServer` renders `"\(e)"` → JSON `message` contains `invalidRequest("…")`. Add `ServerAPIError.userMessage`, use at the two `/x/*` catch sites. Test in `XRoutesTests`.

## Not blocking merge (route to their phase)
- **F3 keep-awake / AFM first-class** → Phase 2.5 (`docs/ROADMAP.md`).
- **English localization** → Phase 4a, **required before public release** (`docs/LOCALIZATION.md`).
- Minor residuals M-1…M-6, flaky-test list → `docs/KNOWN_ISSUES.md`.

## Do it in this order
1. `git checkout feat/pocketserve-phase2` and pull up to speed (`git log --oneline master..HEAD`).
2. Implement F1 (+ ModelKit `ThinkStripper`, synthetic split-chunk tests). Implement F2 (+ XRoutesTests).
3. Re-run both packages green; simulator build.
4. **Device re-smoke** (needs the phone awake + on LAN): clean mlx chat must contain **no** special tokens and a sane `message` on an error path. Use `PocketServe/RUN_ON_IPHONE_PHASE2.md` §4.
5. Merge to `master` (`git checkout master && git merge --no-ff feat/pocketserve-phase2`), concise conventional commit. Tag if desired.
6. Open **Phase 2.5** as a new brainstorm/design session (superpowers:brainstorming → spec → plan), scope = ROADMAP Phase 2.5.

## Constraints while fixing F1/F2
- Keep layer rules (AGENTS.md): the think filter must not drag MLX/UIKit into ModelKit/OpenAICompat where avoidable; `OpenAICompat` still never imports `ModelKit`.
- Don't reintroduce fixed defects (`docs/KNOWN_ISSUES.md#fixed`).
- Respect the 6 GB guard; don't raise it to make E4B fit.
- Never emit raw ChatML special-token literals into chat/commits/docs — describe them.

## Verification commands
```bash
PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit
PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat
xcodebuild -project PocketServe1/PocketServe1.xcodeproj -scheme PocketServe1 \
  -destination 'generic/platform=iOS Simulator' build
```
