import Foundation

/// Claude processes launched ahead of the question, so the CLI's startup (and, for My setup,
/// connecting every user MCP server: 3–11 s cold against 1–2 s warm) is done before the user
/// sends. A spare answers exactly one turn with the full chat, as a cold launch would, and is
/// replaced; nothing carries over between turns. Claude only: Codex reads its prompt before
/// starting a thread, so launching it early saves nothing.
final class WarmPool {
    static let shared = WarmPool()

    /// What a spare was launched with. A request takes a spare only when its launch would be
    /// identical, so a changed model, path or route starts cold rather than reusing a stale one.
    struct Key: Hashable {
        let executable: String
        let arguments: [String]
        /// My setup runs from the home folder; everything else from a fresh empty workspace.
        let personal: Bool
        /// A chat set to a folder with `!cd` runs My setup from there instead of home.
        var directory: URL? = nil
    }

    final class Spare {
        let process: Process
        let input: Pipe, output: Pipe, errors: Pipe
        /// The empty folder it runs in; the request that takes it removes it.
        let workspace: URL?
        init(process: Process, input: Pipe, output: Pipe, errors: Pipe, workspace: URL?) {
            self.process = process; self.input = input; self.output = output; self.errors = errors; self.workspace = workspace
        }
        func discard() {
            if process.isRunning {
                process.terminate()
                let child = process
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
            }
            if let workspace { try? FileManager.default.removeItem(at: workspace) }
        }
    }

    /// Spares go once nothing has used or asked for them this long: a My setup spare holds every
    /// user MCP server open. Matches the popup's fresh-chat rule.
    var idleLimit: TimeInterval = 600
    private let lock = NSLock()
    private var spares: [Key: Spare] = [:]
    private var expiry: DispatchWorkItem?

    /// The running spare launched for `key`, now the caller's. A spare that has exited (a lapsed
    /// login, a crash) is dropped, so the request starts cold and reports the real error.
    func take(_ key: Key) -> Spare? {
        lock.lock(); let spare = spares.removeValue(forKey: key); lock.unlock()
        guard let spare else { return nil }
        guard spare.process.isRunning else { spare.discard(); return nil }
        return spare
    }

    /// Launches a spare for `key` unless a running one is already waiting.
    func prepare(_ key: Key) {
        lock.lock()
        if let current = spares[key], current.process.isRunning { lock.unlock(); scheduleExpiry(); return }
        let stale = spares.removeValue(forKey: key)
        lock.unlock()
        stale?.discard()
        guard let spare = launch(key) else { return }
        lock.lock()
        let raced = spares[key]
        spares[key] = spare
        lock.unlock()
        raced?.discard()
        scheduleExpiry()
    }

    /// Ends every spare (quitting, or idle).
    func drain() {
        lock.lock(); let all = Array(spares.values); spares = [:]; expiry?.cancel(); expiry = nil; lock.unlock()
        all.forEach { $0.discard() }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return spares.values.filter(\.process.isRunning).count }

    private func scheduleExpiry() {
        let item = DispatchWorkItem { [weak self] in self?.drain() }
        lock.lock(); expiry?.cancel(); expiry = item; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + idleLimit, execute: item)
    }

    private func launch(_ key: Key) -> Spare? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: key.executable)
        process.arguments = key.arguments
        process.environment = ExecutableFinder.environment(for: key.executable)
        var workspace: URL?
        if key.personal { process.currentDirectoryURL = key.directory ?? FileManager.default.homeDirectoryForCurrentUser }
        else {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-\(UUID().uuidString)")
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return nil }
            process.currentDirectoryURL = folder; workspace = folder
        }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        do { try process.run() } catch {
            if let workspace { try? FileManager.default.removeItem(at: workspace) }
            return nil
        }
        return Spare(process: process, input: input, output: output, errors: errors, workspace: workspace)
    }
}
