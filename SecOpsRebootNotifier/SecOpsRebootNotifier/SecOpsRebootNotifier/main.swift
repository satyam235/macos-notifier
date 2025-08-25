import AppKit

// Entry point using NSApplicationMain attribute is deprecated in favor of @main in Swift 5.3+,
// but for AppKit we can still launch the application manually.

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // LSUIElement also hides Dock; redundancy ok
        app.run()
 
