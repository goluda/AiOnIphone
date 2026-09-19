import Foundation
import OpenAICompat
import SwiftUI
import Combine

@MainActor final class ServerModel: NSObject, ObservableObject { // NSObject: wymóg NetServiceDelegate (NSObjectProtocol)
    @Published var running = false
    @Published var port: UInt16 = 8080
    private let server = HTTPServer(engines: [AFMEngine()])
    private var netService: NetService?

    func start() {
        _ = Task { do { port = try await server.start(port: 8080); running = true; publishBonjour() } } // brief: błąd ignorowany jawnie
    }
    func stop() { netService?.stop(); Task { await server.stop() }; running = false }
    private func publishBonjour() {
        let name = ProcessInfo.processInfo.hostName.components(separatedBy: ".local").first ?? "pocketserve"
        let svc = NetService(domain: "local.", type: "_oai._tcp.", name: name, port: Int32(port)) // SDK Xcode 27: port: Int32
        svc.delegate = self
        netService = svc
        svc.publish()
    }
}

extension ServerModel: NetServiceDelegate {
    nonisolated func netServiceDidPublish(_ sender: NetService) {} // klient macOS: NWBrowser("_oai._tcp.") w Phase 3
}
