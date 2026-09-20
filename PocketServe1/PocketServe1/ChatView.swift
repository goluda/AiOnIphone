import SwiftUI
import OpenAICompat

struct ChatView: View {
    @ObservedObject var model: ServerModel
    @StateObject private var vm: ChatViewModel

    init(model: ServerModel) { self.model = model; _vm = StateObject(wrappedValue: ChatViewModel(serverModel: model)) }

    var body: some View {
        VStack(spacing: 0) {
            if !model.running {
                ContentUnavailableView("Server offline", systemImage: "wifi.slash",
                    description: Text("Start the server to chat."))
                    .frame(maxHeight: .infinity)
                Button("Start server") { model.start() }.buttonStyle(.borderedProminent).padding(.bottom)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(vm.messages.enumerated()), id: \.offset) { idx, m in
                                bubble(m).id(idx)
                            }
                            if vm.isStreaming {
                                Text(vm.streamingText + "▌")
                                    .padding(10).frame(maxWidth: 280, alignment: .leading)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                                    .id("streaming")
                            }
                        }.padding()
                    }
                    .onChange(of: vm.streamingText) { _, _ in proxy.scrollTo("streaming", anchor: .bottom) }
                    .onChange(of: vm.messages.count) { _, _ in
                        if vm.isStreaming { proxy.scrollTo("streaming", anchor: .bottom) }
                        else if let last = vm.messages.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                if let err = vm.errorText {
                    Text(err).font(.footnote).foregroundStyle(.white)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal)
                }
                HStack {
                    TextField("Type a message…", text: $vm.draft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { vm.send() }
                    if vm.isStreaming {
                        Button("Stop") { vm.stop() }
                    } else {
                        Button { vm.send() } label: { Image(systemName: "arrow.up.circle.fill") }
                            .font(.title2)
                            .disabled(vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.availableModels.isEmpty)
                    }
                }.padding()
            }
        }
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Model", selection: $vm.selectedModel) {
                    ForEach(vm.availableModels, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).disabled(!model.running)
            }
        }
        .task { await vm.refreshModels() }
        .onChange(of: model.running) { _, on in if on { Task { await vm.refreshModels() } } }
        .onDisappear { vm.stop() }
    }

    @ViewBuilder private func bubble(_ m: ChatMessage) -> some View {
        if m.role == "user" {
            HStack { Spacer(); Text(m.content).padding(10)
                .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 280, alignment: .trailing) }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("assistant").font(.caption2).foregroundStyle(.secondary)
                Text(m.content).textSelection(.enabled).padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 280, alignment: .leading)
            }
        }
    }
}
