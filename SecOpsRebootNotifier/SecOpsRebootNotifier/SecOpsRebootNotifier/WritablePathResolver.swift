import Foundation

struct WritablePathResolver {
    // Define the path constants for consistency across the app
    static let configDirectory = "/tmp"
    static let configFileName = "SecOpsNotifierConfig.json"
    static let configPath = "/tmp/SecOpsNotifierConfig.json"
    
    struct Result {
        let stateFile: String
        let historyFile: String
        let baseDir: String
    }
    
    static func resolveConfigDir() -> String {
        // Simply return /tmp as the directory for configs
        let tmpDir = configDirectory
        
        // No need to create /tmp as it always exists
        NSLog("Using /tmp for configuration storage")
        
        return tmpDir
    }
    
    static func resolve(stateFileName: String = "reboot_state.json",
                        historyFileName: String = "reboot_action_history.log") -> Result {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        
        // Candidate directories in priority order
        var candidates: [URL] = []
        
        // 1. Explicit environment override (optional)
        if let custom = ProcessInfo.processInfo.environment["SECOPS_REBOOT_LOG_DIR"] {
            candidates.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
        }
        // 2. Logs directory (visible & admin-friendly)
        candidates.append(home.appendingPathComponent("Library/Logs/SecOpsRebootNotifier"))
        // 3. User temporary directory (not global /tmp)
        candidates.append(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SecOpsRebootNotifier"))
        // 4. Application Support
        candidates.append(home.appendingPathComponent("Library/Application Support/SecOpsRebootNotifier"))
        
        let chosen: URL = candidates.first { dir in
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let probe = dir.appendingPathComponent(".write_test_\(UUID().uuidString)")
                let data = Data("probe".utf8)
                try data.write(to: probe, options: .atomic)
                try fm.removeItem(at: probe)
                return true
            } catch {
                return false
            }
        } ?? home
        
        let state = chosen.appendingPathComponent(stateFileName).path
        let history = chosen.appendingPathComponent(historyFileName).path
        
        print("WritablePathResolver: Selected writable log directory: \(chosen.path)")
        return Result(stateFile: state, historyFile: history, baseDir: chosen.path)
    }
}