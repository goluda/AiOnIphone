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
