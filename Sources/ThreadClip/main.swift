import AppKit
import ThreadHangerCore

@MainActor
private func runHanger() {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.camus.threadclip", isDirectory: true)
    let revealMarker = directory.appendingPathComponent("reveal-request")
    let revealName = Notification.Name("com.camus.threadclip.request-reveal")
    let distributed = DistributedNotificationCenter.default()

    do {
        let lock = try HangerProcessLock(directory: directory)
        let app = NSApplication.shared
        let runtime = HangerRuntime(stateFile: HangerStateFile(directory: directory))
        let delegate = HangerAppDelegate(runtime: runtime)
        app.setActivationPolicy(.accessory)
        app.delegate = delegate

        let revealPending: @Sendable (Notification) -> Void = { [weak delegate] _ in
            DispatchQueue.main.async {
                guard FileManager.default.fileExists(atPath: revealMarker.path),
                      delegate?.revealFromRunningInstance() == true else { return }
                try? FileManager.default.removeItem(at: revealMarker)
            }
        }
        let launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: app, queue: .main, using: revealPending
        )
        let remoteObserver = distributed.addObserver(
            forName: revealName, object: nil, queue: .main, using: revealPending
        )
        defer {
            NotificationCenter.default.removeObserver(launchObserver)
            distributed.removeObserver(remoteObserver)
        }
        withExtendedLifetime((lock, delegate)) { app.run() }
    } catch let error as POSIXError where error.code == .EWOULDBLOCK {
        // Launch Services can start another path with the same bundle ID.
        // Deliver the reveal request to the process that owns the shared state.
        if ProcessInfo.processInfo.arguments.contains("--reveal") {
            do {
                try Data().write(to: revealMarker, options: .atomic)
                distributed.postNotificationName(revealName, object: nil, userInfo: nil, deliverImmediately: true)
            } catch {
                fputs("ThreadClip could not contact its running instance.\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
    } catch {
        fputs("ThreadClip could not initialize its local device state.\n", stderr)
        exit(EXIT_FAILURE)
    }
}

MainActor.assumeIsolated { runHanger() }
