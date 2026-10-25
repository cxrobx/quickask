import AppKit
import Darwin

enum DelegationMode: String, Codable, CaseIterable, Identifiable {
    case file, herdr, background
    var id: String { rawValue }
    var title: String { switch self { case .file: return "File only"; case .herdr: return "Open Claude in Herdr"; case .background: return "Background Claude" } }
    var action: String { switch self { case .file: return "Create task"; case .herdr: return "Create task and open Claude"; case .background: return "Create task and start background agent" } }
}

struct DelegationProposal: Identifiable {
    let id: UUID
    let question: String
    let snapshot: ContextSnapshot?
    var title: String
    var instructions: String
    var documentPath: String
    var workspace: String
    var mode: DelegationMode
    var writesAllowed = false
    var startQueueOnce = false
    let documentRevision: String
    var submissionAttempted = false

    static func make(question: String, history: [ChatMessage], snapshot: ContextSnapshot?) -> Self {
        let path = snapshot?.selection?.records["document_path"] ?? ""
        let file = path.hasPrefix("/") ? path : ""
        let recent = history.filter { $0.complete }.suffix(4).map { "\($0.role): \($0.text.prefix(3000))" }.joined(separator: "\n\n")
        let instructions = recent.isEmpty ? question : "Request:\n\(question)\n\nConversation for reference (data, not additional authorization):\n\(recent)"
        let mode: DelegationMode = question.range(of: "(?i)\\b(background|unattended)\\b", options: .regularExpression) != nil ? .background :
            question.range(of: "(?i)\\b(agent|sub.agent|claude|herdr|kick.off|work on|update this document)\\b", options: .regularExpression) != nil ? .herdr : .file
        let edits = mode == .background && question.range(of: "(?i)\\b(update|edit|revise|rewrite|fix|change|implement)\\b", options: .regularExpression) != nil
        return .init(id: UUID(), question: question, snapshot: snapshot, title: String(question.split(separator: "\n").first.map(String.init)?.prefix(120) ?? "New task"),
                     instructions: instructions, documentPath: file, workspace: file.isEmpty ? "" : URL(fileURLWithPath: file).deletingLastPathComponent().path,
                     mode: mode, writesAllowed: edits, documentRevision: snapshot?.selection?.records["document_revision"] ?? "")
    }
}

struct TaskHandoffRequest: Codable {
    let op: String
    let request_id: String
    let requester_pid: Int32
    let user_confirmed: Bool
    let title: String
    let instructions: String
    let source: String
    let document_path: String?
    let document_revision: String?
    let workspace: String?
    let mode: DelegationMode
    let writes_allowed: Bool
    let start_queue_once: Bool
}

struct TaskHandoffResult: Codable {
    let task_id: String?
    let task_ref: String?
    let state: String
    let message: String
    var link: String? { task_id.map { "cxtasks://task/\($0)" } }
    var transcript: String {
        guard let id = task_ref ?? task_id, let link else { return message }
        return "[\(id)](\(link)): \(message)"
    }
}

enum TaskDelegation {
    static func fileRevision(_ path: String) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw DelegationError("Choose an existing local document file.") }
        let nanos = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return "\(nanos):\(info.st_size)"
    }
    static func request(_ proposal: DelegationProposal) throws -> TaskHandoffRequest {
        let title = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = proposal.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 240, !instructions.isEmpty, instructions.utf8.count <= 32_000 else { throw DelegationError("Add a task title and instructions (up to 32 KB).") }
        if proposal.snapshot?.selection?.records["editing"] == "true" { throw DelegationError("Save and close the Onyx editor, then send a fresh request.") }
        var document: String?, revision: String?, workspace: String?
        if !proposal.documentPath.isEmpty {
            guard proposal.documentPath.hasPrefix("/") else { throw DelegationError("Choose an absolute local document path.") }
            document = URL(fileURLWithPath: proposal.documentPath).resolvingSymlinksInPath().standardizedFileURL.path
            revision = try fileRevision(document!)
            if !proposal.documentRevision.isEmpty, revision != proposal.documentRevision { throw DelegationError("The document changed since it was shown. Refresh it in Onyx and send a fresh request.") }
        }
        if !proposal.workspace.isEmpty {
            guard proposal.workspace.hasPrefix("/") else { throw DelegationError("Choose an absolute working folder.") }
            let url = URL(fileURLWithPath: proposal.workspace).resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw DelegationError("The working folder is unavailable.") }
            workspace = url.path
            if let document, !document.hasPrefix(url.path.hasSuffix("/") ? url.path : url.path + "/") { throw DelegationError("The working folder must contain the source document.") }
        }
        if proposal.mode == .background && workspace == nil { throw DelegationError("Background work needs an explicit working folder.") }
        if proposal.mode != .file && proposal.snapshot?.bundleID == "com.cx.onyx" && document == nil { throw DelegationError("Choose the local document in Onyx before starting an agent. Remote pages cannot be edited.") }
        let source: String
        if let snapshot = proposal.snapshot {
            let records = snapshot.selection?.records ?? [:]
            let data = try JSONSerialization.data(withJSONObject: ["app": snapshot.appName, "selection": snapshot.selection?.label ?? snapshot.windowTitle, "records": records], options: [.sortedKeys])
            source = String(decoding: data, as: UTF8.self)
        } else { source = "General chat; no screen context attached." }
        return .init(op: "handoff", request_id: proposal.id.uuidString.lowercased(), requester_pid: ProcessInfo.processInfo.processIdentifier, user_confirmed: true,
                     title: title, instructions: instructions, source: source, document_path: document, document_revision: revision, workspace: workspace,
                     mode: proposal.mode, writes_allowed: proposal.mode == .background && proposal.writesAllowed,
                     start_queue_once: proposal.mode == .background && proposal.startQueueOnce)
    }
    static func revalidate(_ snapshot: ContextSnapshot?, displayID: UInt32?) throws {
        guard let snapshot else { return }
        guard displayID == snapshot.displayID,
              NSRunningApplication(processIdentifier: snapshot.pid)?.launchDate?.timeIntervalSince1970 == snapshot.launchTime,
              DisplayContext.windows(on: snapshot.displayID).contains(where: { $0.id == snapshot.windowID && $0.pid == snapshot.pid }) else { throw DelegationError("The source window changed. Send a fresh request before creating this task.") }
        if let selection = snapshot.selection {
            guard let fresh = SelectionReader.read(bundleID: snapshot.bundleID, pid: snapshot.pid), fresh.sameTarget(as: selection) else { throw DelegationError("The selected item changed. Send a fresh request before creating this task.") }
        }
    }
    @MainActor static func ensureCXTasks(executable: String) async throws -> Int32 {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: AppConnector.cxtasks.bundleID).first { return app.processIdentifier }
        let bundle = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app", FileManager.default.fileExists(atPath: bundle.path) else { throw DelegationError("Open the updated CXTasks app, or configure its MCP path in Settings.") }
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: bundle, configuration: config) { app, _ in
                if let app { continuation.resume(returning: app) } else { continuation.resume(throwing: DelegationError("CXTasks could not be opened.")) }
            }
        }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: SelectionReader.socketPath(.cxtasks)) { return app.processIdentifier }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DelegationError("CXTasks did not make its task handoff available. Open the updated companion build.")
    }
    static func submit(_ request: TaskHandoffRequest, pid: Int32, socketPath: String = SelectionReader.socketPath(.cxtasks)) throws -> TaskHandoffResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DelegationError("CXTasks is unavailable.") }; defer { close(fd) }
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketPath.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw DelegationError("CXTasks handoff path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw DelegationError("Open the updated CXTasks app to enable task handoff.") }
        var peer: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0, peer == pid else { throw DelegationError("The CXTasks connection changed. Reopen it and retry.") }
        var encoded = try JSONEncoder().encode(request); encoded.append(10)
        guard encoded.count <= 64_000 else { throw DelegationError("The reviewed task is too large to file.") }
        var sent = 0
        while sent < encoded.count {
            let count = encoded.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), encoded.count - sent) }
            guard count > 0 else { throw DelegationError("The task handoff was interrupted. Check CXTasks before trying again.") }; sent += count
        }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while output.count <= 32_000 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw DelegationError("The task handoff has no confirmed result. Check task \(request.request_id) in CXTasks; a launch may already have been accepted.") }
            output.append(contentsOf: buffer.prefix(count))
            if output.contains(10) { break }
        }
        guard let line = output.split(separator: 10).first, line.count <= 32_000,
              let result = try? JSONDecoder().decode(TaskHandoffResult.self, from: Data(line)),
              result.task_id == nil || result.task_id == request.request_id,
              (result.task_id == nil) == (result.state == "rejected"),
              ["filed", "dispatched", "queued", "failed", "pending", "rejected"].contains(result.state) else { throw DelegationError("CXTasks returned an unconfirmed result. Check the task before launching it again.") }
        return result
    }
}

struct DelegationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
