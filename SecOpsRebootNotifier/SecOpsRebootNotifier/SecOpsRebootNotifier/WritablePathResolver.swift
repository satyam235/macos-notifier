import Foundation

struct WritablePathResolver {
    struct Result {
        let stateFile: String
        let historyFile: String
        let baseDir: String
    }
    
    static func resolveSecureConfigDir() -> String {
        let secureDir = "/usr/local/bin/SecOpsNotifierService"
        let fm = FileManager.default
        
        // Check if directory exists, if not create it
        do {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: secureDir, isDirectory: &isDir)
            
            if !exists {
                try fm.createDirectory(atPath: secureDir, withIntermediateDirectories: true)
                
                #if !targetEnvironment(simulator)
                // Set permissions (0750 = rwxr-x---)
                // This requires root permissions, so it might fail if the app isn't run with elevated privileges
                let task = Process()
                task.launchPath = "/usr/bin/chmod"
                task.arguments = ["750", secureDir]
                try task.run()
                task.waitUntilExit()
                #endif
                
                NSLog("Created secure config directory: \(secureDir)")
            } else if !isDir.boolValue {
                NSLog("Warning: \(secureDir) exists but is not a directory")
            }
        } catch {
            NSLog("Failed to create/set permissions on secure config directory: \(error)")
        }
        
        return secureDir
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