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

struct ModelPreset: Identifiable {
    let repo: String
    let name: String
    let approxBytes: Int64
    let note: String
    var id: String { repo }
}

@MainActor final class ModelsViewModel: ObservableObject {
    // Presety zweryfikowane live na HF 2026-09-20 (rozmiary = suma .safetensors, ?blobs=true).
    static let presets: [ModelPreset] = [
        ModelPreset(repo: "mlx-community/Qwen3-0.6B-4bit", name: "Qwen3 0.6B 4bit", approxBytes: 335_000_000, note: "fastest start — test model"),
        ModelPreset(repo: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3 1.7B 4bit", approxBytes: 968_000_000, note: "good Polish — recommended first model"),
        ModelPreset(repo: "mlx-community/gemma-3n-E2B-it-4bit", name: "Gemma 3n E2B 4bit", approxBytes: 4_463_000_000, note: "smaller, higher quality"),
        ModelPreset(repo: "mlx-community/gemma-3n-E4B-it-4bit", name: "Gemma 3n E4B 4bit", approxBytes: 5_819_000_000, note: "largest — just under the 6 GB limit"),
    ]
    @Published var showPresetPicker = false
    @Published var records: [ModelRecord] = []
    @Published var status = DownloadStatus(state: .idle, repo: nil, bytesDone: 0, bytesTotal: 0)
    @Published var alert: String?
    @Published var repoInput = ""
    @Published var memoryWarning = false
    // in-process operacje: widoczność LOADING…/DELETING… bez dodatkowego pollingu
    @Published var loadingId: String?
    @Published var deletingId: String?
    let store: ModelStore
    let coordinator: DownloadCoordinator
    private var poll: Timer?
    private var memObs: NSObjectProtocol?

    init(serverModel: ServerModel) {
        let root = ModelKitPaths.documentsRoot
        store = ModelStore(root: root)
        // R-2: jawne timeouty — zatkany plik nie parkuje koordynatora w .downloading na zawsze
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600 // wagi ~5 GB potrzebują miejsca; stall umiera po 60 s bezczynności
        let session = URLSession(configuration: cfg)
        let dl = HFDownloader(store: store, client: HFClient(session: session), session: session, root: root)
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
        case .downloadInProgress, .loadInProgress, .deleteInProgress: return .downloadInProgress // token wire bez zmian (spec §5) — uczciwy tekst per-op tylko w humanize
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
    func pickPreset(_ p: ModelPreset) { repoInput = p.repo; showPresetPicker = false; importRepo(repo: p.repo) }
    func importRepo(repo: String? = nil) { // I-4: retry z karty failed podaje repo rekordu; fallback = repoInput
        let repo = (repo ?? repoInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { return }
        Task {
            do { try await coordinator.start(repo: repo, revision: "main") }
            catch let e as DownloadAPIError { alert = Self.humanize(e) }
            await refresh(); pollStatus()
        }
    }
    func load(_ id: String) { Task { loadingId = id
        do { try await coordinator.load(id: id) } catch let e as DownloadAPIError { alert = Self.humanize(e) }
        loadingId = nil; await refresh() } }
    func unload(_ id: String) { Task { try? await coordinator.unload(id: id); await refresh() } }
    func deleteFiles(_ id: String) { Task { deletingId = id
        do { try await coordinator.delete(id: id) }
        catch let e as DownloadAPIError { alert = Self.humanize(e) }
        catch { alert = "Delete failed" }
        deletingId = nil; await refresh() } }
    static func humanize(_ e: DownloadAPIError) -> String {
        switch e {
        case .invalidRequest: return "Not a valid mlx repo"
        case .memoryPressure: return "Model too large — pick a smaller quantization"
        case .downloadInProgress: return "Download already in progress"
        case .loadInProgress: return "Model is already loading"
        case .deleteInProgress: return "Cannot delete — another operation in progress"
        case .notReady: return "Download incomplete — resume it first"
        case .notFound: return "Model not found locally"
        case .notLoaded: return "Unload the model first"
        case .downloadFailed: return "Download failed — retry the import"
        case .http(let c): return "HF server replied with error \(c)"
        case .io: return "Disk error"
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
