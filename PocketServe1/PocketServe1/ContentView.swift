import SwiftUI
struct ContentView: View {
    @StateObject private var model = ServerModel()
    @Environment(\.scenePhase) private var scenePhase // Step 7: BackgroundGuard wiring — see BackgroundGuard.swift
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("PocketServe").font(.largeTitle)
                Text(model.running ? "● online :\(model.port, format: .number.grouping(.never))" : "○ offline")
                    .foregroundStyle(model.running ? .green : .secondary)
                Button(model.running ? "Stop" : "Start") { model.running ? model.stop() : model.start() }
                    .buttonStyle(.borderedProminent)
                if model.running { Text("\(model.address):\(model.port, format: .number.grouping(.never))").font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                NavigationLink("Models") { ModelsView(vm: model.viewModel) }
                NavigationLink("API") { EndpointsView(model: model) }
                NavigationLink("Chat") { ChatView(model: model) }
                if model.running { RequestLogView() }
            }.padding()
        }
        .task { _ = model.viewModel } // VM pre-creation off the "Models" tap path
        // Step 7 (brief): background-task guard — keeps a task alive in background until expiry, no request restarts.
        .onChange(of: scenePhase) { _, phase in
            BackgroundGuard.shared.handle(phase, serverRunning: model.running)
        }
    }
}
