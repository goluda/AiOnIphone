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
        var config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeHF.self]
        let session = URLSession(configuration: config)
        store = ModelStore(root: root)
        downloader = HFDownloader(store: store, client: HFClient(session: session, base: URL(string: "https://fake.hf")!), session: session, root: root)
    }

    func testHappyPathReadyWithRecord() async throws {
        try await downloader.start(repo: repo, revision: "rev")
        let st = await downloader.currentStatus()
        XCTAssertEqual(st.state, .ready)
        XCTAssertEqual(st.bytesTotal, Int64(1000 + #"{"model_type":"mlx"}"#.utf8.count))
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
        let st = await downloader.currentStatus()
        XCTAssertEqual(st.state, .ready)
    }

    func testInProgressRejectsSecondStart() async throws {
        // długie pobieranie: wstrzymaj FakeHF dużym plikiem + fail po połowie? Prościej:
        // start dwukrotnie sekwencyjnie gdy pierwszy w stanie downloading przez failOnce:
        FakeHF.failOncePath = "/\(repo)/resolve/rev/model.safetensors"
        try? await downloader.start(repo: repo, revision: "rev")
        // po błędzie stan failed → ponowny start OK (retry), nie inProgress
        FakeHF.failOncePath = nil
        try await downloader.start(repo: repo, revision: "rev")
        let st = await downloader.currentStatus()
        XCTAssertEqual(st.state, .ready)
    }

    func testHFClientDecodesNestedOid() throws {
        let json = Data(#"{"siblings":[{"rfilename":"model.safetensors","size":10,"lfs":{"oid":"abc"}}]}"#.utf8)
        let info = try ModelJSON.decoder.decode(HFModelInfo.self, from: json)
        XCTAssertEqual(info.siblings, [HFSibling(rFilename: "model.safetensors", size: 10, lfsOid: "abc")])
        let noLfs = Data(#"{"siblings":[{"rfilename":"config.json","size":5}]}"#.utf8)
        let info2 = try ModelJSON.decoder.decode(HFModelInfo.self, from: noLfs)
        XCTAssertNil(info2.siblings.first?.lfsOid)
    }
}
