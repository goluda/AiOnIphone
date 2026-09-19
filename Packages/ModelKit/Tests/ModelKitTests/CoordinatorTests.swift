import XCTest
@testable import ModelKit

final class FakeLoader: ModelLoading {
    nonisolated(unsafe) var loadCall: ModelRecord?
    func load(_ record: ModelRecord) async throws { loadCall = record }
    func unload() async {}
    var loadedId: String? { nil }
}

final class IdLoader: ModelLoading {
    nonisolated(unsafe) var id: String?
    func load(_ r: ModelRecord) async throws { id = r.id }
    func unload() async { id = nil }
    var loadedId: String? { id }
}

final class HangingHF: URLProtocol {
    nonisolated(unsafe) static var files: [String: Data] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path.hasSuffix(".safetensors") { return }
        guard let data = HangingHF.files[path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(data.count)"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CoordinatorTests: XCTestCase {
    func makeCoordinator() -> (DownloadCoordinator, ModelStore, FakeLoader) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        let store = ModelStore(root: root)
        let loader = FakeLoader()
        FakeHF.files = ["/api/models/a/b/revision/rev": Data(#"""
        {"siblings":[{"rfilename":"config.json","size":19},{"rfilename":"model.safetensors","size":10}]}
        """#.utf8),
                        "/a/b/resolve/rev/config.json": Data(#"{"model_type":"mlx"}"#.utf8),
                        "/a/b/resolve/rev/model.safetensors": Data(repeating: 7, count: 10)]
        FakeHF.failOncePath = nil; FakeHF.ignoreRange = false; FakeHF.lastRangeHeader = nil
        var config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeHF.self]
        let session = URLSession(configuration: config)
        let dl = HFDownloader(store: store, client: HFClient(session: session, base: URL(string: "https://fake.hf")!), session: session, root: root)
        let c = DownloadCoordinator(downloader: dl, store: store, loader: loader)
        return (c, store, loader)
    }

    func testFullCycleDownloadLoadUnloadDelete() async throws {
        let (c, store, loader) = makeCoordinator()
        try await c.start(repo: "a/b", revision: "rev")
        let st = await c.currentStatus()
        XCTAssertEqual(st.state, .ready)
        try await c.load(id: "mlx:a/b")
        XCTAssertNotNil(loader.loadCall)
        let loadedAfterLoad = await store.records()
        XCTAssertEqual(loadedAfterLoad.first?.loaded, true)
        do { try await c.delete(id: "mlx:a/b"); XCTFail() } catch DownloadAPIError.notLoaded {}
        try await c.unload(id: "mlx:a/b")
        try await c.delete(id: "mlx:a/b")
        let rs = await c.records()
        XCTAssertTrue(rs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("models").appendingPathComponent("a_b").path))
        do { try await c.load(id: "mlx:a/b"); XCTFail() } catch DownloadAPIError.notFound {}
        do { try await c.delete(id: "mlx:a/b"); XCTFail() } catch DownloadAPIError.notFound {}
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
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        let store = ModelStore(root: root)
        await store.upsert(ModelRecord(id: "mlx:z", repo: "z", revision: "r", quant: nil, bytesOnDisk: 5, downloadedAt: Date(), state: .ready))
        let loader = IdLoader()
        let c = DownloadCoordinator(downloader: nil, store: store, loader: loader)
        try await c.load(id: "mlx:z")
        let loaded = await store.records()
        XCTAssertEqual(loaded.first?.loaded, true)
        await c.notifyMemoryWarning()
        let r = await store.records()
        XCTAssertEqual(r.first?.loaded, false)
        XCTAssertNotNil(r.first) // pliki zostają
    }

    func testInProgressPassthrough() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        HangingHF.files = ["/api/models/a/b/revision/rev": Data(#"""
        {"siblings":[{"rfilename":"config.json","size":19},{"rfilename":"model.safetensors","size":10}]}
        """#.utf8),
                         "/a/b/resolve/rev/config.json": Data(#"{"model_type":"mlx"}"#.utf8)]
        var config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingHF.self]
        let session = URLSession(configuration: config)
        let store = ModelStore(root: root)
        let dl = HFDownloader(store: store, client: HFClient(session: session, base: URL(string: "https://fake.hf")!), session: session, root: root)
        let c = DownloadCoordinator(downloader: dl, store: store, loader: FakeLoader())
        let first = Task { try? await c.start(repo: "a/b", revision: "rev") }
        try await Task.sleep(nanoseconds: 200_000_000)
        do { try await c.start(repo: "a/b", revision: "rev"); XCTFail() } catch DownloadAPIError.downloadInProgress {}
        session.invalidateAndCancel()
        try? await first.value
    }
}
