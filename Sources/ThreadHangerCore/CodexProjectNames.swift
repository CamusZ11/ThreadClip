import Foundation

final class CodexProjectNames {
    private struct Project {
        var name: String
        var roots: [String]
    }

    private struct FileRevision: Equatable {
        var inode: NSNumber?
        var modified: Date?
        var size: NSNumber?
    }

    private var revision: FileRevision?
    private var projects: [String: Project] = [:]
    private var assignments: [String: String] = [:]

    func refresh(from url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            revision = nil
            assignments = [:]
            projects = [:]
            return
        }
        let current = FileRevision(
            inode: attributes[.systemFileNumber] as? NSNumber,
            modified: attributes[.modificationDate] as? Date,
            size: attributes[.size] as? NSNumber
        )
        guard current != revision,
              let data = try? Data(contentsOf: url),
              let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        let projectState = state["local-projects"] as? [String: [String: Any]] ?? [:]
        projects = projectState.compactMapValues { project in
            guard let name = project["name"] as? String, !name.isEmpty else { return nil }
            let roots = (project["rootPaths"] as? [String] ?? []).compactMap(Self.canonicalPath)
            return Project(name: name, roots: roots)
        }
        let assignmentState = state["thread-project-assignments"] as? [String: [String: String]] ?? [:]
        assignments = assignmentState.compactMapValues { assignment in
            guard assignment["projectKind"] == "local" else { return nil }
            return assignment["projectId"]
        }
        revision = current
    }

    func name(threadID: String, cwd: String) -> String {
        if let id = assignments[threadID], let project = projects[id] { return project.name }
        guard let cwd = Self.canonicalPath(cwd) else { return "Unassigned" }
        let matching = projects.values.filter { project in
            project.roots.contains { cwd == $0 || cwd.hasPrefix($0 == "/" ? "/" : $0 + "/") }
        }
        if matching.count == 1, let project = matching.first { return project.name }

        let directory = URL(fileURLWithPath: cwd)
        var ancestor = directory
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                return ancestor.lastPathComponent
            }
            ancestor.deleteLastPathComponent()
        }
        return directory.lastPathComponent == "/" ? "Unassigned" : directory.lastPathComponent
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
