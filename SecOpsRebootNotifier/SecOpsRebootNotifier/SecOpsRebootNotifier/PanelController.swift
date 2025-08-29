import AppKit

class PanelController: NSObject {
    private var state: RebootState
    private let logger: ActionLogger
    private let config: ConfigManager?
    private var timer: DispatchSourceTimer?
    
    // MARK: - Panel geometry - hardcoded values
    private let panelWidth: CGFloat = 320  // Hardcoded width as requested
    private let topMargin: CGFloat = 16    // Hardcoded top margin as requested
    private let rightMargin: CGFloat = 24  // Hardcoded right margin as requested
    private let cornerRadius: CGFloat = 16
    private var initialTotalSeconds: Int
    
    private var panel: PersistentPanel!
    private var backgroundView: NSVisualEffectView!
    
    private var iconContainer: NSView! // kept for layout grouping, now transparent
    private var iconView: NSImageView!
    private var titleLabel: NSTextField!
    private var bodyLabel: NSTextField!
    private var countdownLabel: NSTextField!
    // Plain button that shows a menu (no arrow) for options
    private var optionsButton: NSButton!
    private var optionsMenu: NSMenu!
    private var optionsButtonWidthConstraint: NSLayoutConstraint?
    // progress indicator removed
    
    private var delayMenuController: DelayMenuController!
    
    init(state: RebootState, logger: ActionLogger, config: ConfigManager? = nil) {
        self.state = state
        self.logger = logger
        self.config = config
        self.initialTotalSeconds = state.remainingSeconds
        super.init()
        buildUI()
        configureMenu()
        startTimer()
        writeInitialState()
        observeScreenChanges()
        applyConfigVisuals()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func show() {
        layoutAndReposition()
        animateIntro()
        panel.orderFrontRegardless()
    }
    
    private func buildUI() {
        panel = PersistentPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 140),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.animationBehavior = .utilityWindow
        
        backgroundView = NSVisualEffectView(frame: panel.contentView!.bounds)
        backgroundView.autoresizingMask = [.width, .height]
    // Modern translucent material (light, adaptive)
    if #available(macOS 11.0, *) {
        backgroundView.material = .popover
    } else {
        backgroundView.material = .light
    }
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = cornerRadius
        backgroundView.layer?.masksToBounds = true
    backgroundView.layer?.shadowColor = NSColor.black.cgColor
    backgroundView.layer?.shadowOpacity = 0.12
    backgroundView.layer?.shadowRadius = 12
    backgroundView.layer?.shadowOffset = CGSize(width: 0, height: -2)
    // Subtle hairline border inside for definition
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    backgroundView.layer?.borderWidth = 1 / scale
    backgroundView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        panel.contentView?.addSubview(backgroundView)
        
    // Icon container for subtle background + border ring
    iconContainer = NSView()
    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.wantsLayer = true
    iconContainer.layer?.cornerRadius = 0
    iconContainer.layer?.masksToBounds = false
    // Remove circular accent styling per request (transparent container)
    iconContainer.layer?.backgroundColor = NSColor.clear.cgColor
    iconContainer.layer?.borderWidth = 0

    iconView = NSImageView()
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyDown
    iconView.wantsLayer = false
    iconView.image = NSImage(named: "SecOpsIcon")
    iconContainer.addSubview(iconView)
        
    titleLabel = makeLabel(font: .systemFont(ofSize: 13.5, weight: .semibold),
                               color: .labelColor, lines: 1)
    titleLabel.stringValue = "Device will reboot shortly"
        
    // Body label wraps to at most 2 lines (<=100 chars) then countdown appears below.
    bodyLabel = makeLabel(font: .systemFont(ofSize: 12),
                  color: .secondaryLabelColor, lines: 2, wrap: true)
    // Set smaller bottom padding for the label
    bodyLabel.maximumNumberOfLines = 2
    bodyLabel.usesSingleLineMode = false
    bodyLabel.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    bodyLabel.setContentHuggingPriority(.defaultHigh, for: .vertical)
    bodyLabel.stringValue = enforceMessageLimit(config?.customMessage ?? "Reboot required to complete important updates.")
        
    countdownLabel = makeLabel(font: .systemFont(ofSize: 12, weight: .regular),
                   color: .labelColor, lines: 1)
        countdownLabel.stringValue = formattedCountdown()
    // Skip paragraph styling to reduce extra spacing
    // applyParagraphStyle(to: bodyLabel)
    // applyParagraphStyle(to: countdownLabel, tighten: true)
        
    // Plain button (no disclosure arrow). We'll pop up an NSMenu manually.
    optionsButton = NSButton(title: "Options", target: self, action: #selector(showOptionsMenu(_:)))
    optionsButton.translatesAutoresizingMaskIntoConstraints = false
    optionsButton.font = .systemFont(ofSize: 11, weight: .semibold)
    optionsButton.bezelStyle = .rounded
    optionsButton.setAccessibilityLabel("Options: reboot or delay choices")
    // Taller button for better balance with countdown line
    optionsButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
    buildOptionsMenu()
    countdownLabel.setAccessibilityLabel("Countdown until automatic reboot")
    updateOptionsButtonWidth()
        
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
    textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(bodyLabel)
    // countdown placed in separate bottom row with options button for full-width title/body
        
    backgroundView.addSubview(iconContainer)
    backgroundView.addSubview(textStack)
    // Bottom row container
    let bottomRow = NSStackView()
    bottomRow.orientation = .horizontal
    bottomRow.alignment = .centerY
    bottomRow.spacing = 12
    bottomRow.translatesAutoresizingMaskIntoConstraints = false
    bottomRow.addArrangedSubview(countdownLabel)
    bottomRow.addArrangedSubview(NSView()) // flexible spacer
    bottomRow.addArrangedSubview(optionsButton)

    backgroundView.addSubview(bottomRow)

    // (Progress bar removed per design change)

    // Constrain text width so content wraps instead of forcing panel wider than intended.
    let maxTextWidth = panelWidth - 16 /*left padding*/ - 40 /*icon width*/ - 12 /*gap*/ - 20 /*right padding*/
    textStack.widthAnchor.constraint(lessThanOrEqualToConstant: maxTextWidth).isActive = true
    bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 12),
            iconContainer.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor, constant: -2),
            iconContainer.widthAnchor.constraint(equalToConstant: 38),
            iconContainer.heightAnchor.constraint(equalToConstant: 38),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),

            textStack.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            textStack.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 8),
            textStack.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -20),

            bottomRow.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            bottomRow.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: -1),
            bottomRow.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -20),
            bottomRow.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -4),

            optionsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90)
        ])
        
        panel.contentView?.layoutSubtreeIfNeeded()
        backgroundView.layoutSubtreeIfNeeded()
        let requiredHeight = countdownLabel.frame.maxY + 6
        var frame = panel.frame
        frame.size.height = max(requiredHeight, 86)
        panel.setFrame(frame, display: false)
    }
    
    private func makeLabel(font: NSFont, color: NSColor, lines: Int, wrap: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = font
        l.textColor = color
        if wrap {
            l.lineBreakMode = .byWordWrapping
            // 0 means unlimited, but we enforce visual limit by max lines param
            l.maximumNumberOfLines = lines
        } else {
            l.lineBreakMode = .byTruncatingTail
            l.maximumNumberOfLines = lines
        }
        return l
    }
    
    private func configureMenu() {
        // DelayMenuController retained for potential future expansion; not used with new compact "Options" popup.
        delayMenuController = DelayMenuController(options: state.allowedDelayOptions) { [weak self] seconds in
            self?.applyDelay(seconds)
        }
    }
    
    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Decrement remaining time each second
            self.state.tick()
            let remaining = self.state.remainingSeconds
            // Color stays constant; no highlight for last minute.
            self.updateCountdownLabel()
            if remaining <= 0 {
                self.timer?.cancel()
                // Auto behavior: if delay available, auto-apply smallest, persist, log, and exit; else reboot now.
                if let cfg = self.config, cfg.delayCounter > 0, let smallest = self.state.allowedDelayOptions.min() {
                    if self.state.applyDelay(smallest) {
                        self.config?.applyDelay(seconds: smallest)
                        self.logger.log(action: .delay(seconds: smallest), state: self.state)
                    }
                    self.quitApp()
                } else {
                    self.rebootNow()
                }
            }
        }
        timer = t
        t.resume()
    }
    
    private func formattedCountdown() -> String {
        "Auto reboot in \(CountdownFormatter.string(from: state.remainingSeconds))."
    }
    
    private func rebootNow() {
        logger.log(action: .rebootNow, state: state)
        // Set reboot now flag and also clear scheduled time and scheduled status
        config?.setRebootNow()
        config?.clearScheduledStatus()
        quitApp()
    }
    
    private func applyDelay(_ seconds: Int) {
        guard state.applyDelay(seconds) else {
            NSSound.beep()
            return
        }
        logger.log(action: .delay(seconds: seconds), state: state)
    countdownLabel.textColor = NSColor.controlAccentColor.withAlphaComponent(0.75)
        updateCountdownLabel()
        config?.applyDelay(seconds: seconds)
        // After applying delay, also decrement local visual state of remaining delay_counter if present.
    if let cfg = config, cfg.delayCounter <= 0 { disableAllDelayItems(reason: "No Delay Left") }
    // Match original UX: close notifier after user chooses a delay.
    quitApp()
    }
    
    // No longer used: expiration now maps to rebootNow
    private func handleExpiration() { rebootNow() }

    private func applyConfigVisuals() {
        guard let cfg = config else { return }
        switch cfg.rebootConfig {
        case .graceful:
            if cfg.delayCounter != 0 { titleLabel.stringValue = "Reboot Required" }
        case .forceAfterPatch:
            titleLabel.stringValue = "Device Will Reboot Shortly"
        case .other: break
        }
        // Disable delay menu entry if forced or no counter
    if cfg.delayCounter == 0 || cfg.rebootConfig == .forceAfterPatch { disableAllDelayItems() }
        countdownLabel.isHidden = false
        bodyLabel.stringValue = enforceMessageLimit(bodyLabel.stringValue)
    }

    
    private func quitApp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }
    
    private func writeInitialState() {
        logger.writeState(state: state, action: "initial")
    }
    
    private func layoutAndReposition() {
        guard let screen = NSScreen.main else {
            panel.center()
            return
        }
    var vf = screen.visibleFrame
    var frame = panel.frame
    // Ensure width fits inside screen with margins; shrink if necessary
    let maxAllowedWidth = vf.width - (rightMargin * 2)
    if frame.width > maxAllowedWidth { frame.size.width = max(260, maxAllowedWidth) }
    // Recompute origin so panel is fully on-screen
    var originX = vf.maxX - frame.width - rightMargin
    let minX = vf.minX + rightMargin
    if originX < minX { originX = minX }
    var originY = vf.maxY - frame.height - topMargin
    let minY = vf.minY + topMargin
    if originY < minY { originY = minY }
    frame.origin = CGPoint(x: originX, y: originY)
    // Final clamp in case of dynamic later width changes
    if frame.maxX > vf.maxX - rightMargin { frame.origin.x = vf.maxX - rightMargin - frame.width }
    if frame.origin.x < vf.minX + rightMargin { frame.origin.x = vf.minX + rightMargin }
    if frame.maxY > vf.maxY - topMargin { frame.origin.y = vf.maxY - topMargin - frame.height }
    if frame.origin.y < vf.minY + topMargin { frame.origin.y = vf.minY + topMargin }
    panel.setFrame(frame, display: true)
    panel.displayIfNeeded()
    }
    
    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(self, selector: #selector(respositionNotification),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(respositionNotification),
                                               name: NSWindow.didBecomeKeyNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(respositionNotification),
                                               name: NSApplication.didFinishLaunchingNotification, object: nil)
    }
    
    @objc private func respositionNotification() {
        layoutAndReposition()
    }
}

// MARK: - Menu item actions
private extension PanelController {
    @objc func rebootNowMenu(_ sender: Any?) { rebootNow() }
    @objc func delayMenuItemSelected(_ sender: NSMenuItem) {
        if let seconds = sender.representedObject as? Int { applyDelay(seconds) }
    }
    @objc func showOptionsMenu(_ sender: NSButton) {
        // Restore original appearance when showing menu
        if let buttonCell = sender.cell as? NSButtonCell {
            buttonCell.isHighlighted = false
        }
        optionsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height - 2), in: sender)
    }
}

// MARK: - PersistentPanel prevents auto-dismiss on outside click
private final class PersistentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func resignKey() {
        // Don't close when focus moves elsewhere
        super.resignKey()
    }
    override func performClose(_ sender: Any?) {
        // Ignore programmatic close requests unless explicitly terminated
    }
}

// MARK: - Message limiting
private let kMaxBodyChars = 100

private extension PanelController {
    func enforceMessageLimit(_ raw: String) -> String {
        // Collapse whitespace and remove newlines
        var s = raw.replacingOccurrences(of: "[\n\r\t]+", with: " ", options: .regularExpression)
                  .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > kMaxBodyChars {
            let idx = s.index(s.startIndex, offsetBy: kMaxBodyChars)
            s = String(s[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return s
    }

    func updateCountdownLabel() {
        let base = formattedCountdown()
        countdownLabel.attributedStringValue = NSAttributedString(string: base, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ])
    }

    // Build dynamic options dropdown: first dummy title, then actions.
    func buildOptionsMenu() {
        let menu = NSMenu()
        optionsMenu = menu
        // Always add Reboot Now
        let rebootItem = NSMenuItem(title: "Reboot Now", action: #selector(rebootNowMenu), keyEquivalent: "")
        rebootItem.target = self
        rebootItem.identifier = NSUserInterfaceItemIdentifier("rebootNow")
        menu.addItem(rebootItem)

        // Determine if delay options should be shown
        let canDelay: Bool = {
            if state.allowedDelayOptions.isEmpty { return false }
            // If no config, assume delays are permitted
            guard let cfg = config else { return true }
            if cfg.rebootConfig == .forceAfterPatch { return false }
            return cfg.delayCounter > 0
        }()

        if canDelay {
            menu.addItem(NSMenuItem.separator())
            for seconds in state.allowedDelayOptions {
                let title = formattedDelay(seconds)
                let item = NSMenuItem(title: title, action: #selector(delayMenuItemSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = seconds
                item.identifier = NSUserInterfaceItemIdentifier("delay-\(seconds)")
                menu.addItem(item)
            }
        }

        // Recalculate button width based on new menu contents
        updateOptionsButtonWidth()
    }

    func formattedDelay(_ seconds: Int) -> String {
        if seconds >= 3600 && seconds % 3600 == 0 {
            let hrs = seconds / 3600
            return hrs == 1 ? "Remind in 1 hr" : "Remind in \(hrs) hrs"
        }
        if seconds % 60 == 0 {
            let mins = seconds / 60
            return mins == 1 ? "Remind in 1 min" : "Remind in \(mins) min"
        }
        return "Remind in \(seconds)s"
    }

    func disableAllDelayItems(reason: String? = nil) {
        // Now we fully remove delay items & separator by rebuilding without them.
        buildOptionsMenu()
    }

    func updateOptionsButtonWidth() {
        guard let menu = optionsMenu else { return }
        let padding: CGFloat = 24
        let font = optionsButton.font ?? .systemFont(ofSize: 11, weight: .semibold)
        var maxWidth = (optionsButton.title as NSString).size(withAttributes: [.font: font]).width
        for item in menu.items where !item.isSeparatorItem {
            let w = (item.title as NSString).size(withAttributes: [.font: font]).width
            if w > maxWidth { maxWidth = w }
        }
        let target = max(90, ceil(maxWidth + padding))
        if let c = optionsButtonWidthConstraint { c.constant = target } else {
            let cNew = optionsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: target)
            cNew.isActive = true
            optionsButtonWidthConstraint = cNew
        }
    }
}

// MARK: - Typography helpers & animation
private extension PanelController {
    func applyParagraphStyle(to label: NSTextField, tighten: Bool = false) {
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = label.lineBreakMode
        ps.lineHeightMultiple = tighten ? 0.9 : 1.0
        let attr = NSAttributedString(string: label.stringValue, attributes: [
            .font: label.font as Any,
            .foregroundColor: label.textColor as Any,
            .paragraphStyle: ps
        ])
        label.attributedStringValue = attr
    }
    private func animateIntro() {
        let target = self.panel.frame
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            self.panel.alphaValue = 1
            self.panel.setFrame(target, display: true)
            return
        }
        self.panel.contentView?.wantsLayer = true
        var start = target
        start.origin.y += 6
        self.panel.setFrame(start, display: false)
        self.panel.alphaValue = 0
        self.panel.contentView?.layer?.transform = CATransform3DMakeScale(0.98, 0.98, 1)
        NSAnimationContext.runAnimationGroup { [weak self] ctx in
            guard let self = self else { return }
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().alphaValue = 1
            self.panel.animator().setFrame(target, display: true)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                CATransaction.begin()
                let scaleAnim = CABasicAnimation(keyPath: "transform")
                scaleAnim.fromValue = CATransform3DMakeScale(0.98, 0.98, 1)
                scaleAnim.toValue = CATransform3DIdentity
                scaleAnim.duration = 0.25
                scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.contentView?.layer?.add(scaleAnim, forKey: "scale")
                self.panel.contentView?.layer?.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        }
    }
}

// MARK: - MiniActionButton

private final class MiniActionButton: NSButton {
    enum Style { case primary, secondary }
    private let styleType: Style
    private let actionHandler: () -> Void
    
    init(title: String, style: Style, handler: @escaping () -> Void) {
        self.styleType = style
        self.actionHandler = handler
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    font = .systemFont(ofSize: 11, weight: .semibold)
    heightAnchor.constraint(equalToConstant: 26).isActive = true
        updateAppearance(hover: false, pressed: false)
        
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
                                       owner: self,
                                       userInfo: nil))
        target = self
        self.action = #selector(fire)   // FIX: use self.action after renaming parameter
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    @objc private func fire() { actionHandler() }
    
    private var hovering = false { didSet { updateAppearance(hover: hovering, pressed: pressing) } }
    private var pressing = false { didSet { updateAppearance(hover: hovering, pressed: pressing) } }
    
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent)  { hovering = false; pressing = false }
    override func mouseDown(with event: NSEvent) {
        pressing = true
        super.mouseDown(with: event)
        pressing = false
    }
    
    private func updateAppearance(hover: Bool, pressed: Bool) {
        let duration: TimeInterval = 0.12
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            switch styleType {
            case .primary:
                let base = NSColor.controlAccentColor
                let bg: NSColor
                if pressed {
                    bg = base.blended(withFraction: 0.15, of: .black) ?? base
                } else if hover {
                    bg = base.blended(withFraction: 0.08, of: .black) ?? base
                } else {
                    bg = base
                }
                layer?.backgroundColor = bg.cgColor
                layer?.borderWidth = 0
                attributedTitle = NSAttributedString(string: title,
                                                     attributes: [.font: font as Any,
                                                                  .foregroundColor: NSColor.white])
            case .secondary:
                let stroke = NSColor.separatorColor.withAlphaComponent(0.5)
                let base = NSColor.controlAccentColor.withAlphaComponent(0.08)
                let bg: NSColor
                if pressed {
                    bg = NSColor.controlAccentColor.withAlphaComponent(0.25)
                } else if hover {
                    bg = NSColor.controlAccentColor.withAlphaComponent(0.16)
                } else {
                    bg = base
                }
                layer?.backgroundColor = bg.cgColor
                layer?.borderColor = stroke.cgColor
                layer?.borderWidth = 1
                attributedTitle = NSAttributedString(string: title,
                                                     attributes: [.font: font as Any,
                                                                  .foregroundColor: NSColor.labelColor])
            }
        }
    }
    
    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 24
        return s
    }
}
