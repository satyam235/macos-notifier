import Foundation

enum CountdownFormatter {
    static func string(from seconds: Int) -> String {
        let clamped = max(0, seconds)
        if clamped >= 3600 {
            let h = clamped / 3600
            let m = (clamped % 3600) / 60
            return String(format: "%02d:%02d hours", h, m)
        } else {
            let m = clamped / 60
            let s = clamped % 60
            return String(format: "%02d:%02d minutes", m, s)
        }
    }
}