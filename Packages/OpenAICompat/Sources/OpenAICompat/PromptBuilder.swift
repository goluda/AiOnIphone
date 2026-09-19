public enum PromptBuilder {
    public static func prompt(from messages: [ChatMessage]) -> String {
        messages.map { "<|\($0.role)|>\n\($0.content)\n" }.joined()
    }
}
