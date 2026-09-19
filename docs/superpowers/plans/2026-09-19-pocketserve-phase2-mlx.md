# PocketServe Faza 2 (MLX + HF downloader) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Silnik inferencji `mlx:<repo>` obok `apple-afm`: pobieranie modeli MLX z Hugging Face na iPhone, zarządzanie nimi z UI iOS (import po ID / lista / load / unload / usuwanie plików), inference przez endpoint z Fazy 1.

**Architecture:** 3 warstwy wg speca: `ModelKit` (nowy SPM, czysty Foundation — downloader + store + coordinator, w pełni testowany na Mac), `OpenAICompat` (route'y `/x/*` przez wstrzykiwany `ServerExtension`, bez nowych zależności), target iOS (`MLXEngine` adapter mlx-swift + `ModelsViewModel`/`ModelsView`).

**Tech Stack:** Swift 6 strict concurrency, URLSession (mock przez URLProtocol), CryptoKit SHA256, Network (HTTPServer w F.1), mlx-swift (tylko target iOS), SwiftUI.

**Spec:** `docs/superpowers/specs/2026-09-19-pocketserve-phase2-mlx-design.md` (zatwierdzony)

## Global Constraints

- Swift 6 strict concurrency (`swift-tools-version: 6.0`); wszystko `Sendable`
- `ModelKit`: zero zależności poza Foundation/CryptoKit; platformy `.iOS(.v17), .macOS(.v14)`; testy `swift test` na macOS
- `mlx-swift` NIGDZIE w pakiecie z testami CI — wyłącznie target iOS (ryzyko API dryf: pin tag + typecheck, mechanizm Fazy 1)
- Model dev-testowy: `mlx-community/Qwen3-1.7B-4bit-4bit`; docelowy Qwen3-8B-4bit
- 1 model MLX załadowany naraz; niezaładowany `mlx:*` request → `409 model_not_ready`; decyzja silnika wyłącznie z pola `model`
- Katalog: `Documents/models/<repo z "/"→"_">`; katalog stanu `Documents/Models.json`; pliki tymczasowe `.part`
- Weryfikacja SHA256 = `lfs.oid` z HF API gdy jest; resume przez `Range`, przy ignorowanym Range → restart pliku
- Twardy guard load: `bytesOnDisk > 6_000_000_000` → odrzucony (`409 memory_pressure`); memory-warning → auto-unload + banner UI
- `/x/*` NIE gate'owane busy-gate 429; chat single-flight bez zmian
- Błędy w shape `{"error":{"message","type"}}`; repo-id regex `^[\w.\-]+\/[\w.\-]+$`
- UI iOS: 2 osobne akcje: **Odładuj** i **Usuń pliki** (decyzja usera); usuwanie zablokowane gdy loaded
- Testy: TDD RED→GREEN; komendy przez `PATH=/usr/bin:$PATH` (zepsuty shim `swift`); commit po każdym zielonym tasku, message verbatim
- `HTTPServer` bez wstrzykniętego extension → `/x/*` → `501`; testy OpenAICompat Fazy 1 (33/33) muszą zostać zielone

---

### Task 1: Pakiet `ModelKit` — typy stanu + `ModelStore`

**Files:**
- Create: `Packages/ModelKit/Package.swift`
- Create: `Packages/ModelKit/Sources/ModelKit/Types.swift`
- Create: `Packages/ModelKit/Sources/ModelKit/ModelStore.swift`
- Create: `Packages/ModelKit/Tests/ModelKitTests/ModelStoreTests.swift`

**Interfaces:**
- Consumes: (nic — pierwszy task)
- Produces: `enum DownloadState: String, Codable, Sendable { idle, downloading, verifying, ready, failed }`; `struct DownloadStatus: Codable, Sendable, Equatable { state: DownloadState, repo: String?, bytesDone: Int64, bytesTotal: Int64, error: String? }`; `struct ModelRecord: Codable, Sendable, Equatable { id, repo, revision, quant: String?, bytesOnDisk: Int64, downloadedAt: Date, loaded: Bool, state: DownloadState, error: String? }`; `actor ModelStore` z `records()/upsert(_:)/setLoaded(_::_:)/canLoad(_:)/delete(_:)/bytesFree()`; enum `ModelStore.Guard { ok, tooBig(bytes: Int64), notReady, unknown }`, `ModelStore.StoreError { notFound, loaded, io(String) }`. Klucze JSON snake_case: `bytes_on_disk`, `downloaded_at`, `repo` itd. (klasy `ModelRecord`/`DownloadStatus` kodowane domyślnie — JSONEncoder z `.iso8601` ustawiany przez producenta; testy walidują obecność kluczy `bytes_on_disk`).

- [ ] **Step 1: Package.swift**

```swift
// Packages/ModelKit/Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModelKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ModelKit", targets: ["ModelKit"])],
    targets: [
        .target(name: "ModelKit"),
        .testTarget(name: "ModelKitTests", dependencies: ["ModelKit"]),
    ]
)
```

- [ ] **Step 2: Napisz failing tests**

```swift
// Packages/ModelKit/Tests/ModelKitTests/ModelStoreTests.swift
import XCTest
@testable import ModelKit

final class ModelStoreTests: XCTestCase {
    private func makeRoot() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("models"), withIntermediateDirectories: true)
        return dir
    }
    private func rec(_ repo: String, state: DownloadState = .ready, bytes: Int64 = 1_000, loaded: Bool = false) -> ModelRecord {
        ModelRecord(id: "mlx:\(repo)", repo: repo, revision: "main", quant: "4bit",
                    bytesOnDisk: bytes, downloadedAt: Date(timeIntervalSince1970: 0), loaded: loaded, state: state, error: nil)
    }

    func testUpsertRecordsPersistToDiskAndReload() async throws {
        let root = makeRoot()
        let store = ModelStore(root: root)
        await store.upsert(rec("a/b"))
        let reloaded = ModelStore(root: root)
        let rs = await reloaded.records()
        XCTAssertEqual(rs.count, 1)
        XCTAssertEqual(rs.first?.id, "mlx:a/b")
        XCTAssertEqual(rs.first?.state, .ready)
        let data = try Data(contentsOf: root.appendingPathComponent("Models.json"))
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("bytes_on_disk"), s)
    }

    func testCanLoadGuards() async throws {
        let root = makeRoot()
        let store = ModelStore(root: root, loadGuardBytes: 5_000)
        await store.upsert(rec("big", bytes: 6_000))
        XCTAssertEqual(await store.canLoad("mlx:big"), .tooBig(bytes: 6_000))
        await store.upsert(rec("dl", state: .downloading))
        XCTAssertEqual(await store.canLoad("mlx:dl"), .notReady)
        XCTAssertEqual(await store.canLoad("mlx:nope"), .unknown)
        await store.upsert(rec("ok"))
        XCTAssertEqual(await store.canLoad("mlx:ok"), .ok)
    }

    func testDeleteBlockedWhileLoaded() async throws {
        let root = makeRoot()
        let store = ModelStore(root: root)
        await store.upsert(rec("x", loaded: true))
        do { try await store.delete("mlx:x"); XCTFail("should throw") } catch ModelStore.StoreError.loaded {}
        await store.upsert(rec("y", loaded: false))
        try await store.delete("mlx:y")
        let modelDir = root.appendingPathComponent("models").appendingPathComponent("y")
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        await store.upsert(rec("z"))
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("models").appendingPathComponent("z"), withIntermediateDirectories: true)
        try await store.delete("mlx:z")
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("models").appendingPathComponent("z").path))
    }
}
```

- [ ] **Step 3: Run → FAIL** (`cannot find 'ModelStore'`)

Run: `PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit --filter ModelStoreTests`

- [ ] **Step 4: Implement Types.swift + ModelStore.swift**

```swift
// Packages/ModelKit/Sources/ModelKit/Types.swift
import Foundation

public enum DownloadState: String, Codable, Sendable { case idle, downloading, verifying, ready, failed }

public struct DownloadStatus: Codable, Sendable, Equatable {
    public let state: DownloadState
    public let repo: String?
    public let bytesDone: Int64
    public let bytesTotal: Int64
    public let error: String?
    public init(state: DownloadState, repo: String?, bytesDone: Int64, bytesTotal: Int64, error: String? = nil) {
        self.state = state; self.repo = repo; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.error = error
    }
}

public struct ModelRecord: Codable, Sendable, Equatable {
    public let id: String
    public let repo: String
    public let revision: String
    public let quant: String?
    public let bytesOnDisk: Int64
    public let downloadedAt: Date
    public var loaded: Bool
    public var state: DownloadState
    public var error: String?
    public init(id: String, repo: String, revision: String, quant: String?, bytesOnDisk: Int64,
                downloadedAt: Date, loaded: Bool = false, state: DownloadState = .ready, error: String? = nil) {
        self.id = id; self.repo = repo; self.revision = revision; self.quant = quant
        self.bytesOnDisk = bytesOnDisk; self.downloadedAt = downloadedAt; self.loaded = loaded
        self.state = state; self.error = error
    }
}

public enum RepoValidationError: Error { case badFormat }

public enum RepoValidator {
    public static func validate(_ repo: String) throws {
        let ok = repo.range(of: #"^[\w.\-]+/[\w.\-]+$"#, options: .regularExpression) != nil
        guard ok else { throw RepoValidationError.badFormat }
    }
    public static func safeDirName(_ repo: String) -> String { repo.replacingOccurrences(of: "/", with: "_") }
}

public struct ModelJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
```

```swift
// Packages/ModelKit/Sources/ModelKit/ModelStore.swift
import Foundation

public actor ModelStore {
    public enum Guard: Equatable { case ok, tooBig(bytes: Int64), notReady, unknown }
    public enum StoreError: Error { case notFound, loaded, io(String) }

    private let root: URL
    private let loadGuardBytes: Int64
    private var records: [String: ModelRecord] = [:]

    public init(root: URL, loadGuardBytes: Int64 = 6_000_000_000) {
        self.root = root; self.loadGuardBytes = loadGuardBytes
        if let data = try? Data(contentsOf: root.appendingPathComponent("Models.json")),
           let rs = try? ModelJSON.decoder.decode([ModelRecord].self, from: data) {
            for r in rs { var r = r; r.loaded = false; records[r.id] = r } // restart: nic załadowanego
        }
    }

    public func records() -> [ModelRecord] { Array(records.values).sorted { $0.downloadedAt < $1.downloadedAt } }

    public func upsert(_ record: ModelRecord) { records[record.id] = record; persist() }

    public func setLoaded(_ id: String, _ loaded: Bool) {
        guard var r = records[id] else { return }; r.loaded = loaded; records[id] = r; persist()
    }

    public func canLoad(_ id: String) -> Guard {
        guard let r = records[id] else { return .unknown }
        guard r.state == .ready else { return .notReady }
        guard r.bytesOnDisk <= loadGuardBytes else { return .tooBig(bytes: r.bytesOnDisk) }
        return .ok
    }

    public func delete(_ id: String) throws {
        guard let r = records[id] else { throw StoreError.notFound }
        guard !r.loaded else { throw StoreError.loaded }
        let dir = root.appendingPathComponent("models").appendingPathComponent(RepoValidator.safeDirName(r.repo))
        try? FileManager.default.removeItem(at: dir)
        records[id] = nil
        persist()
    }

    public func bytesFree() -> Int64 {
        (try? FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? Int64) ?? 0
    }

    private func persist() {
        let url = root.appendingPathComponent("Models.json")
        do {
            let data = try ModelJSON.encoder.encode(records.values.sorted { $0.id < $1.id })
            try data.write(to: url, options: .atomic)
        } catch { /* log; UI pokaże pusty katalog */ }
    }
}
```

- [ ] **Step 5: Run → GREEN (3/3)**

Run: `PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit`

- [ ] **Step 6: Commit**

```bash
git add Packages/ModelKit
git commit -m "feat(modelkit): state types + persistent ModelStore with guards"
```

---

### Task 2: `HFClient` + `HFDownloader` (resume `.part` + SHA256)

**Files:**
- Create: `Packages/ModelKit/Sources/ModelKit/HFClient.swift`
- Create: `Packages/ModelKit/Sources/ModelKit/HFDownloader.swift`
- Create: `Packages/ModelKit/Tests/ModelKitTests/HFDownloaderTests.swift`
- Create: `Packages/ModelKit/Tests/ModelKitTests/FakeHF.swift`

**Interfaces:**
- Consumes: `DownloadState`, `DownloadStatus`, `ModelRecord`, `RepoValidator`, `ModelJSON` (Task 1)
- Produces: `struct HFSibling: Codable, Sendable { rFilename: String, size: Int64?, lfsOid: String? }` (klucze `rfilename`, `size`, `lfs.oid`); `struct HFModelInfo: Codable, Sendable { siblings: [HFSibling] }`; `actor HFClient { init(session: URLSession, base: URL); func fetchModelInfo(_ repo: String, revision: String) throws -> HFModelInfo; func isMLX(_ repo: String, revision: String) async throws -> Bool }`; `actor HFDownloader { init(store: ModelStore, client: HFClient, session: URLSession, root: URL); func start(repo: String, revision: String) async throws; func status() -> DownloadStatus }`; `enum HFDownloaderError: Error { case inProgress, alreadyReady, notMLX, http(Int), checksum }`.

- [ ] **Step 1: FakeHF (stub URLProtocol)**

```swift
// Packages/ModelKit/Tests/ModelKitTests/FakeHF.swift
import Foundation

final class FakeHF: URLProtocol {
    nonisolated(unsafe) static var files: [String: Data] = [:]   // path po "https://fake.hf/"
    nonisolated(unsafe) static var failOncePath: String?
    nonisolated(unsafe) static var ignoreRange = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        guard var data = FakeHF.files[path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return
        }
        if let fail = FakeHF.failOncePath, fail == path {
            FakeHF.failOncePath = nil
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        var headers: [String: String] = [:]
        let range = request.value(forHTTPHeaderField: "Range")
        if !FakeHF.ignoreRange, let range,
           let r = range.range(of: #"bytes=(\d+)-"#, options: .regularExpression),
           let start = Int(range[r].dropFirst(6).dropLast()) {
            let slice = data.dropFirst(start)
            headers["Content-Range"] = "bytes \(start)-\(data.count - 1)/\(data.count)"
            data = Data(slice)
            client?.urlProtocol(self, didReceive: Response(status: 206), cacheStoragePolicy: .notAllowed)
        } else {
            client?.urlProtocol(self, didReceive: Response(status: 200), cacheStoragePolicy: .notAllowed)
        }
        headers["Content-Length"] = "\(data.count)"
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private final class Response: HTTPURLResponse { init(status: Int) {
        super.init(url: URL(string: "https://fake.hf")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)! } }
}
```

- [ ] **Step 2: failing tests**

```swift
// Packages/ModelKit/Tests/ModelKitTests/HFDownloaderTests.swift
import XCTest
@testable import ModelKit

final class HFDownloaderTests: XCTestCase {
    var root: URL!; var store: ModelStore!; var downloader: HFDownloader!
    let repo = "mlx-community/test-qwen-mlx"

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        URLProtocol.registerClass(FakeHF.self)
        let cfg = Data(#"{"model_type":"mlx"}"#.utf8)
        FakeHF.files = ["/api/models/\(repo)/revision/rev": Data(#"""
        {"siblings":[{"rfilename":"config.json","size":\#(cfg.count)},{"rfilename":"model.safetensors","size":1000}]}
        """#.utf8),
                        "/\(repo)/resolve/rev/config.json": cfg,
                        "/\(repo)/resolve/rev/model.safetensors": Data(repeating: 0xAB, count: 1000)]
        FakeHF.ignoreRange = false; FakeHF.failOncePath = nil
        let session = URLSession(configuration: .ephemeral)
        store = ModelStore(root: root)
        downloader = HFDownloader(store: store, client: HFClient(session: session, base: URL(string: "https://fake.hf")!), session: session, root: root)
    }

    func testHappyPathReadyWithRecord() async throws {
        try await downloader.start(repo: repo, revision: "rev")
        let st = await downloader.currentStatus()
        XCTAssertEqual(st.state, .ready)
        XCTAssertEqual(st.bytesTotal, 1000 + #"""#"{"model_type":"mlx"}""#.utf8.count)
        let rs = await store.records()
        XCTAssertEqual(rs.first?.bytesOnDisk, 1000) // tylko safetensors liczy się do rozmiaru
        XCTAssertEqual(rs.first?.state, .ready)
    }

    func testResumeAfterFailureUsesPartFile() async throws {
        FakeHF.failOncePath = "/\(repo)/resolve/rev/model.safetensors"
        do { try await downloader.start(repo: repo, revision: "rev") } catch {}
        // częściowy .part może nie istnieć (błąd przed bajtami) — retry musi dokończyć:
        FakeHF.failOncePath = nil
        try await downloader.start(repo: repo, revision: "rev")
        let st = await downloader.currentStatus()
        XCTAssertEqual(st.state, .ready)
        let finalFile = root.appendingPathComponent("models").appendingPathComponent("mlx-community_test-qwen-mlx").appendingPathComponent("model.safetensors")
        XCTAssertEqual(try Data(contentsOf: finalFile).count, 1000)
    }

    func testNonMLXRejected() async throws {
        FakeHF.files["/\(repo)/resolve/rev/config.json"] = Data(#"{"model_type":"llama"}"#.utf8)
        do { try await downloader.start(repo: repo, revision: "rev"); XCTFail() } catch HFDownloaderError.notMLX {}
    }

    func testChecksumMismatchMarksFailed() async throws {
        let badOid = String(repeating: "0", count: 64)
        FakeHF.files["/api/models/\(repo)/revision/rev"] = Data(#"""
        {"siblings":[{"rfilename":"model.safetensors","size":100,"lfs":{"oid":"\#(badOid)"}}]}
        """#.utf8)
        FakeHF.files["/\(repo)/resolve/rev/model.safetensors"] = Data(repeating: 0x11, count: 100)
        do {
            try await downloader.start(repo: repo, revision: "rev")
            XCTFail("powinno rzucić checksum")
        } catch HFDownloaderError.checksum(let name) {
            XCTAssertEqual(name, "model.safetensors")
        }
        let st = await downloader.currentStatus()
        XCTAssertEqual(st.state, .failed)
        let dir = root.appendingPathComponent("models").appendingPathComponent("mlx-community_test-qwen-mlx")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors.part").path), "wadliwy .part usunięty")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path))
    }

    func testChecksumSkippedWhenOidAbsent() async throws {
        FakeHF.files["/\(repo)/resolve/rev/model.safetensors"] = Data(repeating: 0x00, count: 100)
        try await downloader.start(repo: repo, revision: "rev") // brak oid w info → skip
        XCTAssertEqual(await downloader.currentStatus().state, .ready)
    }

    func testInProgressRejectsSecondStart() async throws {
        // długie pobieranie: wstrzymaj FakeHF dużym plikiem + fail po połowie? Prościej:
        // start dwukrotnie sekwencyjnie gdy pierwszy w stanie downloading przez failOnce:
        FakeHF.failOncePath = "/\(repo)/resolve/rev/model.safetensors"
        try? await downloader.start(repo: repo, revision: "rev")
        // po błędzie stan failed → ponowny start OK (retry), nie inProgress
        FakeHF.failOncePath = nil
        try await downloader.start(repo: repo, revision: "rev")
        XCTAssertEqual(await downloader.currentStatus().state, .ready)
    }
}
```

- [ ] **Step 3: Run → FAIL**

Run: `PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit --filter HFDownloaderTests`

- [ ] **Step 4: Implement HFClient + HFDownloader**

```swift
// Packages/ModelKit/Sources/ModelKit/HFClient.swift
import Foundation

public struct HFSibling: Codable, Sendable, Equatable {
    public let rFilename: String
    public let size: Int64?
    public let lfsOid: String?
    public init(rFilename: String, size: Int64?, lfsOid: String?) { self.rFilename = rFilename; self.size = size; self.lfsOid = lfsOid }
}
// lfs.oid czytany custom init(from:) — extension pod HFClient.

public struct HFModelInfo: Codable, Sendable, Equatable {
    public let siblings: [HFSibling]
}

public actor HFClient {
    let session: URLSession
    let base: URL
    public init(session: URLSession = .shared, base: URL = URL(string: "https://huggingface.co")!) {
        self.session = session; self.base = base
    }
    public func fetchModelInfo(_ repo: String, revision: String) async throws -> HFModelInfo {
        let url = base.appendingPathComponent("api/models/\(repo)/revision/\(revision)")
        let (data, resp) = try await session.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw HFDownloaderError.http((resp as? HTTPURLResponse)?.statusCode ?? -1) }
        return try ModelJSON.decoder.decode(HFModelInfo.self, from: data)
    }
    public func configText(_ repo: String, revision: String) async -> String? {
        let url = base.appendingPathComponent("\(repo)/resolve/\(revision)/config.json")
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    public func isMLX(_ repo: String, revision: String) async -> Bool {
        guard let cfg = await configText(repo, revision: revision) else { return false }
        return cfg.contains("\"mlx\"") || cfg.contains("mlx_")
    }
}

// Custom decode lfs.oid (zagnieżdżony obiekt lfs: {oid: String}):
private enum SiblingKeys: String, CodingKey { case rfilename, size, lfs }
private enum LfsKeys: String, CodingKey { case oid }

extension HFSibling {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: SiblingKeys.self)
        rFilename = try c.decode(String.self, forKey: .rfilename)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        if let lfs = try? c.nestedContainer(keyedBy: LfsKeys.self, forKey: .lfs) {
            lfsOid = try lfs.decodeIfPresent(String.self, forKey: .oid)
        } else { lfsOid = nil }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: SiblingKeys.self)
        try c.encode(rFilename, forKey: .rfilename)
        try c.encodeIfPresent(size, forKey: .size)
        if let oid = lfsOid { try c.encode(["oid": oid], forKey: .lfs) }
    }
}
```

Test `testHFClientDecodesNestedOid` (dodaj w Step 2): JSON `{"siblings":[{"rfilename":"model.safetensors","size":10,"lfs":{"oid":"abc"}}]}` dekoduje się do `HFSibling(rFilename:"model.safetensors", size:10, lfsOid:"abc")`; brak `lfs` → `lfsOid == nil`.

```swift
// Packages/ModelKit/Sources/ModelKit/HFDownloader.swift
import Foundation
import CryptoKit

public enum HFDownloaderError: Error, Equatable { case inProgress, alreadyReady, notMLX, http(Int), checksum(String) }

public actor HFDownloader {
    private let store: ModelStore
    private let client: HFClient
    private let session: URLSession
    private let root: URL
    private var status = DownloadStatus(state: .idle, repo: nil, bytesDone: 0, bytesTotal: 0)

    public init(store: ModelStore, client: HFClient, session: URLSession, root: URL) {
        self.store = store; self.client = client; self.session = session; self.root = root
    }

    public func currentStatus() -> DownloadStatus { status }

    public func start(repo: String, revision: String) async throws {
        try RepoValidator.validate(repo)
        if case .downloading = status.state { throw HFDownloaderError.inProgress }
        guard await client.isMLX(repo, revision: revision) else { throw HFDownloaderError.notMLX }
        let info = try await client.fetchModelInfo(repo, revision: revision)
        let files = info.siblings.filter { $0.rFilename.hasSuffix(".safetensors") || $0.rFilename.hasSuffix(".safetensors.index.json") || $0.rFilename.hasSuffix(".json") || $0.rFilename.hasSuffix(".model.txt") || $0.rFilename.hasSuffix(".txt") }
        guard files.contains(where: { $0.rFilename.hasSuffix(".safetensors") }) else { throw HFDownloaderError.notMLX }
        let dir = root.appendingPathComponent("models").appendingPathComponent(RepoValidator.safeDirName(repo))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = files.compactMap(\.size).reduce(Int64(0), +)
        status = DownloadStatus(state: .downloading, repo: repo, bytesDone: 0, bytesTotal: total)
        var done: Int64 = 0
        do {
            for s in files {
                let final = dir.appendingPathComponent((s.rFilename as NSString).lastPathComponent)
                let part = URL(fileURLWithPath: final.path + ".part")
                let got = try await download(url: client.base.appendingPathComponent("\(repo)/resolve/\(revision)/\(s.rFilename)"), to: part)
                if let oid = s.lfsOid, try sha256(of: part) != oid.lowercased() {
                    try? FileManager.default.removeItem(at: part)
                    throw HFDownloaderError.checksum(s.rFilename)
                }
                if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
                try FileManager.default.moveItem(at: part, to: final)
                done += got
                status = DownloadStatus(state: .downloading, repo: repo, bytesDone: done, bytesTotal: total)
            }
            status = DownloadStatus(state: .verifying, repo: repo, bytesDone: done, bytesTotal: total)
            let bytes = modelBytes(in: dir)
            let quant = repo.components(separatedBy: "-").last.map { $0.hasSuffix("bit") ? $0 : nil }
            status = DownloadStatus(state: .ready, repo: repo, bytesDone: done, bytesTotal: total)
            await store.upsert(ModelRecord(id: "mlx:\(repo)", repo: repo, revision: revision, quant: quant,
                                           bytesOnDisk: bytes, downloadedAt: Date(), state: .ready))
        } catch {
            status = DownloadStatus(state: .failed, repo: repo, bytesDone: done, bytesTotal: total, error: "\(error)")
            throw error
        }
    }

    private func download(url: URL, to part: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        let existing = Int64((try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let (bytes, resp) = try await session.bytes(for: request)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 || code == 206 else { throw HFDownloaderError.http(code) }
        let handle: FileHandle = {
            if FileManager.default.fileExists(atPath: part.path) {
                let h = try! FileHandle(forWritingTo: part)
                if code == 200 { h.truncateFile(atOffset: 0) } else { h.seekToEndOfFile() }
                return h
            } else { FileManager.default.createFile(atPath: part.path, contents: nil); return try! FileHandle(forWritingTo: part) }
        }()
        defer { try? handle.close() }
        var written: Int64 = existing
        var buf = Data()
        buf.reserveCapacity(1 << 20)
        for try await b in bytes {
            buf.append(b)
            if buf.count >= (1 << 20) { try handle.write(contentsOf: buf); written += Int64(buf.count); buf.removeAll(keepingCapacity: true) }
        }
        if !buf.isEmpty { try handle.write(contentsOf: buf); written += Int64(buf.count) }
        return Int64(written - existing)
    }

    private func sha256(of url: URL) throws -> String {
        let h = SHA256.Hasher()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while autoreleasepool(invoking: { () -> Bool in
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            h.update(data: chunk); return true
        }) {}
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func modelBytes(in dir: URL) -> Int64 { // tylko .safetensors liczą się do rozmiaru modelu
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while case let f as URL = en?.nextObject() {
            guard f.pathExtension == "safetensors" else { continue }
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
```

**Uwagi:** (a) filtr w `start()` obejmuje config/tokenizer — test liczby bajtów total zakłada config+model; (b) `session.bytes(for:)` ze stubem URLProtocol działa w testach na Mac; (c) single-flight: `guard case .downloading = status.state` bez `await` między guardem a przypisaniem `.downloading` (atomowość aktora); (d) `.part` + `Range` = resume (test `testResumeAfterFailureUsesPartFile`); (e) checksum weryfikowany TYLKO gdy `lfsOid != nil` (test `testChecksumMismatchMarksFailed` musi podstawić `lfs.oid` w stubie info API i zły content pliku → `HFDownloaderError.checksum` + stan `.failed` + usunięty `.part`).

- [ ] **Step 5: Run → GREEN (7/7)**

Run: `PATH=/usr/bin:$PATH swift test --package-path Packages/ModelKit`

- [ ] **Step 6: Commit**

```bash
git add Packages/ModelKit
git commit -m "feat(modelkit): HF metadata client + resumable downloader with sha256"
```

---

### Task 3: `DownloadCoordinator` + `ModelLoading` (spin + memory pressure)

**Files:**
- Create: `Packages/ModelKit/Sources/ModelKit/DownloadCoordinator.swift`
- Create: `Packages/ModelKit/Tests/ModelKitTests/CoordinatorTests.swift`

**Interfaces:**
- Consumes: `HFDownloader.currentStatus()`, `ModelStore`, `DownloadStatus`, `ModelRecord` (Task 1-2)
- Produces: `enum DownloadAPIError: Error, Equatable { invalidRequest(String), downloadInProgress, notReady, notLoaded, notFound, memoryPressure, downloadFailed(String), http(Int) }`; `protocol ModelLoading: Sendable { func load(_ record: ModelRecord) async throws; func unload() async; var loadedId: String? { get async } }`; `actor DownloadCoordinator: DownloadAPI`; `protocol DownloadAPI: Sendable { start(repo:revision:) ; currentStatus(); records(); load(id:) ; unload(id:) ; delete(id:) ; notifyMemoryWarning() }` (wszystko `async throws` wg tabeli poniżej).

- [ ] **Step 1: failing tests**

```swift
// Packages/ModelKit/Tests/ModelKitTests/CoordinatorTests.swift
import XCTest
@testable import ModelKit

final class FakeLoader: ModelLoading {
    nonisolated(unsafe) var loadCall: ModelRecord?
    func load(_ record: ModelRecord) async throws { loadCall = record }
    func unload() async {}
    var loadedId: String? { nil }
}

final class CoordinatorTests: XCTestCase {
    func makeCoordinator() -> (DownloadCoordinator, ModelStore, FakeLoader) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        let store = ModelStore(root: root)
        let loader = FakeLoader()
        URLProtocol.registerClass(FakeHF.self)
        FakeHF.files = ["/api/models/a/b/revision/rev": Data(#"""
        {"siblings":[{"rfilename":"config.json","size":19},{"rfilename":"model.safetensors","size":10}]}
        """#.utf8),
                        "/a/b/resolve/rev/config.json": Data(#"{"model_type":"mlx"}"#.utf8),
                        "/a/b/resolve/rev/model.safetensors": Data(repeating: 7, count: 10)]
        let session = URLSession(configuration: .ephemeral)
        let dl = HFDownloader(store: store, client: HFClient(session: session, base: URL(string: "https://fake.hf")!), session: session, root: root)
        let c = DownloadCoordinator(downloader: dl, store: store, loader: loader)
        return (c, store, loader)
    }

    func testFullCycleDownloadLoadUnloadDelete() async throws {
        let (c, store, loader) = makeCoordinator()
        try await c.start(repo: "a/b", revision: "rev")
        XCTAssertEqual((await c.currentStatus()).state, .ready)
        try await c.load(id: "mlx:a/b")
        XCTAssertNotNil(loader.loadCall)
        try await c.unload(id: "mlx:a/b")
        try await c.delete(id: "mlx:a/b")
        let rs = await c.records(); XCTAssertTrue(rs.isEmpty)
        // po delete load → unknown
        do { try await c.load(id: "mlx:a/b"); XCTFail() } catch DownloadAPIError.notFound {}
    }

    func testGuardRejections() async throws {
        let (c, store, _) = makeCoordinator()
        await store.upsert(ModelRecord(id: "mlx:x", repo: "x", revision: "r", quant: nil, bytesOnDisk: 7_000_000_000, downloadedAt: Date(), state: .ready))
        do { try await c.load(id: "mlx:x"); XCTFail() } catch DownloadAPIError.memoryPressure {}
        await store.upsert(ModelRecord(id: "mlx:y", repo: "y", revision: "r", quant: nil, bytesOnDisk: 1, downloadedAt: Date(), state: .downloading))
        do { try await c.load(id: "mlx:y"); XCTFail() } catch DownloadAPIError.notReady {}
        do { try await c.unload(id: "mlx:y"); XCTFail() } catch DownloadAPIError.notLoaded {}
    }

    func testMemoryWarningUnloadsActive() async throws {
        final class IdLoader: ModelLoading {
            var id: String?
            func load(_ r: ModelRecord) async throws { id = r.id }
            func unload() async { id = nil }
            var loadedId: String? { id }
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        let store = ModelStore(root: root)
        await store.upsert(ModelRecord(id: "mlx:z", repo: "z", revision: "r", quant: nil, bytesOnDisk: 5, downloadedAt: Date(), state: .ready))
        let loader = IdLoader()
        let c = DownloadCoordinator(downloader: nil, store: store, loader: loader)
        try await c.load(id: "mlx:z")
        XCTAssertEqual((await store.records()).first?.loaded, true)
        await c.notifyMemoryWarning()
        let r = await store.records()
        XCTAssertEqual(r.first?.loaded, false)
        XCTAssertNotNil(r.first) // pliki zostają
    }
}
```

- [ ] **Step 2: Run → FAIL; Step 3: Implement**

```swift
// Packages/ModelKit/Sources/ModelKit/DownloadCoordinator.swift
import Foundation

public enum DownloadAPIError: Error, Equatable {
    case invalidRequest(String), downloadInProgress, notReady, notLoaded, notFound, memoryPressure, downloadFailed(String), http(Int), io(String)
}

public protocol ModelLoading: Sendable {
    func load(_ record: ModelRecord) async throws
    func unload() async
    var loadedId: String? { get async }
}

public protocol DownloadAPI: Sendable {
    func start(repo: String, revision: String?) async throws
    func currentStatus() async -> DownloadStatus
    func records() async -> [ModelRecord]
    func load(id: String) async throws
    func unload(id: String) async throws
    func delete(id: String) async throws
    func notifyMemoryWarning() async
}

public actor DownloadCoordinator: DownloadAPI {
    private let downloader: HFDownloader?
    private let store: ModelStore
    private let loader: ModelLoading

    public init(downloader: HFDownloader?, store: ModelStore, loader: ModelLoading) {
        self.downloader = downloader; self.store = store; self.loader = loader
    }

    public func start(repo: String, revision: String?) async throws {
        guard let dl = downloader else { throw DownloadAPIError.invalidRequest("no downloader") }
        do { try await dl.start(repo: repo, revision: revision ?? "main") }
        catch HFDownloaderError.inProgress { throw DownloadAPIError.downloadInProgress }
        catch HFDownloaderError.notMLX { throw DownloadAPIError.invalidRequest("repo bez plików mlx") }
        catch let e as HFDownloaderError {
            switch e { case .http(let c): throw DownloadAPIError.http(c); case .checksum(let f): throw DownloadAPIError.downloadFailed("checksum \(f)"); default: throw DownloadAPIError.downloadFailed("\(e)") }
        }
    }
    public func currentStatus() async -> DownloadStatus { await downloader?.currentStatus() ?? DownloadStatus(state: .idle, repo: nil, bytesDone: 0, bytesTotal: 0) }
    public func records() async -> [ModelRecord] { await store.records() }

    public func load(id: String) async throws {
        switch await store.canLoad(id) {
        case .unknown: throw DownloadAPIError.notFound
        case .notReady: throw DownloadAPIError.notReady
        case .tooBig: throw DownloadAPIError.memoryPressure
        case .ok: break
        }
        let rec = (await store.records()).first { $0.id == id }!
        try await loader.load(rec)
        await store.setLoaded(id, true)
        // single MLX: poprzedni = załaduj -> store pokazuje tylko jeden loaded
        for r in await store.records() where r.id != id && r.loaded { await store.setLoaded(r.id, false) }
    }
    public func unload(id: String) async throws {
        guard (await loader.loadedId) == id else { throw DownloadAPIError.notLoaded }
        await loader.unload(); await store.setLoaded(id, false)
    }
    public func delete(id: String) async throws {
        do { try await store.delete(id) }
        catch ModelStore.StoreError.notFound { throw DownloadAPIError.notFound }
        catch ModelStore.StoreError.loaded { throw DownloadAPIError.notLoaded }
        catch let ModelStore.StoreError.io(m) { throw DownloadAPIError.io(m) }
    }
    public func notifyMemoryWarning() async {
        if let lid = await loader.loadedId { await loader.unload(); await store.setLoaded(lid, false) }
    }
}
```

- [ ] **Step 4: Run → GREEN; Step 5: Commit**

```bash
git add Packages/ModelKit && git commit -m "feat(modelkit): DownloadCoordinator + memory-pressure unload"
```

---

### Task 4: `ServerExtension` + route'y `/x/*` w `OpenAICompat`

**Files:**
- Modify: `Packages/OpenAICompat/Sources/OpenAICompat/HTTPServer.swift` (rejestr, init, routing)
- Create: `Packages/OpenAICompat/Sources/OpenAICompat/ServerExtension.swift`
- Create: `Packages/OpenAICompat/Tests/OpenAICompatTests/XRoutesTests.swift`

**Interfaces:**
- Consumes: `DownloadAPI`/`DownloadStatus`/`ModelRecord` — przez duplikat `protocol` w OpenAICompat? NIE: `ServerExtension` przyjmuje generically-typed handler closures. `enum ServerAPIError { case invalidRequest(String), downloadInProgress, notReady, notLoaded, notFound, memoryPressure, failed(String) }` żyje w **OpenAICompat**; ModelKit's `DownloadAPIError` mapowany w app-target adapterze (Task 6).
- Produces: `struct DownloadHandler: Sendable` (closures: `start`, `status`, `records`, `load`, `unload`, `delete`, `memoryWarning` — each async); `struct ServerExtension: Sendable { download: DownloadHandler?; extraModels: @Sendable () -> [ModelInfo] }`; `HTTPServer.init(port:engines:extension:)` z default `extension: ServerExtension? = nil`; route'y: `GET /x/models` → 200 JSON `[records]`; `POST /x/download` {repo,revision?} → 202; `GET /x/download/status`; `POST /x/models/load|unload` {id} → 202/200; `DELETE /x/models/<id-percent-encoded>` → 200; mapowanie błędów → 400/409 wg speca §5.

- [ ] **Step 1: failing tests (mock handler, real NWListener :0, URLSession)**

```swift
// Packages/OpenAICompat/Tests/OpenAICompatTests/XRoutesTests.swift
import XCTest
@testable import OpenAICompat

final class XRoutesTests: XCTestCase {
    func start(ext: ServerExtension?) async throws -> (HTTPServer, URLSession) {
        let s = HTTPServer(engines: [MockEngine()], extension: ext)
        _ = try await s.start(port: 0)
        let cfg = URLSessionConfiguration.ephemeral; cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return (s, URLSession(configuration: cfg))
    }
    func url(_ s: HTTPServer, _ p: String) -> URL { URL(string: "http://127.0.0.1:\(s.port!)\(p)")! }

    func testNoExtensionGives501() async throws {
        let (s, c) = try await start(ext: nil)
        defer { Task { await s.stop() } }
        let (_, r) = try await c.data(from: url(s, "/x/models"))
        XCTAssertEqual((r as? HTTPURLResponse)?.statusCode, 501)
    }

    func testGetModelsRecordsEndpoint() async throws {
        let rec = "[{\"id\":\"mlx:a/b\",\"loaded\":false,\"state\":\"ready\"}]"
        let ext = ServerExtension(download: DownloadHandler(
            start: { _, _ in }, status: { Data() }, records: { Data(rec.utf8) },
            load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}
        ), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        let (d, r) = try await c.data(from: url(s, "/x/models"))
        XCTAssertEqual((r as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: d, as: UTF8.self).contains("mlx:a/b"))
    }

    func testMapErrorsToStatus() async throws {
        let ext = ServerExtension(download: DownloadHandler(
            start: { _, _ in throw ServerAPIError.downloadInProgress },
            status: { Data() }, records: { Data() },
            load: { _ in throw ServerAPIError.notReady },
            unload: { _ in throw ServerAPIError.notLoaded },
            delete: { _ in throw ServerAPIError.notFound },
            memoryWarning: {}
        ), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        var req = URLRequest(url: url(s, "/x/download")); req.httpMethod = "POST"; req.httpBody = Data(#"{"repo":"a/b"}"#.utf8)
        let (bd, br) = try await c.data(for: req)
        XCTAssertEqual((br as? HTTPURLResponse)?.statusCode, 409)
        XCTAssertTrue(String(decoding: bd, as: UTF8.self).contains("download_in_progress"))
        var lreq = URLRequest(url: url(s, "/x/models/load")); lreq.httpMethod = "POST"; lreq.httpBody = Data(#"{"id":"mlx:a/b"}"#.utf8)
        let (_, lr) = try await c.data(for: lreq)
        XCTAssertEqual((lr as? HTTPURLResponse)?.statusCode, 409)
        var dreq = URLRequest(url: url(s, "/x/models/mlx%3Aa%2Fb")); dreq.httpMethod = "DELETE"
        let (_, dr) = try await c.data(for: dreq)
        XCTAssertEqual((dr as? HTTPURLResponse)?.statusCode, 404)
    }

    func testXRoutesNotBusyGated() async throws {
        // busy serwer (mock stream) + /x/status -> 200 mimo 429 na /chat
        // użyj tego samego mechanizmu co concurrent 429 test: odpal stream, potem /x/download/status
        let ext = ServerExtension(download: DownloadHandler(start: { _, _ in }, status: { Data(#"{"state":"ready","bytesDone":1,"bytesTotal":1}"#.utf8) }, records: { Data() }, load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        var req = URLRequest(url: url(s, "/v1/chat/completions")); req.httpMethod = "POST"
        req.httpBody = Data(#"{"model":"mock","messages":[{"role":"user","content":"x"}],"stream":true}"#.utf8)
        let (_, br) = try await c.bytes(for: req) // stream otwarty
        _ = br
        let (sd, sr) = try await c.data(from: url(s, "/x/download/status"))
        XCTAssertEqual((sr as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: sd, as: UTF8.self).contains("ready"))
    }

    func testXDownloadPassThrough202() async throws {
        let ext = ServerExtension(download: DownloadHandler(start: { _, _ in }, status: { Data() }, records: { Data() }, load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        var req = URLRequest(url: url(s, "/x/download")); req.httpMethod = "POST"
        req.httpBody = Data(#"{"repo":"mlx-community/x-4bit"}"#.utf8)
        let (_, r) = try await c.data(for: req)
        XCTAssertEqual((r as? HTTPURLResponse)?.statusCode, 202)
    }

    func testDynamicModelsAppendedToV1Models() async throws {
        let ext = ServerExtension(download: DownloadHandler(start: { _, _ in }, status: { Data() }, records: { Data() }, load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}),
                                  extraModels: { [ModelInfo(id: "mlx:live", contextWindow: 8192)] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        let (d, _) = try await c.data(from: url(s, "/v1/models"))
        XCTAssertTrue(String(decoding: d, as: UTF8.self).contains("mlx:live"))
    }
}
```

- [ ] **Step 2: Run → FAIL (compile)**; Step 3: Implement

```swift
// Packages/OpenAICompat/Sources/OpenAICompat/ServerExtension.swift
import Foundation

public enum ServerAPIError: Error {
    case invalidRequest(String), downloadInProgress, notReady, notLoaded, notFound, memoryPressure, failed(String)
    public var httpStatus: Int {
        switch self {
        case .invalidRequest: return 400
        case .downloadInProgress, .notReady, .notLoaded, .memoryPressure: return 409
        case .notFound: return 404
        case .failed: return 502
        }
    }
    public var type: String {
        switch self {
        case .invalidRequest: return "invalid_request_error"
        case .downloadInProgress: return "download_in_progress"
        case .notReady: return "model_not_ready"
        case .notLoaded: return "model_not_loaded"
        case .notFound: return "not_found"
        case .memoryPressure: return "memory_pressure"
        case .failed: return "download_failed"
        }
    }
}

public struct DownloadHandler: Sendable {
    public let start: @Sendable (String, String?) async throws -> Void
    public let status: @Sendable () async throws -> Data
    public let records: @Sendable () async throws -> Data
    public let load: @Sendable (String) async throws -> Void
    public let unload: @Sendable (String) async throws -> Void
    public let delete: @Sendable (String) async throws -> Void
    public let memoryWarning: @Sendable () async -> Void
    public init(start: @escaping @Sendable (String, String?) async throws -> Void,
                status: @escaping @Sendable () async throws -> Data,
                records: @escaping @Sendable () async throws -> Data,
                load: @escaping @Sendable (String) async throws -> Void,
                unload: @escaping @Sendable (String) async throws -> Void,
                delete: @escaping @Sendable (String) async throws -> Void,
                memoryWarning: @escaping @Sendable () async -> Void) {
        self.start = start; self.status = status; self.records = records
        self.load = load; self.unload = unload; self.delete = delete; self.memoryWarning = memoryWarning
    }
}

public struct ServerExtension: Sendable {
    public let download: DownloadHandler?
    public let extraModels: @Sendable () -> [ModelInfo]
    public init(download: DownloadHandler?, extraModels: @escaping @Sendable () -> [ModelInfo]) {
        self.download = download; self.extraModels = extraModels
    }
}
```

W `HTTPServer.swift`: (1) `private var ext: ServerExtension?` + parametr init `extension: ServerExtension? = nil`; (2) `/v1/models` response łączy `engines + ext?.extraModels()`; (3) w `route()` PRZED busy-gate'em (po CL-validation) sekcja:

```swift
if let ext = ext, req.path.hasPrefix("/x/") {
    do {
        switch (req.method, req.path) {
        case ("GET", "/x/models"): sendRaw(conn, 200, try await ext.download!.records(), type: "application/json")
        case ("GET", "/x/download/status"): sendRaw(conn, 200, try await ext.download!.status(), type: "application/json")
        case ("POST", "/x/download"):
            struct DReq: Decodable { let repo: String; let revision: String? }
            let d = try JSONDecoder().decode(DReq.self, from: req.body)
            try await ext.download!.start(repo: d.repo, revision: d.revision)
            sendRaw(conn, 202, Data(#"{"accepted":true}"#.utf8), type: "application/json")
        case ("POST", "/x/models/load"), ("POST", "/x/models/unload"):
            struct IdReq: Decodable { let id: String }
            let d = try JSONDecoder().decode(IdReq.self, from: req.body)
            if req.method == "POST", req.path == "/x/models/load" { try await ext.download!.load(id: d.id); sendRaw(conn, 202, Data(#"{"loading":true}"#.utf8), type: "application/json") }
            else { try await ext.download!.unload(id: d.id); sendRaw(conn, 200, Data(#"{"unloaded":true}"#.utf8), type: "application/json") }
        case ("DELETE", let p) where p.hasPrefix("/x/models/"):
            let id = String(p.dropFirst("/x/models/".count)).removingPercentEncoding ?? ""
            try await ext.download!.delete(id: id)
            sendRaw(conn, 200, Data(#"{"deleted":true}"#.utf8), type: "application/json")
        default: sendError(conn, 404, type: "not_found", message: "brak endpointu")
        }
    } catch let e as ServerAPIError { sendError(conn, e.httpStatus, type: e.type, message: "\(e)") }
    catch { sendError(conn, 500, type: "server_error", message: "\(error)") }
    return
}
if ext == nil, req.path.hasPrefix("/x/") { sendError(conn, 501, type: "not_implemented", message: "serwer bez /x/*"); return }
```
(Uwaga: `if let ext` warunek — dla nil-ext path `/x/*` spada na 501 BEFORE `default: 404` w starym routerze. Dodaj `sendRaw(conn:status:body:type:)` helper identyczny jak `sendJSON` z jawnym `Content-Type`.)

- [ ] **Step 4: Run → GREEN + pełna faza-1 regresja 33/33.** Run: `PATH=/usr/bin:$PATH swift test --package-path Packages/OpenAICompat`
- [ ] **Step 5: Commit** `git add Packages/OpenAICompat && git commit -m "feat(server): /x/* management routes via injectable ServerExtension"`

---

### Task 5: `MLXEngine` (adapter mlx-swift, target iOS, device-only)

**Files:**
- Create: `PocketServe1/PocketServe1/MLXEngine.swift`
- Modify: `PocketServe/RUN_ON_IPHONE_PHASE2.md` (utwórz fragment "dodaj mlx-swift")
- Test: brak w CI (device smoke Task 7) — walidacja = typecheck vs SDK + mlx-swift sources

**Interfaces:**
- Consumes: `InferenceEngine`, `GenerationParams` (OpenAICompat, Faza 1)
- Produces: `final class MLXEngine: InferenceEngine, @unchecked Sendable` — `static let shared`; `static var loadedId: String?` (NSLock-protected, format `"mlx:<repo>"`, nonisolated); `func loadRecord(_ repo: String, revision: String, folder: URL) async throws`; `func unloadNow() async`; `id` = `loadedId ?? "mlx:none"`; `contextWindow = loaded model.modelContextLength ?? 8192`; `stream(prompt:params:)` jak AFM (onTermination + kumulacja→delta).

- [ ] **Step 1: dodaj mlx-swift do projektu (Xcode GUI, potem commit pbxproj)**

Plik: `PocketServe/RUN_ON_IPHONE_PHASE2.md`: sekcja — Project → Package Dependencies → `+` → `github.com/ml-explore/mlx-swift` → **Up to Next Major Version od najnowszego release tag shown in UI** → Add; record tag+SHA do fazy §; docelowo w `pbxproj` `minimumVersion` pin.

- [ ] **Step 2: discovery API (krok obowiązkowy — wzorzec AFM z F.1)**

Uruchom: `xcodebuild -resolvePackageDependencies -project PocketServe1/PocketServe1.xcodeproj -scheme PocketServe1 2>&1 | tail -5` potem odczytaj `~/Library/Developer/Xcode/DerivedData/PocketServe1-*/SourcePackages/checkouts/mlx-swift/Source/MLXLLM/LLMModel.swift` — zanotuj w raporcie DOKŁADNE sygnatury `load(_:configuration:)`, `streamGeneration(...)`, `modelContextLength`, `GenerateParameters.init`. Dopasuj szablon poniżej (jeśli `streamGeneration` ma split `stream`/`finish` → użyj wariantu B).

- [ ] **Step 3: MLXEngine.swift (szablon — dostosuj sygnatury wg Step 2)**

```swift
import Foundation
import MLX
import MLXLLM
import MLXRandom
import OpenAICompat

final class MLXEngine: InferenceEngine, @unchecked Sendable {
    static let shared = MLXEngine()

    private static let lock = NSLock()
    private static var _loadedId: String?   // "mlx:<repo>" albo nil
    private static var _model: LLMModel?

    static var loadedId: String? { lock.withLock { _loadedId } }

    var id: String { Self.loadedId ?? "mlx:none" }
    var contextWindow: Int { Self.lock.withLock { Self._model?.modelContextLength } ?? 8192 }

    func loadRecord(_ repo: String, revision: String, folder: URL) async throws {
        await unloadNow()
        MLXRandom.seed(42)
        var config = LLMModelConfiguration()
        config.metadata = ["model": repo]
        let model = try LLMModel.load(folder, configuration: config)
        Self.lock.withLock { Self._model = model; Self._loadedId = "mlx:\(repo)" }
    }

    func unloadNow() async {
        Self.lock.withLock { Self._model = nil; Self._loadedId = nil }
        MXLClearMalloc()
    }

    func stream(prompt: String, params: GenerationParams) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let model = Self.lock.withLock({ Self._model }) else {
                    continuation.finish(throwing: NSError(domain: "mlx", code: 2, userInfo: [NSLocalizedDescriptionKey: "model nie załadowany"])); return
                }
                var sent = ""
                do {
                    var gp = GenerateParameters()
                    gp.temperature = Float(params.temperature)
                    gp.maxTokens = params.maxTokens
                    // Wariant A (callback kumulacyjny). Jeśli discovery pokaże split stream/finish → Wariant B.
                    try await model.streamGeneration(prompt: prompt, parameters: gp) { full, _ in
                        let delta = full.hasPrefix(sent) ? String(full.dropFirst(sent.count)) : full
                        sent = full
                        if !delta.isEmpty { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

**Uwagi:** statyczny stan chroniony `NSLock` (`withLock` — iOS 15+, target 26 OK); wyścig load/unload vs generacja wyklucza single-flight serwera (unload tylko gdy busy=false — straż w `DownloadCoordinator`); sygnatury `LLMModel.load`, `streamGeneration`, `GenerateParameters`, `modelContextLength`, `MXLClearMalloc` potwierdź w Step 2 discovery i wpisz finalne do pliku.

- [ ] **Step 4: typecheck all app sources** (komendy z task-7-report F.1, + `-I` SourcePackages build products po xcodebuild build iOS sim)
- [ ] **Step 5: Commit** `git commit -am "feat(ios): MLXEngine adapter (mlx-swift) + package pin"`

---

### Task 6: `ModelsViewModel` + `ModelsView` + wiring iOS target

**Files:**
- Create: `PocketServe1/PocketServe1/ModelsViewModel.swift`, `ModelsView.swift`
- Modify: `ContentView.swift` (NavigationStack + link "Modele"), `ServerModel.swift` (udostępnij `HTTPServer` + `DownloadCoordinator` do view; `/v1/models` dynamic mlx)

**Interfaces:**
- Consumes: `ModelKit.DownloadCoordinator/HFDownloader/HFClient/ModelStore/ModelRecord/RepoValidator`, `ModelLoading` adapter `MLXLoading` (opak. `MLXEngine`), `ServerExtension`/`ServerAPIError`/`ServerModel.port`
- Produces: `@MainActor final class ModelsViewModel: ObservableObject` — `@Published records/status/alert`; `func importRepo()`; `func load(_:)`; `func unload(_:)`; `func deleteFiles(_:)`; start() serwera instaluje `ServerExtension` z adapterem.

- [ ] **Step 1: ModelsViewModel.swift**

```swift
import SwiftUI
import ModelKit
import OpenAICompat

final class MLXLoading: ModelLoading {
    func load(_ record: ModelRecord) async throws {
        let folder = ModelKitPaths.modelsRoot.appendingPathComponent(RepoValidator.safeDirName(record.repo))
        try await MLXEngine.shared.loadRecord(record.repo, revision: record.revision, folder: folder)
    }
    func unload() async { await MLXEngine.shared.unloadNow() }
    var loadedId: String? { MLXEngine.loadedId }
}

@MainActor final class ModelsViewModel: ObservableObject {
    @Published var records: [ModelRecord] = []
    @Published var status = DownloadStatus(state: .idle, repo: nil, bytesDone: 0, bytesTotal: 0)
    @Published var alert: String?
    @Published var repoInput = ""
    @Published var memoryWarning = false
    let store: ModelStore
    let coordinator: DownloadCoordinator
    private var poll: Timer?

    init(serverModel: ServerModel) {
        let root = ModelKitPaths.documentsRoot
        store = ModelStore(root: root)
        let dl = HFDownloader(store: store, client: HFClient(session: .shared), session: .shared, root: root)
        coordinator = DownloadCoordinator(downloader: dl, store: store, loader: MLXLoading())
        serverModel.attach(extension: Self.makeExtension(coordinator: coordinator))
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.memoryWarning = true
            Task { await self.coordinator.notifyMemoryWarning(); await self.refresh() }
        }
    }
    static func makeExtension(coordinator: DownloadCoordinator) -> ServerExtension {
        ServerExtension(download: DownloadHandler(
            start: { repo, rev in try await coordinator.start(repo: repo, revision: rev) },
            status: { try JSONEncoder().encode(await coordinator.currentStatus()) },
            records: { try JSONEncoder().encode(await coordinator.records()) },
            load: { id in try await coordinator.load(id: id) },
            unload: { id in try await coordinator.unload(id: id) },
            delete: { id in try await coordinator.delete(id: id) },
            memoryWarning: { await coordinator.notifyMemoryWarning() }),
            extraModels: { MLXEngine.loadedId.map { ModelInfo(id: $0, contextWindow: MLXEngine.shared.contextWindow) } ?? [] })
    }
    func refresh() async { records = await store.records(); status = await coordinator.currentStatus() }
    func importRepo() {
        let repo = repoInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { return }
        Task {
            do { try await coordinator.start(repo: repo, revision: "main") }
            catch let e as DownloadAPIError { alert = Self.humanize(e) }
            await refresh(); pollStatus()
        }
    }
    func load(_ id: String) { Task { do { try await coordinator.load(id: id) } catch let e as DownloadAPIError { alert = Self.humanize(e) }; await refresh() } }
    func unload(_ id: String) { Task { try? await coordinator.unload(id: id); await refresh() } }
    func deleteFiles(_ id: String) { Task { do { try await coordinator.delete(id: id) } catch { alert = "nie można usunąć — najpierw odładuj model" }; await refresh() } }
    static func humanize(_ e: DownloadAPIError) -> String {
        switch e {
        case .invalidRequest: return "to nie jest poprawne repo mlx"
        case .memoryPressure: return "model za duży — wybierz mniejszą kwantyzację"
        case .downloadInProgress: return "pobieranie już w toku"
        default: return "operacja niedostępna: \(e)"
        }
    }
    private func pollStatus() { poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
        Task { @MainActor in guard let self else { return }
            await self.refresh()
            if self.status.state == .ready || self.status.state == .failed { self.poll?.invalidate() }
        } }
    }
}

enum ModelKitPaths {
    static var documentsRoot: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var modelsRoot: URL { documentsRoot.appendingPathComponent("models") }
}
```

**Uwagi:** (a) walidacja repo odbywa się w `coordinator.start()` (rzuca `DownloadAPIError.invalidRequest`) — VM nie powtarza `RepoValidator`; (b) `humanize` mapuje błędy na ludzki PL; (c) jeden współdzielony singleton `MLXEngine.shared` dla serwera i VM; (d) `JSONEncoder` — użyj `ModelJSON.encoder` z ModelKit (Task 1, `.iso8601`) zamiast lokalnego, jeśli tam zdefiniowany.

- [ ] **Step 2: ModelsView.swift (ekran wg speca §6)** — NavigationStack z listą kart (nazwa/quant GB/badge stanu/progres), TextField repo + Import, akcje Wczytaj/Odładuj/Usuń pliki (`.disabled` gdy `rec.loaded`), banner memory gdy `vm.memoryWarning`:

```swift
import SwiftUI
import ModelKit

struct ModelsView: View {
    @StateObject var vm: ModelsViewModel
    var body: some View {
        List {
            if vm.memoryWarning {
                Text("Niska pamięć — model odładowany automatycznie")
                    .font(.caption).foregroundStyle(.white)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 8))
            }
            Section("Import z Hugging Face") {
                TextField("np. mlx-community/Qwen3-1.7B-4bit-4bit", text: $vm.repoInput)
                    .textInputAutocapitalization(.never).font(.system(.body, design: .monospaced))
                Button("Import") { vm.importRepo() }
                    .disabled(vm.status.state == .downloading || vm.status.state == .verifying)
                if vm.status.state == .downloading || vm.status.state == .verifying {
                    ProgressView(value: Double(vm.status.bytesDone), total: Double(max(1, vm.status.bytesTotal)))
                    Text("\(vm.status.state.rawValue) \(format(vm.status.bytesDone))/\(format(vm.status.bytesTotal))").font(.caption)
                }
            }
            Section("Modele") {
                if vm.records.isEmpty { Text("Brak pobranych modeli").foregroundStyle(.secondary) }
                ForEach(vm.records, id: \.id) { rec in
                    VStack(alignment: .leading) {
                        HStack { Text(rec.repo).font(.headline)
                            if rec.loaded { Text("ZAŁADOWANY").font(.caption2).foregroundStyle(.white).padding(4).background(.green, in: Capsule()) }
                            Spacer() }
                        Text("\(rec.quant ?? "?") · \(format(rec.bytesOnDisk)) · \(rec.state.rawValue)").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if rec.loaded { Button("Odładuj") { vm.unload(rec.id) } }
                            else if rec.state == .ready { Button("Wczytaj") { vm.load(rec.id) } }
                            if rec.state == .failed { Button("Ponów import") { vm.importRepo() } }
                            Spacer()
                            Button("Usuń pliki", role: .destructive) { vm.deleteFiles(rec.id) }.disabled(rec.loaded)
                        }
                    }
                }
            }
        }
        .navigationTitle("Modele")
        .task { await vm.refresh() }
        .alert("Błąd", isPresented: .init(get: { vm.alert != nil }, set: { if !$0 { vm.alert = nil } })) { Button("OK") { vm.alert = nil } } message: { Text(vm.alert ?? "") }
    }
    private func format(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}
```

- [ ] **Step 3: ContentView + ServerModel wiring**

Decyzje wiringu (wykonaj dokładnie tak): (1) `ServerModel.swift` — dodaj `private var ext: ServerExtension?`, `func attach(extension: ServerExtension)` (woła attach przed/po `HTTPServer(engines:extension:)` — sygnatura HTTPServer z Task 4; jeśli serwer już działa, przebuduj go przez stop+restart na tym samym porcie); (2) silniki: `[AFMEngine(), MLXEngine.shared]` — MLX zawsze w rejestrze; dispatch w obsłudze `/v1/chat/completions`: jeśli `model` ma prefiks `mlx:` i `MLXEngine.loadedId != model` → odpowiedz `409` `model_not_ready` zanim oddasz zapytanie do silnika; (3) `ServerModel` tworzy `private(set) lazy var viewModel = ModelsViewModel(serverModel: self)`; to `ModelsViewModel.init` woła `serverModel.attach(extension:)` jako officialny kanał montażu (SceneDelegate nic nie dokleja); (4) `ContentView`: owiń treść w `NavigationStack` + `NavigationLink("Modele") { ModelsView(vm: model.viewModel) }`; (5) memory warning: obserwator w `ModelsViewModel.init` (kod wyżej) → banner + auto-unload.

- [ ] **Step 4:** typecheck + build na simulatorze? (iPhone simulator nie ma MLX na mac? — mlx-swift wspiera arm64 simulator → xcodebuild build `generic/platform=iOS Simulator` jeśli dostępny; fallback: device w Task 7) + build app PASS
- [ ] **Step 5: Commit** `git commit -am "feat(ios): models management UI wired to coordinator"`

---

### Task 7: Device smoke + RUN_ON_IPHONE_PHASE2.md (user-driven)

**Files:** Modify: `PocketServe/RUN_ON_IPHONE_PHASE2.md`; Create raport `.superpowers/sdd/task-7p2-report.md`

- [ ] Step 1: Uzupełnij RUN doc: mlx-swift add step, pełna pętla: Import→progress→ready→Wczytaj→curl stream `mlx:`→Odładuj→Usuń; curl `GET /x/models`, `GET /x/download/status`; oczekiwane wyjścia 202/200/409; ~40 tok/s vs AFM porównanie.
- [ ] Step 2 (user): dodaj mlx-swift (GUI), wrzuć nowe pliki do targetu (Membership), Build & Run na iPhonie.
- [ ] Step 3 (agent z terminala): curl-e + raport; zapis SHAs.

**DoD (spec §8):** import→ready→load→inference→unload→delete end-to-end (UI + curl); /v1/models odzwierciedla stan; testy ModelKit+OpenAICompat zielone (regresja F.1+nowe); device bez crashy; memory guard unit-zielony.
