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
        } catch {
            NSLog("ConfigManager: failed writing config: \(error)")
        }
    }
    
    private func mutate(_ block: @escaping (inout [String: Any]) -> Void) {
        queue.async(flags: .barrier) {
            block(&self.store)
            self.persistLocked()
        }
    }
    
    // MARK: - Mutations
    func setRebootNow() {
        mutate { $0["reboot_now"] = true }
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
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}