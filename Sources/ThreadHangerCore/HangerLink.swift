import Foundation

public enum HangerLink {
    public static func url(for threadID: String, hostID: String? = nil) -> URL? {
        guard UUID(uuidString: threadID) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(threadID)"
        if let hostID {
            let prefix = "remote-control:"
            guard hostID.hasPrefix(prefix) else { return nil }
            let suffix = hostID.dropFirst(prefix.count)
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
            guard !suffix.isEmpty, suffix.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
            components.queryItems = [URLQueryItem(name: "hostId", value: hostID)]
        }
        return components.url
    }

    public static func shouldHide(
        card: HangerCard,
        originalCards: [HangerCard],
        currentCards: [HangerCard]
    ) -> Bool {
        let current = Set(currentCards.compactMap(\.notificationID))
        let original = Set(originalCards.compactMap(\.notificationID))
        guard current.isSubset(of: original) else { return false }
        if let notification = card.notificationID {
            return currentCards.contains { $0.identity == card.identity && $0.notificationID == notification }
        }
        return card.isRecent && currentCards.contains { $0.identity == card.identity && $0.isRecent }
    }
}
