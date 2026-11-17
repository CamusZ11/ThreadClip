import Darwin
import Foundation

struct CodexRemoteFrames {
    private enum FramingError: Error { case invalidLength }

    private static let maximumFrameLength = 32 * 1024 * 1024
    private var buffer = Data()

    mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 4 {
            let header = buffer[offset..<(offset + 4)]
            let length = header.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
            guard (1...Self.maximumFrameLength).contains(length) else { throw FramingError.invalidLength }
            guard buffer.endIndex - offset - 4 >= length else { break }
            frames.append(buffer[(offset + 4)..<(offset + 4 + length)])
            offset += 4 + length
        }
        if offset != buffer.startIndex { buffer = Data(buffer[offset...]) }
        return frames
    }

    static func encode(_ message: [String: Any]) -> Data? {
        guard let payload = try? JSONSerialization.data(withJSONObject: message),
              payload.count <= maximumFrameLength else { return nil }
        var length = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }
}

/// Locally mirrors status metadata for the Remote conversations already followed by Codex Desktop.
public final class CodexRemoteFeed: @unchecked Sendable {
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock").path
    }

    private let path: String
    private let queue = DispatchQueue(label: "flowcontext.thread-hanger.remote")
    private let cacheLock = NSLock()
    private var cachedThreads: [CodexRemoteThread] = []

    // Transport and protocol state is accessed only on queue.
    private var enabled = false
    private var generation = 0
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var frames = CodexRemoteFrames()
    private var stream = CodexRemoteStream()
    private var completionDeadline: DispatchTime?
    private var initializeID: String?
    private var clientID: String?

    public init(socketPath: String = CodexRemoteFeed.defaultSocketPath) { path = socketPath }

    deinit { readSource?.cancel() }

    /// Returns the last published snapshot immediately and starts the feed if necessary.
    public func threads() -> [CodexRemoteThread] {
        queue.async { [weak self] in
            guard let self, !self.enabled else { return }
            self.enabled = true
            self.connectIfEnabled()
        }
        return cacheLock.withLock { cachedThreads }
    }

    public func stop() {
        queue.sync {
            enabled = false
            disconnect()
        }
    }

    private func connectIfEnabled() {
        guard enabled, socketFD == -1 else { return }
        guard let fd = Self.openSocket(path) else {
            reconnect()
            return
        }

        socketFD = fd
        generation += 1
        let connection = generation
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in
            guard let self, self.generation == connection else { return }
            self.readFrames()
        }
        reader.setCancelHandler { Darwin.close(fd) }
        readSource = reader
        reader.resume()

        let requestID = UUID().uuidString
        initializeID = requestID
        guard send(["type": "request", "method": "initialize", "version": 0,
                    "sourceClientId": "", "requestId": requestID,
                    "params": ["clientType": "flowcontext-thread-hanger"]]) else {
            disconnectAndReconnect()
            return
        }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.generation == connection, self.clientID == nil else { return }
            self.disconnectAndReconnect()
        }
    }

    private func readFrames() {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        // Yield to stop and reconnect after each bounded batch of available input.
        for _ in 0..<4 {
            let count = bytes.withUnsafeMutableBytes { Darwin.recv(socketFD, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
            }
            guard count > 0,
                  let messages = try? frames.append(Data(bytes.prefix(count))) else {
                disconnectAndReconnect()
                return
            }
            for message in messages {
                guard let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any] else {
                    continue
                }
                if !consume(object) {
                    disconnectAndReconnect()
                    return
                }
            }
            if !messages.isEmpty { publish() }
        }
    }

    private func consume(_ message: [String: Any]) -> Bool {
        if let clientID {
            return stream.consume(message, clientID: clientID).allSatisfy { send($0.message(clientID: clientID)) }
        }
        guard message["type"] as? String == "response",
              message["requestId"] as? String == initializeID else { return true }
        guard let result = message["result"] as? [String: Any], let assignedID = result["clientId"] as? String,
              !assignedID.isEmpty, assignedID.utf8.count <= 256 else { return false }
        clientID = assignedID
        initializeID = nil
        return true
    }

    private func publish() {
        stream.expireCompletions()
        let threads = stream.threads
        cacheLock.withLock { cachedThreads = threads }
        let nextDeadline = stream.nextCompletionDeadline
        guard nextDeadline != completionDeadline else { return }
        completionDeadline = nextDeadline
        if let nextDeadline {
            queue.asyncAfter(deadline: nextDeadline) { [weak self] in
                guard let self, self.completionDeadline == nextDeadline else { return }
                self.publish()
            }
        }
    }

    private func disconnectAndReconnect() {
        disconnect()
        reconnect()
    }

    private func disconnect() {
        generation += 1
        let removals = stream.stopFollowing()
        if socketFD != -1 {
            if let clientID {
                for removal in removals {
                    guard send(removal.message(clientID: clientID)) else { break }
                }
            }
            Darwin.shutdown(socketFD, SHUT_RDWR)
        }
        readSource?.cancel()
        readSource = nil
        socketFD = -1
        frames = CodexRemoteFrames()
        stream = CodexRemoteStream()
        clientID = nil
        initializeID = nil
        publish()
    }

    private func reconnect() {
        let attempt = generation
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.generation == attempt else { return }
            self.connectIfEnabled()
        }
    }

    private func send(_ message: [String: Any]) -> Bool {
        guard let frame = CodexRemoteFrames.encode(message) else { return false }
        return frame.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(socketFD, bytes.baseAddress?.advanced(by: sent), bytes.count - sent, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private static func openSocket(_ path: String) -> Int32? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard !path.isEmpty, !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: address.sun_path)
        else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(bytes.count + 2)
        withUnsafeMutableBytes(of: &address.sun_path) { pathBytes in
            bytes.withUnsafeBytes { pathBytes.copyBytes(from: $0) }
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSignal: Int32 = 1
        guard Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC) != -1,
              Darwin.fcntl(fd, F_SETFL, O_NONBLOCK) != -1,
              Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            Darwin.close(fd)
            return nil
        }
        let addressLength = socklen_t(address.sun_len)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength) == 0
            }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard connected, Darwin.getpeereid(fd, &uid, &gid) == 0, uid == Darwin.geteuid() else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }
}
