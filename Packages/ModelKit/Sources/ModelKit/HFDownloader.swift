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
        status = DownloadStatus(state: .downloading, repo: repo, bytesDone: 0, bytesTotal: 0)
        var done: Int64 = 0
        var total: Int64 = 0
        do {
            guard await client.isMLX(repo, revision: revision) else { throw HFDownloaderError.notMLX }
            let info = try await client.fetchModelInfo(repo, revision: revision)
            let files = info.siblings.filter { $0.rFilename.hasSuffix(".safetensors") || $0.rFilename.hasSuffix(".safetensors.index.json") || $0.rFilename.hasSuffix(".json") || $0.rFilename.hasSuffix(".model.txt") || $0.rFilename.hasSuffix(".txt") }
            guard files.contains(where: { $0.rFilename.hasSuffix(".safetensors") }) else { throw HFDownloaderError.notMLX }
            let dir = root.appendingPathComponent("models").appendingPathComponent(RepoValidator.safeDirName(repo))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            total = files.compactMap(\.size).reduce(Int64(0), +)
            status = DownloadStatus(state: .downloading, repo: repo, bytesDone: 0, bytesTotal: total)
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
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int64, Error>) in
            let task = session.dataTask(with: request)
            task.delegate = Sink(part: part, cont: cont)
            task.resume()
        }
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

private final class Sink: NSObject, URLSessionDataDelegate, @unchecked Sendable { // @unchecked: callbacki serializowane na kolejce tasku
    private let part: URL
    private let cont: CheckedContinuation<Int64, Error>
    private var handle: FileHandle?
    private var buf = Data()
    private var written: Int64 = 0
    private var status = -1
    init(part: URL, cont: CheckedContinuation<Int64, Error>) { self.part = part; self.cont = cont }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                   completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 || status == 206 else { completionHandler(.cancel); return }
        do {
            if FileManager.default.fileExists(atPath: part.path) {
                let h = try FileHandle(forWritingTo: part)
                if status == 200 { h.truncateFile(atOffset: 0) } else { h.seekToEndOfFile() }
                handle = h
            } else {
                FileManager.default.createFile(atPath: part.path, contents: nil)
                handle = try FileHandle(forWritingTo: part)
            }
            completionHandler(.allow)
        } catch { completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buf.append(data)
        if buf.count >= (1 << 20) { flush() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        flush()
        try? handle?.close()
        if status != 200 && status != 206 { cont.resume(throwing: HFDownloaderError.http(status)) }
        else if let error { cont.resume(throwing: error) }
        else { cont.resume(returning: written) }
    }
    private func flush() {
        guard !buf.isEmpty else { return }
        try? handle?.write(contentsOf: buf)
        written += Int64(buf.count)
        buf.removeAll(keepingCapacity: true)
    }
}
