import Foundation

/// Keys expected (all optional):
///  - custom_message: String
///  - reboot_config: String (e.g. "Graceful Reboot" or "Force reboot after patch deployment")
///  - delay_counter: Int (number of remaining delay opportunities)
///  - scheduled_time: String (ISO-like or '%Y-%m-%d %H:%M:%S')
///  - task_scheduled: Bool
///  - reboot_now: Bool
/// This manager loads a JSON dictionary (top-level object) and allows selective mutation
/// while preserving unknown fields. All keys must be in snake_case format.
final class ConfigManager {
    enum RebootConfig: String {
        case graceful = "Graceful Reboot"
        case forceAfterPatch = "Force reboot after patch deployment"
        case other
        init(raw: String?) {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Case-insensitive comparison for graceful reboot
            if trimmed?.lowercased() == "graceful reboot" {
                self = .graceful
            } else if trimmed == RebootConfig.forceAfterPatch.rawValue {
                self = .forceAfterPatch
            } else {
                self = .other
            }
        }
    }
    
    private(set) var store: [String: Any] = [:]
    private var path: String
    private let queue = DispatchQueue(label: "secops.config", attributes: .concurrent)
    
    init(path: String) {
        // Use the Application Support path
        self.path = WritablePathResolver.configPath
        
        NSLog("ConfigManager: Using path for config file: \(self.path)")
        
        load()
    }
    
    // MARK: - Derived values
    var customMessage: String {
        (store["custom_message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Reboot required to complete important updates."
    }
    var rebootConfig: RebootConfig { RebootConfig(raw: store["reboot_config"] as? String) }
    var delayCounter: Int { store["delay_counter"] as? Int ?? 0 }
    var rebootNowFlag: Bool { store["reboot_now"] as? Bool ?? false }
    /// countdown_seconds from config (0 means not set — caller should apply its own default)
    var countdownSeconds: Int { store["countdown_seconds"] as? Int ?? 0 }
    /// delay_options from config: list of integer hours → converted to seconds.
    /// Returns empty array when the key is absent (caller should apply its own default).
    var delayOptionsInSeconds: [Int] {
        guard let hours = store["delay_options"] as? [Int], !hours.isEmpty else { return [] }
        return hours.map { $0 * 3600 }
    }
    
    // MARK: - Load & Save
    private func load() {
        queue.sync(flags: .barrier) {
            let fm = FileManager.default
            
            // Make sure we're using the Application Support path
            if self.path != WritablePathResolver.configPath {
                NSLog("ConfigManager: Warning - Not using correct config path. Correcting.")
                self.path = WritablePathResolver.configPath
            }
            
            if fm.fileExists(atPath: path) {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    
                    if data.isEmpty {
                        NSLog("ConfigManager: Config file exists at path: \(path) but is empty. Creating a new config file.")
                        persistLocked()
                        return
                    }
                    
                    if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.store = obj
                        NSLog("ConfigManager: Successfully loaded config with \(obj.keys.count) keys: \(obj.keys.joined(separator: ", "))")
                        NSLog("ConfigManager: custom_message = '\(obj["custom_message"] as? String ?? "nil")'")
                        NSLog("ConfigManager: delay_counter = \(obj["delay_counter"] as? Int ?? -1)")
                        NSLog("ConfigManager: reboot_config = '\(obj["reboot_config"] as? String ?? "nil")'")
                        normalizeKeysLocked()
                    } else {
                        NSLog("ConfigManager: Config file exists but contains invalid JSON structure. Creating a new config file.")
                        persistLocked()
                    }
                } catch {
                    NSLog("ConfigManager: Failed reading config: \(error)")
                    NSLog("ConfigManager: Creating a new config file due to read error.")
                    persistLocked()
                }
            } else {
                // Log that the config file does not exist
                NSLog("ConfigManager: Config file does not exist at path: \(path). Creating a new empty config file.")
                
                // Create empty file
                persistLocked()
            }
        }
    }
    
    func reload() { load() }
    
    private func persistLocked() {
        do {
            let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            
            // Ensure the directory exists
            let fm = FileManager.default
            let dir = (path as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            
            // Write the file to Application Support
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            
            NSLog("ConfigManager: Successfully wrote to config file: \(path)")
        } catch {
            NSLog("ConfigManager: Failed writing config: \(error)")
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