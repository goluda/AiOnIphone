import SwiftUI
import UIKit

/// Step 7 (brief): background-task guard.
///
/// Cel: po przejściu w `.background` podczas aktywnego streamu aplikacja
/// dostaje krótki grant (`beginBackgroundTask`) żeby dokończyć trwający
/// stream; po `.active` (lub OS expiry) task jest kończony.
/// NIE restartuje żądań — zerwany stream = endpoint pada (feature, DoD).
///
/// Grant tylko w oknie aktywnego streamu: `.background` + `serverRunning`
/// + `AFMEngine.hasActiveStream`. Stream kończy się w tle →
/// `streamDidEnd()` zwalnia grant natychmiast (nie czeka na expiry OS).
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
            guard serverRunning && AFMEngine.hasActiveStream else { return } // tylko aktywny stream = grant
            begin()
        case .active, .inactive:
            end() // foreground = grant zbędny
        @unknown default:
            end()
        }
    }

    /// Wywoływane przez AFMEngine gdy ostatni aktywny stream się skończy —
    /// grant w tle jest zbędny od zaraz.
    func streamDidEnd() {
        end()
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
