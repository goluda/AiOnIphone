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
            let quant = repo.components(separatedBy: "-").last.flatMap { $0.hasSuffix("bit") ? $0 : nil }
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
        var h = SHA256()
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
