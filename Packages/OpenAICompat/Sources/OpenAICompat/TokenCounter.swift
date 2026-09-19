public enum TokenCounter {
    public static func approximate(_ text: String) -> Int { max(1, text.count / 4) }
    public static func approximate(_ message: ChatMessage) -> Int {
        approximate(message.role) + approximate(message.content) + 4 // framing <|role|>
    }
}
