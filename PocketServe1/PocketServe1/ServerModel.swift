import Foundation
import OpenAICompat
import SwiftUI
import Combine

@MainActor final class ServerModel: NSObject, ObservableObject { // NSObject: wymóg NetServiceDelegate (NSObjectProtocol)
    @Published var running = false
    @Published var port: UInt16 = 8080
    @Published var address = "—"
    private var server: HTTPServer
    private var ext: ServerExtension?
    private var netService: NetService?
    private(set) lazy var viewModel = ModelsViewModel(serverModel: self) // init VM woła attach — oficjalny kanał montażu

    override init() { server = HTTPServer(engines: [AFMEngine(), MLXEngine.shared]) }

    func attach(extension: ServerExtension) {
        ext = `extension`
        let old = server // wymiana synchroniczna → start() widzi już serwer z ext
        server = HTTPServer(engines: [AFMEngine(), MLXEngine.shared], extension: `extension`)
        guard running else { return }
        let oldPort = port
        Task { [weak self] in
            guard let self else { return }
            await old.stop()
            do { self.port = try await self.server.start(port: oldPort) } catch { self.running = false }
        }
    }

    func start() {
        _ = viewModel // montuj /x/* zanim server.start()
        _ = Task { do { port = try await server.start(port: 8080); address = Self.localIPAddress() ?? "brak LAN"; running = true; publishBonjour() } } // brief: błąd ignorowany jawnie
    }
    func stop() { netService?.stop(); Task { await server.stop() }; running = false }
    private func publishBonjour() {
        let name = ProcessInfo.processInfo.hostName.components(separatedBy: ".local").first ?? "pocketserve"
        let svc = NetService(domain: "local.", type: "_oai._tcp.", name: name, port: Int32(port)) // SDK Xcode 27: port: Int32
        svc.delegate = self
        netService = svc
        svc.publish()
    }

    static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr?.pointee,
                  sa.sa_family == UInt8(AF_INET),
                  String(cString: ptr.pointee.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }
}

extension ServerModel: NetServiceDelegate {
    nonisolated func netServiceDidPublish(_ sender: NetService) {} // klient macOS: NWBrowser("_oai._tcp.") w Phase 3
}
