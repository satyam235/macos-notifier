import AppKit

class DelayMenuController {
    let options: [Int] // seconds
    let menu: NSMenu
    private let handler: (Int) -> Void
    
    init(options: [Int], handler: @escaping (Int) -> Void) {
        self.options = options
        self.handler = handler
        self.menu = NSMenu()
        buildMenu()
    }
    
    private func buildMenu() {
        menu.items.removeAll()
        for opt in options {
            let title = formatOption(seconds: opt)
            let item = NSMenuItem(title: title, action: #selector(selectDelay(_:)), keyEquivalent: "")
            item.representedObject = opt
            item.target = self
            menu.addItem(item)
        }
    }
    
    private func formatOption(seconds: Int) -> String {
        if seconds % 3600 == 0 {
            let hours = seconds / 3600
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        if seconds % 60 == 0 {
            let mins = seconds / 60
            return "\(mins) min"
        }
        return "\(seconds) s"
    }
    
    @objc private func selectDelay(_ sender: NSMenuItem) {
        guard let val = sender.representedObject as? Int else { return }
        handler(val)
    }
}