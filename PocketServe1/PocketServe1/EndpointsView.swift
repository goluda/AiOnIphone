import SwiftUI

struct EndpointsView: View {
    @ObservedObject var model: ServerModel

    private struct Row: Identifiable { let id = UUID(); let method: String; let path: String; let desc: String }
    private let inferenceRows: [Row] = [
        .init(method: "GET", path: "/health", desc: "server health"),
        .init(method: "GET", path: "/v1/models", desc: "model list"),
        .init(method: "POST", path: "/v1/chat/completions", desc: "OpenAI shape — stream + JSON"),
        .init(method: "POST", path: "/v1/messages", desc: "Anthropic shape — stream + JSON"),
    ]
    private let mgmtRows: [Row] = [
        .init(method: "GET", path: "/x/models", desc: "list + model states"),
        .init(method: "POST", path: "/x/download", desc: "import from Hugging Face"),
        .init(method: "GET", path: "/x/download/status", desc: "download progress"),
        .init(method: "POST", path: "/x/models/load", desc: "load engine"),
        .init(method: "POST", path: "/x/models/unload", desc: "unload engine"),
        .init(method: "DELETE", path: "/x/models/{id}", desc: "delete model files"),
    ]

    var body: some View {
        List {
            Section("Base URL") {
                if model.running {
                    HStack {
                        Text("http://\(model.address):\(model.port)")
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button { UIPasteboard.general.string = "http://\(model.address):\(model.port)" } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                } else {
                    Text("server off").foregroundStyle(.secondary)
                }
            }
            Section("Inference") { rows(inferenceRows) }
            Section("Management (/x/*)") { rows(mgmtRows) }
            Section("Error codes") {
                Text("429 — server busy").font(.caption)
                Text("409 — model not loaded").font(.caption)
                Text("404 — unknown model / endpoint").font(.caption)
                Text("400 — bad request").font(.caption)
            }
        }
        .navigationTitle("API")
    }

    @ViewBuilder private func rows(_ rows: [Row]) -> some View {
        ForEach(rows) { r in
            HStack(alignment: .top) {
                Text(r.method).font(.system(.caption, design: .monospaced)).bold()
                    .padding(4).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    .frame(width: 60, alignment: .leading)
                VStack(alignment: .leading) {
                    Text(r.path).font(.system(.body, design: .monospaced))
                    Text(r.desc).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
