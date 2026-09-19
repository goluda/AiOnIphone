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
        let big = await store.canLoad("mlx:big")
        XCTAssertEqual(big, .tooBig(bytes: 6_000))
        await store.upsert(rec("dl", state: .downloading))
        let dl = await store.canLoad("mlx:dl")
        XCTAssertEqual(dl, .notReady)
        let nope = await store.canLoad("mlx:nope")
        XCTAssertEqual(nope, .unknown)
        await store.upsert(rec("ok"))
        let ok = await store.canLoad("mlx:ok")
        XCTAssertEqual(ok, .ok)
    }

    func testDeleteBlockedWhileLoaded() async throws {
        let root = makeRoot()
        let store = ModelStore(root: root)
        await store.upsert(rec("x", loaded: true))
        do { try await store.delete("mlx:x"); XCTFail("should throw") } catch ModelStore.StoreError.loaded {}
        await store.upsert(rec("y", loaded: false))
        let modelDir = root.appendingPathComponent("models").appendingPathComponent("y")
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try await store.delete("mlx:y")
        await store.upsert(rec("z"))
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("models").appendingPathComponent("z"), withIntermediateDirectories: true)
        try await store.delete("mlx:z")
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("models").appendingPathComponent("z").path))
    }
}
