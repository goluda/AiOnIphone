import Foundation

public enum ServerAPIError: Error {
    case invalidRequest(String), downloadInProgress, notReady, notLoaded, notFound, memoryPressure, failed(String)
    public var httpStatus: Int {
        switch self {
        case .invalidRequest: return 400
        case .downloadInProgress, .notReady, .notLoaded, .memoryPressure: return 409
        case .notFound: return 404
        case .failed: return 502
        }
    }
    public var type: String {
        switch self {
        case .invalidRequest: return "invalid_request_error"
        case .downloadInProgress: return "download_in_progress"
        case .notReady: return "model_not_ready"
        case .notLoaded: return "model_not_loaded"
        case .notFound: return "not_found"
        case .memoryPressure: return "memory_pressure"
        case .failed: return "download_failed"
        }
    }
}

public struct DownloadHandler: Sendable {
    public let start: @Sendable (String, String?) async throws -> Void
    public let status: @Sendable () async throws -> Data
    public let records: @Sendable () async throws -> Data
    public let load: @Sendable (String) async throws -> Void
    public let unload: @Sendable (String) async throws -> Void
    public let delete: @Sendable (String) async throws -> Void
    public let memoryWarning: @Sendable () async -> Void
    public init(start: @escaping @Sendable (String, String?) async throws -> Void,
                status: @escaping @Sendable () async throws -> Data,
                records: @escaping @Sendable () async throws -> Data,
                load: @escaping @Sendable (String) async throws -> Void,
                unload: @escaping @Sendable (String) async throws -> Void,
                delete: @escaping @Sendable (String) async throws -> Void,
                memoryWarning: @escaping @Sendable () async -> Void) {
        self.start = start; self.status = status; self.records = records
        self.load = load; self.unload = unload; self.delete = delete; self.memoryWarning = memoryWarning
    }
}

public struct ServerExtension: Sendable {
    public let download: DownloadHandler?
    public let extraModels: @Sendable () -> [ModelInfo]
    public init(download: DownloadHandler?, extraModels: @escaping @Sendable () -> [ModelInfo]) {
        self.download = download; self.extraModels = extraModels
    }
}
