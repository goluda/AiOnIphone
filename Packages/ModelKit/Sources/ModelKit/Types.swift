import Foundation

public enum DownloadState: String, Codable, Sendable { case idle, downloading, verifying, ready, failed }

public struct DownloadStatus: Codable, Sendable, Equatable {
    public let state: DownloadState
    public let repo: String?
    public let bytesDone: Int64
    public let bytesTotal: Int64
    public let error: String?
    public init(state: DownloadState, repo: String?, bytesDone: Int64, bytesTotal: Int64, error: String? = nil) {
        self.state = state; self.repo = repo; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.error = error
    }
}

public struct ModelRecord: Codable, Sendable, Equatable {
    public let id: String
    public let repo: String
    public let revision: String
    public let quant: String?
    public let bytesOnDisk: Int64
    public let downloadedAt: Date
    public var loaded: Bool
    public var state: DownloadState
    public var error: String?
    public init(id: String, repo: String, revision: String, quant: String?, bytesOnDisk: Int64,
                downloadedAt: Date, loaded: Bool = false, state: DownloadState = .ready, error: String? = nil) {
        self.id = id; self.repo = repo; self.revision = revision; self.quant = quant
        self.bytesOnDisk = bytesOnDisk; self.downloadedAt = downloadedAt; self.loaded = loaded
        self.state = state; self.error = error
    }
}

public enum RepoValidationError: Error { case badFormat }

public enum RepoValidator {
    public static func validate(_ repo: String) throws {
        let ok = repo.range(of: #"^[\w.\-]+/[\w.\-]+$"#, options: .regularExpression) != nil
        guard ok else { throw RepoValidationError.badFormat }
    }
    public static func safeDirName(_ repo: String) -> String { repo.replacingOccurrences(of: "/", with: "_") }
}

public struct ModelJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.keyEncodingStrategy = .convertToSnakeCase; e.outputFormatting = [.sortedKeys]; return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()
}
