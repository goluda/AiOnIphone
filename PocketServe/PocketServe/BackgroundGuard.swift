import SwiftUI
import UIKit

/// Step 7 (brief): background-task guard.
///
/// Cel: po przejściu w `.background` podczas aktywnego streamu aplikacja
/// dostaje krótki grant (`beginBackgroundTask`) żeby dokończyć trwający
/// stream; po `.active` (lub OS expiry) task jest kończony.
/// NIE restartuje żądań — zerwany stream = endpoint pada (feature, DoD).
///
/// Uwaga Phase 1: obserwujemy `serverRunning`, nie pojedynczy stream
/// (HTTPServer nie eksponuje jeszcze licznika aktywnych połączeń —
/// przyszły hook). Grant w tle kończy się na expiry OS = stream
/// kończony naturalnie, bez ponownego wysłania żądania.
///
/// Wiring (ContentView): `@Environment(\.scenePhase)` + `.onChange(of: scenePhase)`
/// → `BackgroundGuard.shared.handle(phase, serverRunning: model.running)`.
@MainActor
final class BackgroundGuard {
    static let shared = BackgroundGuard()
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    func handle(_ phase: ScenePhase, serverRunning: Bool) {
        switch phase {
        case .background:
            guard serverRunning else { return } // brak serwera = brak streamu do ochrony
            begin()
        case .active, .inactive:
            end() // foreground = grant zbędny
        @unknown default:
            end()
        }
    }

    private func begin() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "PocketServeStream") { [weak self] in
            // OS expiry: kończymy task; NIE restartujemy żądań.
            Task { @MainActor in self?.end() }
        }
    }

    private func end() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }
}
