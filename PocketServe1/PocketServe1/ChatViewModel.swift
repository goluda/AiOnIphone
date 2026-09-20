import SwiftUI
import Combine
import OpenAICompat

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var streamingText = ""
    @Published var isStreaming = false
    @Published var availableModels: [String] = []
    @Published var selectedModel = "apple-afm"
    @Published var errorText: String?

    private let service = ChatService()
    private weak var serverModel: ServerModel?

    init(serverModel: ServerModel) { self.serverModel = serverModel }

    func refreshModels() async {
        guard let sm = serverModel, sm.running else { return }
        do {
            availableModels = try await service.models(port: sm.port)
            if !availableModels.contains(selectedModel), let first = availableModels.first { selectedModel = first }
        } catch { /* server off — placeholder UI covers the state */ }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, let sm = serverModel, sm.running else { return }
        let port = sm.port
        draft = ""
        messages.append(ChatMessage(role: "user", content: text))
        errorText = nil
        streamingText = ""
        isStreaming = true
        let history = messages
        let model = selectedModel
        Task {
            do {
                let req = ChatCompletionRequest(model: model, messages: history, stream: true)
                for try await token in service.stream(port: port, request: req) { streamingText += token }
                messages.append(ChatMessage(role: "assistant", content: streamingText))
            } catch let e as ChatServiceError {
                errorText = e.userMessage
                if !streamingText.isEmpty { messages.append(ChatMessage(role: "assistant", content: streamingText)) }
            } catch { errorText = "\(error)" }
            streamingText = ""
            isStreaming = false
        }
    }

    func stop() { service.stop() }
}
