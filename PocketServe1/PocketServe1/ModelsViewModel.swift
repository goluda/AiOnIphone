import SwiftUI
import Combine
import UIKit
import ModelKit
import OpenAICompat

struct MLXLoading: ModelLoading {
    func load(_ record: ModelRecord) async throws {
        let folder = ModelKitPaths.modelsRoot.appendingPathComponent(RepoValidator.safeDirName(record.repo))
        try await MLXEngine.shared.loadRecord(record.repo, revision: record.revision, folder: folder)
    }
    func unload() async { await MLXEngine.shared.unloadNow() }
    var loadedId: String? { MLXEngine.loadedId }
}

@MainActor final class ModelsViewModel: ObservableObject {
    @Published var records: [ModelRecord] = []
    @Published var status = DownloadStatus(state: .idle, repo: nil, bytesDone: 0, bytesTotal: 0)
    @Published var alert: String?
    @Published var repoInput = ""
    @Published var memoryWarning = false
    let store: ModelStore
    let coordinator: DownloadCoordinator
    private var poll: Timer?
    private var memObs: NSObjectProtocol?

    init(serverModel: ServerModel) {
        let root = ModelKitPaths.documentsRoot
        store = ModelStore(root: root)
        let dl = HFDownloader(store: store, client: HFClient(session: .shared), session: .shared, root: root)
        coordinator = DownloadCoordinator(downloader: dl, store: store, loader: MLXLoading())
        serverModel.attach(extension: Self.makeExtension(coordinator: coordinator))
        memObs = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.memoryWarning = true
                await self.coordinator.notifyMemoryWarning()
                await self.refresh()
            }
        }
    }
    deinit { if let memObs { NotificationCenter.default.removeObserver(memObs) } }

    enum Op { case start, load, unload, delete }
    // HTTPServer rozumie wyłącznie ServerAPIError — mostek per-op (spec §5):
    // delete: notLoaded→modelLoaded; unload: notLoaded→model_not_loaded; reszta wspólna.
    nonisolated static func bridge(_ e: DownloadAPIError, op: Op) -> ServerAPIError {
        switch e {
        case .invalidRequest(let m): return .invalidRequest(m)
        case .downloadInProgress: return .downloadInProgress
        case .notReady: return .notReady
        case .notFound: return op == .delete ? .notFound : .invalidRequest("model nie znaleziony") // I-3 spec §5: delete→404; load/unload→400
        case .memoryPressure: return .memoryPressure
        case .downloadFailed(let m): return .failed(m)
        case .http(let c): return .failed("http \(c)")
        case .io(let m): return .failed(m)
        case .notLoaded: return op == .delete ? .modelLoaded : .notLoaded
        }
    }

    static func makeExtension(coordinator: DownloadCoordinator) -> ServerExtension {
        ServerExtension(download: DownloadHandler(
            start: { repo, rev in
                do { try await coordinator.start(repo: repo, revision: rev) }
                catch let e as DownloadAPIError { throw bridge(e, op: .start) }
            },
            status: { try ModelJSON.encoder.encode(await coordinator.currentStatus()) },
            records: { try ModelJSON.encoder.encode(await coordinator.records()) },
            load: { id in
                do { try await coordinator.load(id: id) }
                catch let e as DownloadAPIError { throw bridge(e, op: .load) }
            },
            unload: { id in
                do { try await coordinator.unload(id: id) }
                catch let e as DownloadAPIError { throw bridge(e, op: .unload) }
            },
            delete: { id in
                do { try await coordinator.delete(id: id) }
                catch let e as DownloadAPIError { throw bridge(e, op: .delete) }
            },
            memoryWarning: { await coordinator.notifyMemoryWarning() }),
            // mlx na /v1/models: przez MLXEngine.listedModel (silnik w rejestrze serwera)
            extraModels: { [] })
    }
    func refresh() async { records = await store.records(); status = await coordinator.currentStatus() }
    func importRepo(repo: String? = nil) { // I-4: retry z karty failed podaje repo rekordu; fallback = repoInput
        let repo = (repo ?? repoInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { return }
        Task {
            do { try await coordinator.start(repo: repo, revision: "main") }
            catch let e as DownloadAPIError { alert = Self.humanize(e) }
            await refresh(); pollStatus()
        }
    }
    func load(_ id: String) { Task { do { try await coordinator.load(id: id) } catch let e as DownloadAPIError { alert = Self.humanize(e) }; await refresh() } }
    func unload(_ id: String) { Task { try? await coordinator.unload(id: id); await refresh() } }
    func deleteFiles(_ id: String) { Task { do { try await coordinator.delete(id: id) } catch let e as DownloadAPIError { alert = Self.humanize(e) } catch { alert = "nie można usunąć — najpierw odładuj model" }; await refresh() } }
    static func humanize(_ e: DownloadAPIError) -> String {
        switch e {
        case .invalidRequest: return "to nie jest poprawne repo mlx"
        case .memoryPressure: return "model za duży — wybierz mniejszą kwantyzację"
        case .downloadInProgress: return "pobieranie już w toku"
        case .notReady: return "pobieranie nie ukończone"
        case .notFound: return "model nie znaleziony"
        case .notLoaded: return "najpierw odładuj model"
        case .downloadFailed: return "pobieranie nie powiodło się — ponów import"
        case .http(let c): return "serwer HF odpowiedział błędem \(c)"
        case .io: return "błąd dysku"
        }
    }
    private func pollStatus() {
        guard status.state == .downloading || status.state == .verifying else { return }
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
        Task { @MainActor in guard let self else { return }
            await self.refresh()
            if self.status.state == .ready || self.status.state == .failed { self.poll?.invalidate() }
        } }
    }
}

enum ModelKitPaths {
    static var documentsRoot: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var modelsRoot: URL { documentsRoot.appendingPathComponent("models") }
}
