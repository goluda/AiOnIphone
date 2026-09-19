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
    private var loadSlotBusy = false

    public init(downloader: HFDownloader?, store: ModelStore, loader: ModelLoading) {
        self.downloader = downloader; self.store = store; self.loader = loader
    }

    public func start(repo: String, revision: String?) async throws {
        guard let dl = downloader else { throw DownloadAPIError.invalidRequest("no downloader") }
        do { try await dl.start(repo: repo, revision: revision ?? "main") }
        catch let e as HFDownloaderError {
            switch e {
            case .inProgress: throw DownloadAPIError.downloadInProgress
            // M-2: alreadyReady = sukces idempotentny — pliki już gotowe, NIE pobieramy ponownie,
            // status zostaje .ready, endpoint odpowiada normalnie (202).
            case .alreadyReady: return
            case .notMLX: throw DownloadAPIError.invalidRequest("repo bez plików mlx")
            case .http(let c): throw DownloadAPIError.http(c)
            case .checksum(let f): throw DownloadAPIError.downloadFailed("checksum \(f)")
            }
        }
        catch RepoValidationError.badFormat { throw DownloadAPIError.invalidRequest("repo: \(repo)") }
        catch let e as URLError { throw DownloadAPIError.downloadFailed(e.localizedDescription) }
    }

    public func currentStatus() async -> DownloadStatus {
        await downloader?.currentStatus() ?? DownloadStatus(state: .idle, repo: nil, bytesDone: 0, bytesTotal: 0)
    }

    public func records() async -> [ModelRecord] { await store.records() }

    public func load(id: String) async throws {
        guard !loadSlotBusy else { throw DownloadAPIError.downloadInProgress }
        loadSlotBusy = true
        defer { loadSlotBusy = false }
        switch await store.canLoad(id) {
        case .unknown: throw DownloadAPIError.notFound
        case .notReady: throw DownloadAPIError.notReady
        case .tooBig: throw DownloadAPIError.memoryPressure
        case .ok: break
        }
        guard let rec = (await store.records()).first(where: { $0.id == id }) else { throw DownloadAPIError.notFound }
        try await loader.load(rec)
        await store.setLoaded(id, true)
        for r in await store.records() where r.id != id && r.loaded { await store.setLoaded(r.id, false) }
    }

    public func unload(id: String) async throws {
        guard let rec = (await store.records()).first(where: { $0.id == id }) else { throw DownloadAPIError.notFound }
        guard rec.loaded else { throw DownloadAPIError.notLoaded }
        await loader.unload()
        await store.setLoaded(id, false)
    }

    public func delete(id: String) async throws {
        guard !loadSlotBusy else { throw DownloadAPIError.downloadInProgress }
        loadSlotBusy = true
        defer { loadSlotBusy = false }
        guard let rec = (await store.records()).first(where: { $0.id == id }) else { throw DownloadAPIError.notFound }
        guard !rec.loaded else { throw DownloadAPIError.notLoaded }
        let dir = store.root.appendingPathComponent("models").appendingPathComponent(RepoValidator.safeDirName(rec.repo))
        if FileManager.default.fileExists(atPath: dir.path) {
            do { try FileManager.default.removeItem(at: dir) }
            catch { throw DownloadAPIError.io("\(id): \(error.localizedDescription)") }
        }
        do { try await store.delete(id) }
        catch ModelStore.StoreError.notFound { throw DownloadAPIError.notFound }
        catch ModelStore.StoreError.loaded { throw DownloadAPIError.notLoaded }
        catch ModelStore.StoreError.io(let m) { throw DownloadAPIError.io(m) }
    }

    public func notifyMemoryWarning() async {
        if let lid = await loader.loadedId { await loader.unload(); await store.setLoaded(lid, false) }
    }
}
