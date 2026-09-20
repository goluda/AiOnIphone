import SwiftUI

struct EndpointsView: View {
    @ObservedObject var model: ServerModel

    private struct Row: Identifiable { let id = UUID(); let method: String; let path: String; let desc: String }
    private let inferenceRows: [Row] = [
        .init(method: "GET", path: "/health", desc: "zdrowie serwera"),
        .init(method: "GET", path: "/v1/models", desc: "lista modeli"),
        .init(method: "POST", path: "/v1/chat/completions", desc: "OpenAI shape — stream + JSON"),
        .init(method: "POST", path: "/v1/messages", desc: "Anthropic shape — stream + JSON"),
    ]
    private let mgmtRows: [Row] = [
        .init(method: "GET", path: "/x/models", desc: "lista + stany modeli"),
        .init(method: "POST", path: "/x/download", desc: "import z Hugging Face"),
        .init(method: "GET", path: "/x/download/status", desc: "postęp pobierania"),
        .init(method: "POST", path: "/x/models/load", desc: "wczytaj silnik"),
        .init(method: "POST", path: "/x/models/unload", desc: "odładuj silnik"),
        .init(method: "DELETE", path: "/x/models/{id}", desc: "usuń pliki modelu"),
    ]

    var body: some View {
        List {
            Section("Baza URL") {
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
                    Text("serwer wyłączony").foregroundStyle(.secondary)
                }
            }
            Section("Inference") { rows(inferenceRows) }
            Section("Zarządzanie (/x/*)") { rows(mgmtRows) }
            Section("Kody błędów") {
                Text("429 — serwer zajęty (busy)").font(.caption)
                Text("409 — model nie załadowany").font(.caption)
                Text("404 — nieznany model / endpoint").font(.caption)
                Text("400 — złe zapytanie").font(.caption)
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
