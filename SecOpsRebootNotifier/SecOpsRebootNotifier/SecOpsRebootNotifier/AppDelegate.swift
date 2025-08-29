import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController?
    private var configManager: ConfigManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments.dropFirst()
        let config = AppConfiguration.parse(from: Array(arguments))
        
        // Use /tmp directly - the path will be enforced inside ConfigManager
        let cfgPath = WritablePathResolver.configPath
        let cfgMgr = ConfigManager(path: cfgPath)
        self.configManager = cfgMgr
        
        // Always start with a fresh countdown, hardcoded to 600 seconds (10 minutes)
        let countdown = 600 // Hardcoded value as requested
        
        // Clear any previously scheduled time in the config
        if cfgMgr.store["scheduled_time"] != nil {
            cfgMgr.clearScheduledStatus()
            NSLog("AppDelegate: Starting with fresh countdown, cleared previous scheduled time")
        }
        
        // Initialize the logger and clear any previously saved state
        let logger = ActionLogger(stateFilePath: config.stateFilePath,
                                  historyLogPath: config.historyFilePath)
        // Clear any previous state to ensure we start with a fresh countdown
        logger.clearStateFile()
        
        // Hardcode delay options to [30, 90] minutes (converted to seconds)
        let hardcodedDelayOptions = [30 * 60, 90 * 60]
        
        let state = RebootState(initialSeconds: countdown,
                                allowedDelayOptions: hardcodedDelayOptions,
                                maxTotalDelay: config.maxTotalDelay)
        
        panelController = PanelController(state: state, logger: logger, config: cfgMgr)
        panelController?.show()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app alive so accidental clicks outside panel don't auto-exit.
        return false
    }
}

// MARK: - Configuration
struct AppConfiguration {
    let countdownSeconds: Int
    let delayOptions: [Int]
    let stateFilePath: String
    let historyFilePath: String
    let maxTotalDelay: Int?
    // Potential future: add configFilePath if you want CLI override of JSON config.
    
    static func parse(from args: [String]) -> AppConfiguration {
        var countdown = 300
        var delays: [Int] = [3600, 7200, 21600]
        var statePath = "/tmp/reboot_state.json"
        var historyPath = "/tmp/reboot_action_history.log"
        var maxDelay: Int?
        
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--countdown":
                if let v = iterator.next(), let intV = Int(v) {
                    countdown = intV
                }
            case "--delays":
                if let v = iterator.next() {
                    let parts = v.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if !parts.isEmpty { delays = parts }
                }
            case "--state-file":
                if let v = iterator.next() { statePath = v }
            case "--log-file":
                if let v = iterator.next() { historyPath = v }
            case "--max-total-delay":
                if let v = iterator.next(), let intV = Int(v) { maxDelay = intV }
            default:
                break
            }
        }
        
        return AppConfiguration(countdownSeconds: countdown,
                                delayOptions: delays.sorted(),
                                stateFilePath: statePath,
                                historyFilePath: historyPath,
                                maxTotalDelay: maxDelay)
    }
}