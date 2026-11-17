import Darwin
import Foundation

public struct HangerStateFile {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var file: URL {
        directory.appendingPathComponent("device-state.json")
    }

    public func read() throws -> HangerState {
        do {
            return try JSONDecoder().decode(HangerState.self, from: Data(contentsOf: file))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError {
            return HangerState()
        }
    }

    public func write(_ state: HangerState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard (try? Data(contentsOf: file)) != data else { return }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

public final class HangerProcessLock {
    private let descriptor: Int32

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let lockFile = directory.appendingPathComponent("instance.lock")
        let descriptor = Darwin.open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw reason
        }
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }
}
