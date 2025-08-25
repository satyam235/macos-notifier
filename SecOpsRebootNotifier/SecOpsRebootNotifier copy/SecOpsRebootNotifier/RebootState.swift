import Foundation

struct RebootState: Codable {
    private(set) var remainingSeconds: Int
    let allowedDelayOptions: [Int]
    let maxTotalDelay: Int?   // (unused right now; keep if you later want a cap)
    
    init(initialSeconds: Int,
         allowedDelayOptions: [Int],
         maxTotalDelay: Int?) {
        self.remainingSeconds = initialSeconds
        self.allowedDelayOptions = allowedDelayOptions.sorted()
        self.maxTotalDelay = maxTotalDelay
    }
    
    mutating func tick() {
        if remainingSeconds > 0 { remainingSeconds -= 1 }
    }
    
    mutating func applyDelay(_ seconds: Int) -> Bool {
        guard allowedDelayOptions.contains(seconds) else { return false }
        // If you later enforce a max, check here with maxTotalDelay.
        remainingSeconds += seconds
        return true
    }
}