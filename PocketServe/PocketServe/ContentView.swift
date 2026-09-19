import SwiftUI
struct ContentView: View {
    @StateObject private var model = ServerModel()
    @Environment(\.scenePhase) private var scenePhase // Step 7: Wiring BackgroundGuard — patrz BackgroundGuard.swift
    var body: some View {
        VStack(spacing: 20) {
            Text("PocketServe").font(.largeTitle)
            Text(model.running ? "● online :\(model.port, format: .number.grouping(.never))" : "○ offline")
                .foregroundStyle(model.running ? .green : .secondary)
            Button(model.running ? "Stop" : "Start") { model.running ? model.stop() : model.start() }
                .buttonStyle(.borderedProminent)
            if model.running { Text("\(model.address):\(model.port, format: .number.grouping(.never))").font(.system(.body, design: .monospaced)).textSelection(.enabled) }
        }.padding()
        // Step 7 (brief): background-task guard — w tle utrzymuje zadanie do expiry, bez restartu żądań.
        .onChange(of: scenePhase) { _, phase in
            BackgroundGuard.shared.handle(phase, serverRunning: model.running)
        }
    }
}
