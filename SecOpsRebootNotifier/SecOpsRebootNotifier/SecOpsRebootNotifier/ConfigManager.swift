import Foundation

/// Keys expected (all optional):
///  - custom_message: String
///  - reboot_config: String (e.g. "Graceful Reboot" or "Force reboot after patch deployment")
///  - delay_counter: Int (number of remaining delay opportunities)
///  - scheduled_time: String (ISO-like or '%Y-%m-%d %H:%M:%S')
///  - task_scheduled: Bool
///  - reboot_now: Bool
/// This manager loads a JSON dictionary (top-level object) and allows selective mutation
/// while preserving unknown fields.
final class ConfigManager {
    enum RebootConfig: String {
        case graceful = "Graceful Reboot"
        case forceAfterPatch = "Force reboot after patch deployment"
        case other
        init(raw: String?) {
            switch raw?.trimmingCharacters(in: .whitespacesAndNewlines) {
            case RebootConfig.graceful.rawValue?: self = .graceful
            case RebootConfig.forceAfterPatch.rawValue?: self = .forceAfterPatch
            default: self = .other
            }
        }
    }
    
    private(set) var store: [String: Any] = [:]
    private let path: String
    private let queue = DispatchQueue(label: "secops.config", attributes: .concurrent)
    
    init(path: String) {
        self.path = (path as NSString).expandingTildeInPath
        
        // Log if using secure path
        if path.contains("/usr/local/bin/SecOpsNotifierService") {
            NSLog("ConfigManager: Using secure path for config file: \(path)")
        } else if path.contains("/tmp") {
            NSLog("ConfigManager: WARNING - Using insecure /tmp path for config file: \(path)")
        }
        
        load()
    }
    
    // MARK: - Derived values
    var customMessage: String {
        (store["custom_message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Reboot required to complete important updates."
    }
    var rebootConfig: RebootConfig { RebootConfig(raw: store["reboot_config"] as? String) }
    var delayCounter: Int { store["delay_counter"] as? Int ?? 0 }
    var rebootNowFlag: Bool { store["reboot_now"] as? Bool ?? false }
    
    // MARK: - Load & Save
    private func load() {
        queue.sync(flags: .barrier) {
            let fm = FileManager.default
            if fm.fileExists(atPath: path) {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.store = obj
                        normalizeKeysLocked()
                    }
                } catch {
                    NSLog("ConfigManager: failed reading config: \(error)")
                }
            } else {
                // Create empty file
                persistLocked()
            }
        }
    }
    
    func reload() { load() }
    
    private func persistLocked() {
        do {
            let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            
            // Set appropriate permissions if in secure directory
            if dir.contains("/usr/local/bin/SecOpsNotifierService") {
                #if !targetEnvironment(simulator)
                let task = Process()
                task.launchPath = "/usr/bin/chmod"
                task.arguments = ["640", path] // Owner read-write, group read, others nothing
                try task.run()
                task.waitUntilExit()
                #endif
                
                NSLog("ConfigManager: successfully wrote to secure config file: \(path)")
            }
        } catch {
            NSLog("ConfigManager: failed writing config: \(error). Ensure the app has necessary permissions.")
        }
    }
    
    private func mutate(_ block: @escaping (inout [String: Any]) -> Void) {
        queue.async(flags: .barrier) {
            block(&self.store)
            self.persistLocked()
        }
    }

    // Accept both legacy/camelCase keys and canonical snake_case keys.
    // Must be called inside barrier (Locked) context.
    private func normalizeKeysLocked() {
        let mappings: [(legacy: String, canonical: String)] = [
            ("customMessage", "custom_message"),
            ("rebootConfig", "reboot_config"),
            ("delayCounter", "delay_counter"),
            ("scheduledTime", "scheduled_time"),
            ("rebootNow", "reboot_now")
        ]
        var changed = false
        for (legacy, canonical) in mappings {
            if let v = store[legacy] {
                if store[canonical] == nil { store[canonical] = v }
                store.removeValue(forKey: legacy) // always remove legacy key
                changed = true
            }
        }
        if changed { persistLocked() }
    }
    
    // MARK: - Mutations
    func setRebootNow() {
        mutate { $0["reboot_now"] = true }
    }
    
    func clearScheduledStatus() {
        mutate { dict in
            dict["scheduled_time"] = ""
            dict["task_scheduled"] = false
        }
    }
    
    func applyDelay(seconds: Int) {
        mutate { dict in
            let current = dict["delay_counter"] as? Int ?? 0
            if current > 0 { dict["delay_counter"] = current - 1 }
            let date = Date().addingTimeInterval(TimeInterval(seconds))
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            dict["scheduled_time"] = fmt.string(from: date)
            dict["task_scheduled"] = false
            // Ensure reboot_now is false when delaying
            dict["reboot_now"] = false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}