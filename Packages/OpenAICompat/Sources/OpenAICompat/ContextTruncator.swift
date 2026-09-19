public enum ContextTruncator {
    public static func truncate(messages: [ChatMessage], budgetTokens: Int)
        -> (kept: [ChatMessage], droppedTokens: Int) {
        var system = messages.filter { $0.role == "system" }
        let rest = messages.filter { $0.role != "system" }
        let sysCost = system.reduce(0) { $0 + TokenCounter.approximate($1) }
        var kept: [ChatMessage] = []
        var dropped = 0
        var cost = sysCost
        for m in rest.reversed() {
            let c = TokenCounter.approximate(m)
            if cost + c <= budgetTokens { cost += c; kept.insert(m, at: 0) }
            else { dropped += c; break } // stop scanning: keep a strict contiguous newest suffix
        }
        system.append(contentsOf: kept)
        return (system, dropped)
    }
}
