import Foundation

struct LoggedAction: Codable {
    let timestamp: Date
    let action: String
    let remainingSeconds: Int
}

/// Minimal logger: writes a JSON snapshot (state file) and an append-only log.
/// Files go to ~/Library/Logs/SecOpsRebootNotifier by default.
final class ActionLogger {
    private let statePath: String
    private let historyPath: String
    private let writer = AtomicWriter()
    private let iso = ISO8601DateFormatter()
    private let queue = DispatchQueue(label: "secops.logger")
    
    init(stateFilePath: String? = nil,
         historyLogPath: String? = nil) {
        
        // Determine base log directory (prefer user Library/Logs)
        if let s = stateFilePath,
           let h = historyLogPath {
            self.statePath = (s as NSString).expandingTildeInPath
            self.historyPath = (h as NSString).expandingTildeInPath
        } else {
            let fm = FileManager.default
            let base = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/SecOpsRebootNotifier", isDirectory: true)
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            statePath = base.appendingPathComponent("reboot_state.json").path
            historyPath = base.appendingPathComponent("reboot_action_history.log").path
        }
        print("ActionLogger init state=[\(statePath)] history=[\(historyPath)]")
    }
    
    func log(action: LoggerAction, state: RebootState) {
        queue.async {
            self.appendHistory(action: action, state: state)
            self.writeState(state: state, action: action.name)
        }
    }
    
    func clearState() {
        queue.async {
            do {
                // Write an empty JSON object to the state file
                let emptyData = "{}".data(using: .utf8)!
                try self.writer.writeAtomic(data: emptyData, toPath: self.statePath, permissions: 0o644)
                NSLog("ActionLogger: Cleared state file")
            } catch {
                NSLog("Failed to clear state: \(error)")
            }
        }
    }
    
    func clearStateFile() {
        // Clear the state file immediately (synchronously)
        do {
            // Write an empty JSON object to the state file
            let emptyData = "{}".data(using: .utf8)!
            try self.writer.writeAtomic(data: emptyData, toPath: self.statePath, permissions: 0o644)
            NSLog("ActionLogger: Cleared state file on app startup")
        } catch {
            NSLog("Failed to clear state file on startup: \(error)")
        }
    }
    
    func writeState(state: RebootState, action: String) {
        queue.async {
            let payload: [String: Any] = [
                "timestamp": self.iso.string(from: Date()),
                "action": action,
                "remaining_seconds": state.remainingSeconds
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                try self.writer.writeAtomic(data: data, toPath: self.statePath, permissions: 0o644)
            } catch {
                NSLog("Failed to write state: \(error)")
            }
        }
    }
    
    private func appendHistory(action: LoggerAction, state: RebootState) {
        queue.async {
            let entry = LoggedAction(timestamp: Date(),
                                     action: action.name,
                                     remainingSeconds: state.remainingSeconds)
            do {
                let encoded = try JSONEncoder().encode(entry)
                let line = String(data: encoded, encoding: .utf8)! + "\n"
                try self.append(line: line, to: self.historyPath)
            } catch {
                NSLog("Failed to append log: \(error)")
            }
        }
    }
    
    private func append(line: String, to path: String) throws {
        let fm = FileManager.default
        let expanded = (path as NSString).expandingTildeInPath
        let dir = (expanded as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: expanded) {
            try writer.writeAtomic(data: Data(), toPath: expanded, permissions: 0o644)
        }
        guard let handle = FileHandle(forWritingAtPath: expanded) else {
            throw NSError(domain: "ActionLogger", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot open file handle at \(expanded)"])
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }
}

enum LoggerAction {
    case rebootNow
    case delay(seconds: Int)
    case expired
    
    var name: String {
        switch self {
        case .rebootNow: return "reboot_now"
        case .delay(let s): return "delay_\(s)"
        case .expired: return "expired"
        }
    }
}