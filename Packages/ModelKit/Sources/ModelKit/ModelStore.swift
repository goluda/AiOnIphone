import Foundation

public actor ModelStore {
    public enum Guard: Equatable, Sendable { case ok, tooBig(bytes: Int64), notReady, unknown }
    public enum StoreError: Error, Sendable { case notFound, loaded, io(String) }

    private let root: URL
    private let loadGuardBytes: Int64
    private var recordsById: [String: ModelRecord] = [:]

    public init(root: URL, loadGuardBytes: Int64 = 6_000_000_000) {
        self.root = root; self.loadGuardBytes = loadGuardBytes
        if let data = try? Data(contentsOf: root.appendingPathComponent("Models.json")),
           let rs = try? ModelJSON.decoder.decode([ModelRecord].self, from: data) {
            for r in rs { var r = r; r.loaded = false; recordsById[r.id] = r } // restart: nic załadowanego
        }
    }

    public func records() -> [ModelRecord] { Array(recordsById.values).sorted { $0.downloadedAt < $1.downloadedAt } }

    public func upsert(_ record: ModelRecord) { recordsById[record.id] = record; persist() }

    public func setLoaded(_ id: String, _ loaded: Bool) {
        guard var r = recordsById[id] else { return }; r.loaded = loaded; recordsById[id] = r; persist()
    }

    public func canLoad(_ id: String) -> Guard {
        guard let r = recordsById[id] else { return .unknown }
        guard r.state == .ready else { return .notReady }
        guard r.bytesOnDisk <= loadGuardBytes else { return .tooBig(bytes: r.bytesOnDisk) }
        return .ok
    }

    public func delete(_ id: String) throws {
        guard let r = recordsById[id] else { throw StoreError.notFound }
        guard !r.loaded else { throw StoreError.loaded }
        let dir = root.appendingPathComponent("models").appendingPathComponent(RepoValidator.safeDirName(r.repo))
        try? FileManager.default.removeItem(at: dir)
        recordsById[id] = nil
        persist()
    }

    public func bytesFree() -> Int64 {
        ((try? FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize]) as? Int64) ?? 0
    }

    private func persist() {
        let url = root.appendingPathComponent("Models.json")
        do {
            let data = try ModelJSON.encoder.encode(recordsById.values.sorted { $0.id < $1.id })
            try data.write(to: url, options: .atomic)
        } catch { /* log; UI pokaże pusty katalog */ }
    }
}
