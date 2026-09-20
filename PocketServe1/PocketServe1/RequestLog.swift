import Foundation
import SwiftUI
import OpenAICompat

@MainActor
final class RequestLog: ObservableObject {
    static let shared = RequestLog()
    @Published private(set) var events: [RequestEvent] = []
    private init() {}
    func record(_ e: RequestEvent) {
        events.append(e)
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
    func clear() { events = [] }
}

extension RequestEvent {
    var timeLabel: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: timestamp)
    }
    var statusColor: Color {
        if (200..<300).contains(status) { return .green }
        if (400..<500).contains(status) { return .orange }
        return .red
    }
}

struct RequestLogView: View {
    @ObservedObject private var log: RequestLog
    init() { _log = ObservedObject(wrappedValue: .shared) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Requests").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                if !log.events.isEmpty { Button("Clear") { log.clear() }.font(.caption) }
            }
            if log.events.isEmpty {
                Text("Waiting for requests…").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(log.events.suffix(8).enumerated()), id: \.offset) { _, e in
                    HStack(spacing: 6) {
                        Text(e.timeLabel).foregroundStyle(.secondary)
                        Text(e.method).bold()
                        Text(e.path).lineLimit(1)
                        Spacer()
                        Text("\(e.status)").foregroundStyle(e.statusColor)
                        Text("\(e.durationMs)ms").foregroundStyle(.secondary)
                    }.font(.system(.caption2, design: .monospaced))
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }
}
