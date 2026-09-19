import SwiftUI
import ModelKit

struct ModelsView: View {
    @StateObject var vm: ModelsViewModel
    var body: some View {
        List {
            if vm.memoryWarning {
                Text("Niska pamięć — model odładowany automatycznie")
                    .font(.caption).foregroundStyle(.white)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red, in: RoundedRectangle(cornerRadius: 8))
            }
            Section("Import z Hugging Face") {
                TextField("np. mlx-community/Qwen3-1.7B-4bit", text: $vm.repoInput)
                    .textInputAutocapitalization(.never).font(.system(.body, design: .monospaced))
                Button("Import") { vm.importRepo() }
                    .disabled(vm.status.state == .downloading || vm.status.state == .verifying)
                if vm.status.state == .downloading || vm.status.state == .verifying {
                    ProgressView(value: Double(vm.status.bytesDone), total: Double(max(1, vm.status.bytesTotal)))
                    Text("\(vm.status.state.rawValue) \(format(vm.status.bytesDone))/\(format(vm.status.bytesTotal))").font(.caption)
                }
            }
            Section("Modele") {
                if vm.records.isEmpty { Text("Brak pobranych modeli").foregroundStyle(.secondary) }
                ForEach(vm.records, id: \.id) { rec in
                    VStack(alignment: .leading) {
                        HStack { Text(rec.repo).font(.headline)
                            if rec.loaded { Text("ZAŁADOWANY").font(.caption2).foregroundStyle(.white).padding(4).background(.green, in: Capsule()) }
                            Spacer() }
                        Text("\(rec.quant ?? "?") · \(format(rec.bytesOnDisk)) · \(rec.state.rawValue)").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if rec.loaded { Button("Odładuj") { vm.unload(rec.id) } }
                            else if rec.state == .ready { Button("Wczytaj") { vm.load(rec.id) } }
                            if rec.state == .failed { Button("Ponów import") { vm.importRepo(repo: rec.repo) } }
                            Spacer()
                            Button("Usuń pliki", role: .destructive) { vm.deleteFiles(rec.id) }.disabled(rec.loaded)
                        }
                    }
                }
            }
        }
        .navigationTitle("Modele")
        .navigationSubtitle(vm.records.first(where: { $0.loaded })?.repo ?? "tylko apple-afm") // spec §6: nagłówek = załadowany model albo fallback
        .task { await vm.refresh() }
        .alert("Błąd", isPresented: .init(get: { vm.alert != nil }, set: { if !$0 { vm.alert = nil } })) { Button("OK") { vm.alert = nil } } message: { Text(vm.alert ?? "") }
    }
    private func format(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}
