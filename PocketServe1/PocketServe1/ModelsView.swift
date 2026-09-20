import SwiftUI
import ModelKit

struct ModelsView: View {
    @StateObject var vm: ModelsViewModel
    var body: some View {
        List {
            if vm.memoryWarning {
                Text("Low memory — model unloaded automatically")
                    .font(.caption).foregroundStyle(.white)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red, in: RoundedRectangle(cornerRadius: 8))
            }
            Section("Hugging Face import") {
                TextField("e.g. mlx-community/Qwen3-1.7B-4bit", text: $vm.repoInput)
                    .textInputAutocapitalization(.never).font(.system(.body, design: .monospaced))
                HStack {
                    Button("Import") { vm.importRepo() }
                    Button {
                        vm.showPresetPicker = true
                    } label: { Image(systemName: "sparkles") }
                    Spacer()
                }
                .disabled(vm.status.state == .downloading || vm.status.state == .verifying)
                if vm.status.state == .downloading || vm.status.state == .verifying {
                    ProgressView(value: Double(vm.status.bytesDone), total: Double(max(1, vm.status.bytesTotal)))
                    Text("\(vm.status.state.rawValue) \(format(vm.status.bytesDone))/\(format(vm.status.bytesTotal))").font(.caption)
                }
            }
            Section("Models") {
                if vm.records.isEmpty { Text("No models downloaded yet").foregroundStyle(.secondary) }
                ForEach(vm.records, id: \.id) { rec in
                    ModelRow(rec: rec, vm: vm)
                }
            }
        }
        .confirmationDialog("Which model to import?", isPresented: $vm.showPresetPicker, titleVisibility: .visible) {
            ForEach(ModelsViewModel.presets) { p in
                Button("\(p.name) — \(format(p.approxBytes)) · \(p.note)") { vm.pickPreset(p) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sample models from mlx-community. Sizes approximate.")
        }
        .navigationTitle("Models")
        .navigationSubtitle(vm.records.first(where: { $0.loaded })?.repo ?? "apple-afm only") // spec §6: header = loaded model or fallback
        .task { await vm.refresh() }
        .alert("Error", isPresented: .init(get: { vm.alert != nil }, set: { if !$0 { vm.alert = nil } })) { Button("OK") { vm.alert = nil } } message: { Text(vm.alert ?? "") }
    }
    private func format(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

private struct ModelRow: View {
    let rec: ModelRecord
    @ObservedObject var vm: ModelsViewModel
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(rec.repo).font(.headline)
                if vm.loadingId == rec.id { ProgressView().controlSize(.small) }
                Spacer()
                Text(chip).font(.caption2).foregroundStyle(.white)
                    .padding(4).background(chipColor, in: Capsule())
            }
            Text("\(rec.quant ?? "?") · \(fmt(rec.bytesOnDisk))").font(.caption).foregroundStyle(.secondary)
            HStack {
                if rec.loaded { Button("Unload") { vm.unload(rec.id) } }
                else if rec.state == .ready { Button(vm.loadingId == rec.id ? "Loading…" : "Load") { vm.load(rec.id) }.disabled(vm.loadingId != nil) }
                if rec.state == .failed { Button("Retry import") { vm.importRepo(repo: rec.repo) } }
                Spacer()
                Button("Delete", role: .destructive) { confirmDelete = true }
                    .disabled(vm.deletingId == rec.id || rec.loaded)
            }
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .leading) {
            if rec.loaded {
                Button("Unload") { vm.unload(rec.id) }.tint(.orange)
            } else if rec.state == .ready {
                Button(vm.loadingId == rec.id ? "Loading…" : "Load") { vm.load(rec.id) }
                    .tint(.green).disabled(vm.loadingId != nil)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { confirmDelete = true }
                .disabled(vm.deletingId == rec.id || rec.loaded)
        }
        .confirmationDialog("Delete model files?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete files", role: .destructive) { vm.deleteFiles(rec.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes downloaded files from this device. Re-import from Hugging Face anytime.")
        }
    }

    private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    private var chip: String {
        if vm.loadingId == rec.id { return "LOADING…" }
        if vm.deletingId == rec.id { return "DELETING…" }
        if rec.loaded { return "LOADED" }
        switch rec.state {
        case .ready: return "READY"
        case .downloading:
            let pct = Int((Double(vm.status.bytesDone) / Double(max(1, vm.status.bytesTotal)) * 100).rounded())
            return vm.status.repo == rec.repo ? "DOWNLOADING \(pct)%" : "QUEUED"
        case .verifying: return "VERIFYING…"
        case .failed: return "FAILED"
        case .idle: return "NOT DOWNLOADED"
        }
    }
    private var chipColor: Color {
        switch chip {
        case "LOADED": return .green
        case "FAILED": return .red
        case "READY": return .gray
        case "NOT DOWNLOADED": return .gray
        default: return .blue
        }
    }
}
