import XCTest
@testable import OpenAICompat

final class XRoutesTests: XCTestCase {
    func start(ext: ServerExtension?) async throws -> (HTTPServer, URLSession) {
        let s = HTTPServer(engines: [MockEngine()], extension: ext)
        _ = try await s.start(port: 0)
        let cfg = URLSessionConfiguration.ephemeral; cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return (s, URLSession(configuration: cfg))
    }
    func url(_ s: HTTPServer, _ p: String) async -> URL { URL(string: "http://127.0.0.1:\(await s.port!)\(p)")! }

    func testNoExtensionGives501() async throws {
        let (s, c) = try await start(ext: nil)
        defer { Task { await s.stop() } }
        let (_, r) = try await c.data(from: await url(s, "/x/models"))
        XCTAssertEqual((r as? HTTPURLResponse)?.statusCode, 501)
    }

    func testSetExtensionHotMountsXPathWithoutRestart() async throws {
        let (s, c) = try await start(ext: nil) // nasłuch już działa bez /x/*
        defer { Task { await s.stop() } }
        let (_, r1) = try await c.data(from: await url(s, "/x/models"))
        XCTAssertEqual((r1 as? HTTPURLResponse)?.statusCode, 501)
        let port = await s.port!
        let rec = "[{\"id\":\"mlx:a/b\",\"loaded\":false,\"state\":\"ready\"}]"
        await s.setExtension(ServerExtension(download: DownloadHandler(
            start: { _, _ in }, status: { Data() }, records: { Data(rec.utf8) },
            load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}
        ), extraModels: { [] }))
        let (d, r2) = try await c.data(from: URL(string: "http://127.0.0.1:\(port)/x/models")!)
        XCTAssertEqual((r2 as? HTTPURLResponse)?.statusCode, 200) // ten sam listener, bez rebindu
        XCTAssertTrue(String(decoding: d, as: UTF8.self).contains("mlx:a/b"))
    }

    func testGetModelsRecordsEndpoint() async throws {
        let rec = "[{\"id\":\"mlx:a/b\",\"loaded\":false,\"state\":\"ready\"}]"
        let ext = ServerExtension(download: DownloadHandler(
            start: { _, _ in }, status: { Data() }, records: { Data(rec.utf8) },
            load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}
        ), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        let (d, r) = try await c.data(from: await url(s, "/x/models"))
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
        var req = URLRequest(url: await url(s, "/x/download")); req.httpMethod = "POST"; req.httpBody = Data(#"{"repo":"a/b"}"#.utf8)
        let (bd, br) = try await c.data(for: req)
        XCTAssertEqual((br as? HTTPURLResponse)?.statusCode, 409)
        XCTAssertTrue(String(decoding: bd, as: UTF8.self).contains("download_in_progress"))
        var lreq = URLRequest(url: await url(s, "/x/models/load")); lreq.httpMethod = "POST"; lreq.httpBody = Data(#"{"id":"mlx:a/b"}"#.utf8)
        let (ld, lr) = try await c.data(for: lreq)
        XCTAssertEqual((lr as? HTTPURLResponse)?.statusCode, 409)
        XCTAssertTrue(String(decoding: ld, as: UTF8.self).contains("download_not_ready")) // spec §5: load-path token
        var dreq = URLRequest(url: await url(s, "/x/models/mlx%3Aa%2Fb")); dreq.httpMethod = "DELETE"
        let (_, dr) = try await c.data(for: dreq)
        XCTAssertEqual((dr as? HTTPURLResponse)?.statusCode, 404)
    }

    func testXRoutesNotBusyGated() async throws {
        // busy serwer (stream 150ms/token): /x probe -> 200 mimo busy, drugi /chat -> 429,
        // a po drenażu /chat znowu 200 — dowie, że /x omija gate, a gate chata działa
        let ext = ServerExtension(download: DownloadHandler(start: { _, _ in }, status: { Data(#"{"state":"ready","bytesDone":1,"bytesTotal":1}"#.utf8) }, records: { Data() }, load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}), extraModels: { [] })
        let s = HTTPServer(engines: [MockEngine(latency: .milliseconds(150))], extension: ext)
        _ = try await s.start(port: 0)
        defer { Task { await s.stop() } }
        let cfg = URLSessionConfiguration.ephemeral; cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let c = URLSession(configuration: cfg)
        var req = URLRequest(url: await url(s, "/v1/chat/completions")); req.httpMethod = "POST"
        req.httpBody = Data(#"{"model":"mock","messages":[{"role":"user","content":"x"}],"stream":true}"#.utf8)
        let (bytes, br) = try await c.bytes(for: req) // stream otwarty => busy acquired
        XCTAssertEqual((br as? HTTPURLResponse)?.statusCode, 200)
        let (sd, sr) = try await c.data(from: await url(s, "/x/download/status")) // probe while busy
        XCTAssertEqual((sr as? HTTPURLResponse)?.statusCode, 200) // /x bypasses gate
        XCTAssertTrue(String(decoding: sd, as: UTF8.self).contains("ready"))
        var req2 = URLRequest(url: await url(s, "/v1/chat/completions")); req2.httpMethod = "POST"
        req2.httpBody = Data(#"{"model":"mock","messages":[{"role":"user","content":"second"}]}"#.utf8)
        let (d2, r2) = try await c.data(for: req2) // concurrent chat while first in-flight
        XCTAssertEqual((r2 as? HTTPURLResponse)?.statusCode, 429) // gate chat intact
        XCTAssertTrue(String(decoding: d2, as: UTF8.self).contains("server_busy"))
        for try await _ in bytes.lines {} // drain stream => busy releases
        let (_, r3) = try await c.data(for: req2)
        XCTAssertEqual((r3 as? HTTPURLResponse)?.statusCode, 200)
    }

    func testXDownloadPassThrough202() async throws {
        let ext = ServerExtension(download: DownloadHandler(start: { _, _ in }, status: { Data() }, records: { Data() }, load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        var req = URLRequest(url: await url(s, "/x/download")); req.httpMethod = "POST"
        req.httpBody = Data(#"{"repo":"mlx-community/x-4bit"}"#.utf8)
        let (_, r) = try await c.data(for: req)
        XCTAssertEqual((r as? HTTPURLResponse)?.statusCode, 202)
    }

    func testDynamicModelsAppendedToV1Models() async throws {
        let ext = ServerExtension(download: DownloadHandler(start: { _, _ in }, status: { Data() }, records: { Data() }, load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}),
                                  extraModels: { [ModelInfo(id: "mlx:live", created: 0, contextWindow: 8192)] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        let (d, _) = try await c.data(from: await url(s, "/v1/models"))
        XCTAssertTrue(String(decoding: d, as: UTF8.self).contains("mlx:live"))
    }

    func testLoadAndDeleteDownloadInProgressGive409() async throws {
        // Task 3 hardened: load AND delete can throw downloadInProgress -> 409
        let ext = ServerExtension(download: DownloadHandler(
            start: { _, _ in }, status: { Data() }, records: { Data() },
            load: { _ in throw ServerAPIError.downloadInProgress },
            unload: { _ in },
            delete: { _ in throw ServerAPIError.downloadInProgress },
            memoryWarning: {}
        ), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        var lreq = URLRequest(url: await url(s, "/x/models/load")); lreq.httpMethod = "POST"; lreq.httpBody = Data(#"{"id":"mlx:a/b"}"#.utf8)
        let (ld, lr) = try await c.data(for: lreq)
        XCTAssertEqual((lr as? HTTPURLResponse)?.statusCode, 409)
        XCTAssertTrue(String(decoding: ld, as: UTF8.self).contains("download_in_progress"))
        var dreq = URLRequest(url: await url(s, "/x/models/mlx%3Aa%2Fb")); dreq.httpMethod = "DELETE"
        let (dd, dr) = try await c.data(for: dreq)
        XCTAssertEqual((dr as? HTTPURLResponse)?.statusCode, 409)
        XCTAssertTrue(String(decoding: dd, as: UTF8.self).contains("download_in_progress"))
    }

    func testInvalidRequestAndUnmappedErrorsGive400And502() async throws {
        let ext = ServerExtension(download: DownloadHandler(
            start: { _, _ in throw ServerAPIError.invalidRequest("repo bez plików mlx") },
            status: { Data() }, records: { Data() },
            load: { _ in throw ServerAPIError.memoryPressure },
            unload: { _ in }, delete: { _ in }, memoryWarning: {}
        ), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        var req = URLRequest(url: await url(s, "/x/download")); req.httpMethod = "POST"; req.httpBody = Data(#"{"repo":"a/b"}"#.utf8)
        let (bd, br) = try await c.data(for: req)
        XCTAssertEqual((br as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(String(decoding: bd, as: UTF8.self).contains("invalid_request_error"))
        var lreq = URLRequest(url: await url(s, "/x/models/load")); lreq.httpMethod = "POST"; lreq.httpBody = Data(#"{"id":"mlx:a/b"}"#.utf8)
        let (_, lr) = try await c.data(for: lreq)
        XCTAssertEqual((lr as? HTTPURLResponse)?.statusCode, 409)
        // failed -> 502
        let ext2 = ServerExtension(download: DownloadHandler(
            start: { _, _ in throw ServerAPIError.failed("sha mismatch") },
            status: { Data() }, records: { Data() },
            load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}
        ), extraModels: { [] })
        let (s2, c2) = try await start(ext: ext2)
        defer { Task { await s2.stop() } }
        var freq = URLRequest(url: await url(s2, "/x/download")); freq.httpMethod = "POST"; freq.httpBody = Data(#"{"repo":"a/b"}"#.utf8)
        let (fd, fr) = try await c2.data(for: freq)
        XCTAssertEqual((fr as? HTTPURLResponse)?.statusCode, 502)
        XCTAssertTrue(String(decoding: fd, as: UTF8.self).contains("download_failed"))
    }

    func testMalformedBodyGives400() async throws {
        let ext = ServerExtension(download: DownloadHandler(start: { _, _ in }, status: { Data() }, records: { Data() }, load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        var req = URLRequest(url: await url(s, "/x/download")); req.httpMethod = "POST"; req.httpBody = Data(#"{"revision":"v2"}"#.utf8) // brak repo
        let (bd, br) = try await c.data(for: req)
        XCTAssertEqual((br as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(String(decoding: bd, as: UTF8.self).contains("invalid_request_error"))
        var lreq = URLRequest(url: await url(s, "/x/models/load")); lreq.httpMethod = "POST"; lreq.httpBody = Data("not json".utf8)
        let (_, lr) = try await c.data(for: lreq)
        XCTAssertEqual((lr as? HTTPURLResponse)?.statusCode, 400)
    }

    func testUnknownXPathGives404() async throws {
        let ext = ServerExtension(download: DownloadHandler(start: { _, _ in }, status: { Data() }, records: { Data() }, load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        let (_, r) = try await c.data(from: await url(s, "/x/nope"))
        XCTAssertEqual((r as? HTTPURLResponse)?.statusCode, 404)
    }

    func testDeleteLoadedModelGives409ModelLoaded() async throws {
        // spec §5 DELETE: "409 model_loaded" — delete zwraca .modelLoaded gdy model wczytany
        let ext = ServerExtension(download: DownloadHandler(start: { _, _ in }, status: { Data() }, records: { Data() },
            load: { _ in }, unload: { _ in },
            delete: { _ in throw ServerAPIError.modelLoaded },
            memoryWarning: {}), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        var dreq = URLRequest(url: await url(s, "/x/models/mlx%3Aa%2Fb")); dreq.httpMethod = "DELETE"
        let (dd, dr) = try await c.data(for: dreq)
        XCTAssertEqual((dr as? HTTPURLResponse)?.statusCode, 409)
        XCTAssertTrue(String(decoding: dd, as: UTF8.self).contains("model_loaded"))
    }

    func testDeletePercentEncodedSlashIdDecodedBeforeClosure() async throws {
        actor IdBox { var got = ""; func set(_ i: String) { got = i }; func get() -> String { got } }
        let box = IdBox()
        let ext = ServerExtension(download: DownloadHandler(start: { _, _ in }, status: { Data() }, records: { Data() },
            load: { _ in }, unload: { _ in },
            delete: { id in await box.set(id) },
            memoryWarning: {}), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        var dreq = URLRequest(url: await url(s, "/x/models/mlx-community%2FQwen2.5-7B-4bit")); dreq.httpMethod = "DELETE"
        let (dd, dr) = try await c.data(for: dreq)
        XCTAssertEqual((dr as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: dd, as: UTF8.self).contains("deleted"))
        let captured = await box.get()
        XCTAssertEqual(captured, "mlx-community/Qwen2.5-7B-4bit")
    }

    func testWrongTypedRepoGives400WithDecodeReason() async throws {
        let ext = ServerExtension(download: DownloadHandler(start: { _, _ in }, status: { Data() }, records: { Data() }, load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        var req = URLRequest(url: await url(s, "/x/download")); req.httpMethod = "POST"
        req.httpBody = Data(#"{"repo":123}"#.utf8) // nie String
        let (bd, br) = try await c.data(for: req)
        XCTAssertEqual((br as? HTTPURLResponse)?.statusCode, 400)
        let text = String(decoding: bd, as: UTF8.self)
        XCTAssertTrue(text.contains("invalid_request_error"))
        XCTAssertTrue(text.contains("repo")) // komunikat wskazuje winne pole
    }
}
