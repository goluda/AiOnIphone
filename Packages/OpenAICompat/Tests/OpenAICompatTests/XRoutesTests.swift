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
        let (_, lr) = try await c.data(for: lreq)
        XCTAssertEqual((lr as? HTTPURLResponse)?.statusCode, 409)
        var dreq = URLRequest(url: await url(s, "/x/models/mlx%3Aa%2Fb")); dreq.httpMethod = "DELETE"
        let (_, dr) = try await c.data(for: dreq)
        XCTAssertEqual((dr as? HTTPURLResponse)?.statusCode, 404)
    }

    func testXRoutesNotBusyGated() async throws {
        // busy serwer (mock stream) + /x/status -> 200 mimo 429 na /chat
        // użyj tego samego mechanizmu co concurrent 429 test: odpal stream, potem /x/download/status
        let ext = ServerExtension(download: DownloadHandler(start: { _, _ in }, status: { Data(#"{"state":"ready","bytesDone":1,"bytesTotal":1}"#.utf8) }, records: { Data() }, load: { _ in }, unload: { _ in }, delete: { _ in }, memoryWarning: {}), extraModels: { [] })
        let (s, c) = try await start(ext: ext)
        defer { Task { await s.stop() } }
        var req = URLRequest(url: await url(s, "/v1/chat/completions")); req.httpMethod = "POST"
        req.httpBody = Data(#"{"model":"mock","messages":[{"role":"user","content":"x"}],"stream":true}"#.utf8)
        let (_, br) = try await c.bytes(for: req) // stream otwarty
        _ = br
        let (sd, sr) = try await c.data(from: await url(s, "/x/download/status"))
        XCTAssertEqual((sr as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: sd, as: UTF8.self).contains("ready"))
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
}
