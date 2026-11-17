import Foundation

final class CodexStopLogs {
    private struct TurnKey: Hashable {
        var threadID: String
        var turnID: String
    }

    private struct Lookup {
        var found: Bool
        var retryAfter: Date
    }

    private let directory: URL
    private var recentLookups: [TurnKey: Lookup] = [:]
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    init(directory: URL) {
        self.directory = directory
    }

    func confirmsUserStop(threadID: String, turnID: String, completedAt: Date, now: Date) -> Bool {
        let key = TurnKey(threadID: threadID, turnID: turnID)
        if let lookup = recentLookups[key], lookup.retryAfter > now { return lookup.found }

        let found = containsUserStop(key, at: completedAt)
        // The log and history projection may be committed in either order.
        let retry = found || now.timeIntervalSince(completedAt) > 60 ? Date.distantFuture : now.addingTimeInterval(4)
        if recentLookups.count >= 256 { recentLookups.removeAll() }
        recentLookups[key] = Lookup(found: found, retryAfter: retry)
        return found
    }

    private func containsUserStop(_ turn: TurnKey, at date: Date) -> Bool {
        let signature = Data(
            (" info [host-app-server-manager] Sending turn interrupt callSite=interruptConversationSelf hostId=local"
             + " reason=user-stop threadId=\(turn.threadID) turnId=\(turn.turnID)").utf8
        )
        // Search both sides of a midnight rotation without enumerating all logs.
        let days = Set([-3_600.0, 0, 3_600.0].map { dayFormatter.string(from: date.addingTimeInterval($0)) })
        for day in days {
            let dailyLogs = (try? FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent(day), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for log in dailyLogs where log.pathExtension == "log" {
                guard let properties = try? log.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      properties.isRegularFile == true,
                      let size = properties.fileSize, size <= 16 * 1024 * 1024,
                      let data = try? Data(contentsOf: log, options: .mappedIfSafe) else { continue }
                var start = data.startIndex
                while start < data.endIndex,
                      let range = data.range(of: signature, in: start..<data.endIndex) {
                    // An exact end boundary prevents one turn ID from matching a longer ID.
                    let endOfLine = range.upperBound == data.endIndex || data[range.upperBound] == 10
                        || data[range.upperBound] == 13
                    if endOfLine, hasTimestamp(before: range.lowerBound, in: data) { return true }
                    start = range.upperBound
                }
            }
        }
        return false
    }

    private func hasTimestamp(before index: Int, in data: Data) -> Bool {
        let start = index - 24
        // The verified Desktop logger emits UTC timestamps with milliseconds.
        guard start >= data.startIndex, start == data.startIndex || data[start - 1] == 10 else { return false }
        let punctuation: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 58, 16: 58, 19: 46, 23: 90]
        return data[start..<index].enumerated().allSatisfy { offset, byte in
            if let expected = punctuation[offset] { return byte == expected }
            return (48...57).contains(byte)
        }
    }
}
