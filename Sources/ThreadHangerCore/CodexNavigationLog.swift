import Foundation

/// Observes the installed Desktop's renderer route and matching App Server response.
/// LaunchServices accepting a URL, by itself, does not stand for a rendered thread.
public struct CodexNavigationLog: Sendable {
    private struct Route {
        let at: Date
        let window: String
        let renderer: String
        let threadID: UUID?
        let hostID: String?
    }

    private struct Reply {
        let at: Date
        let loadsThread: Bool
        let succeeded: Bool
        let renderer: String?
    }

    private let directory: URL

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/com.openai.codex")) {
        self.directory = directory
    }

    public func confirmsRoute(
        threadID: String, hostID: String? = nil, processID: Int32, processStartedAt: Date,
        requestedAt: Date, now: Date, allowExistingRoute: Bool
    ) -> Bool {
        guard let target = UUID(uuidString: threadID) else { return false }
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var routes: [Route] = []
        var rejected: [Route] = []
        var replies: [Reply] = []

        for log in recentLogs(for: processID, at: now) {
            for line in lines(in: log) {
                let payload = line.dropFirst(24).split(maxSplits: 1, whereSeparator: \.isWhitespace).last ?? ""
                let isRoute = payload.hasPrefix("[electron-message-handler] IAB_LIFECYCLE received browser sidebar owner sync ")
                let isRejected = payload.hasPrefix("[electron-message-handler] IAB_LIFECYCLE ignored browser sidebar owner sync from auxiliary window ")
                let isReply = payload.hasPrefix("[AppServerConnection] response_routed ")
                guard isRoute || isRejected || isReply,
                      let at = timestamp.date(from: String(line.prefix(24))),
                      at >= processStartedAt, at <= now else { continue }

                if isRoute || isRejected {
                    guard let window = value("windowId", in: line), Int(window) != nil,
                          let renderer = value("originWebContentsId", in: line), Int(renderer) != nil else { continue }
                    let target = threadAddress(in: line)
                    let route = Route(
                        at: at, window: window, renderer: renderer,
                        threadID: target?.threadID, hostID: target?.hostID
                    )
                    if isRejected { rejected.append(route) } else { routes.append(route) }
                } else {
                    guard let id = value("conversationId", in: line), UUID(uuidString: id) == target,
                          let method = value("method", in: line),
                          ["thread/read", "thread/resume", "thread/queue/list"].contains(method),
                          value("hadPending", in: line) == "true",
                          let error = value("errorCode", in: line) else { continue }
                    let renderer = value("originWebcontentsId", in: line).flatMap { Int($0) == nil ? nil : $0 }
                    replies.append(Reply(
                        at: at, loadsThread: method != "thread/queue/list", succeeded: error == "null", renderer: renderer
                    ))
                }
            }
        }

        routes.removeAll { route in
            rejected.contains {
                $0.window == route.window && $0.renderer == route.renderer
                    && $0.at >= route.at && $0.at.timeIntervalSince(route.at) <= 0.15
            }
        }
        routes.sort { $0.at < $1.at }
        guard let route = routes.last, route.threadID == target, route.hostID == hostID,
              now.timeIntervalSince(route.at) >= 0.15,
              Set(routes.map(\.window)).count == 1 else { return false }

        if hostID != nil {
            replies.removeAll { $0.renderer != nil && $0.renderer != route.renderer }
        }
        if route.at >= requestedAt, confirmsLoad(replies, since: requestedAt, requiresThreadLoad: hostID != nil) {
            return true
        }

        // Opening the already visible thread can be a no-op or repeat the same renderer sync.
        guard allowExistingRoute, now.timeIntervalSince(route.at) < 2 * 60 * 60 else { return false }
        let previousRoute = routes.last { $0.threadID != target || $0.hostID != hostID }
        guard let firstMatch = routes.first(where: { $0.at > (previousRoute?.at ?? .distantPast) }),
              firstMatch.at < requestedAt else { return false }
        return confirmsLoad(replies, since: firstMatch.at, requiresThreadLoad: hostID != nil)
    }

    private func confirmsLoad(_ replies: [Reply], since: Date, requiresThreadLoad: Bool) -> Bool {
        let relevant = replies.filter { $0.at >= since }
        let latestThreadLoad = relevant.filter(\.loadsThread).max(by: { $0.at < $1.at })?.succeeded
        if latestThreadLoad == false || (requiresThreadLoad && latestThreadLoad != true) {
            return false
        }
        return relevant.max(by: { $0.at < $1.at })?.succeeded == true
    }

    private func recentLogs(for processID: Int32, at now: Date) -> [URL] {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy/MM/dd"
        let dates = [now, now.addingTimeInterval(-24 * 60 * 60)]
        let files = dates.flatMap { date in
            (try? FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent(day.string(from: date)),
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        return files.compactMap { url -> (URL, Date)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("codex-desktop-"), url.pathExtension == "log",
                  name.contains("-\(processID)-t0-i"),
                  let properties = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  properties.isRegularFile == true,
                  let updatedAt = properties.contentModificationDate else { return nil }
            return (url, updatedAt)
        }.sorted { $0.1 > $1.1 }.prefix(4).map(\.0)
    }

    private func lines(in log: URL) -> [Substring] {
        guard let file = try? FileHandle(forReadingFrom: log) else { return [] }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return [] }
        let limit: UInt64 = 768 * 1024
        let start = size > limit ? size - limit : 0
        guard (try? file.seek(toOffset: start)) != nil,
              let bytes = try? file.read(upToCount: Int(limit)), !bytes.isEmpty else { return [] }
        let parts = String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        return Array(parts.dropFirst(start > 0 ? 1 : 0).dropLast())
    }

    private func value(_ name: String, in line: Substring) -> String? {
        guard let range = line.range(of: " \(name)=") else { return nil }
        return line[range.upperBound...].split(maxSplits: 1, whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private func threadAddress(in line: Substring) -> (threadID: UUID, hostID: String?)? {
        guard let path = value("ownerRoutePath", in: line),
              let components = URLComponents(string: path), components.scheme == nil, components.host == nil,
              components.path.hasPrefix("/local/"),
              let threadID = UUID(uuidString: String(components.path.dropFirst("/local/".count))) else { return nil }
        let hosts = components.queryItems?.filter { $0.name == "hostId" } ?? []
        guard !hosts.isEmpty else { return (threadID, nil) }
        guard hosts.count == 1, let hostID = hosts.first?.value, !hostID.isEmpty else { return nil }
        return (threadID, hostID == "local" ? nil : hostID)
    }
}
