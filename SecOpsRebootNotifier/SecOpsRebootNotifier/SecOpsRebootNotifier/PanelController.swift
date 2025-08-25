import AppKit

class PanelController: NSObject {
    private var state: RebootState
    private let logger: ActionLogger
    private let config: ConfigManager?
    private var timer: DispatchSourceTimer?
    
    private let panelWidth: CGFloat = 340
    private let topMargin: CGFloat = 24   // fixed margin from top
    private let rightMargin: CGFloat = 24 // fixed margin from right
    private let cornerRadius: CGFloat = 14
    
    private var panel: NSPanel!
    private var backgroundView: NSVisualEffectView!
    
    private var iconView: NSImageView!
    private var titleLabel: NSTextField!
    private var bodyLabel: NSTextField!
    private var countdownLabel: NSTextField!
    private var rebootButton: MiniActionButton!
    private var delayButton: MiniActionButton!
    
    private var delayMenuController: DelayMenuController!
    
    init(state: RebootState, logger: ActionLogger, config: ConfigManager? = nil) {
        self.state = state
        self.logger = logger
        self.config = config
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
        panel.orderFrontRegardless()
    }
    
    private func buildUI() {
        panel = NSPanel(
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
        backgroundView.material = .underWindowBackground
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = cornerRadius
        backgroundView.layer?.masksToBounds = true
        panel.contentView?.addSubview(backgroundView)
        
        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(named: NSImage.cautionName)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        
        titleLabel = makeLabel(font: .systemFont(ofSize: 14, weight: .semibold),
                               color: .labelColor, lines: 1)
    titleLabel.stringValue = "Device Will Reboot Shortly"
        
    // Body label now wraps across multiple lines (max 4) instead of truncating tail
    bodyLabel = makeLabel(font: .systemFont(ofSize: 12),
                  color: .secondaryLabelColor, lines: 4, wrap: true)
    bodyLabel.stringValue = config?.customMessage ?? "Reboot required to complete important updates."
        
        countdownLabel = makeLabel(font: .systemFont(ofSize: 11),
                                   color: .tertiaryLabelColor, lines: 1)
        countdownLabel.stringValue = formattedCountdown()
        
        rebootButton = MiniActionButton(title: "Reboot Now", style: .primary) { [weak self] in
            self?.rebootNow()
        }
        delayButton = MiniActionButton(title: "Delay Reboot", style: .secondary) { [weak self] in
            self?.showDelayMenu()
        }
        
        let buttonStack = NSStackView(views: [rebootButton, delayButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(bodyLabel)
        textStack.addArrangedSubview(countdownLabel)
        
        backgroundView.addSubview(iconView)
        backgroundView.addSubview(textStack)
        backgroundView.addSubview(buttonStack)
        
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 14),
            iconView.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 14),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -14),
            
            buttonStack.topAnchor.constraint(greaterThanOrEqualTo: textStack.bottomAnchor, constant: 10),
            buttonStack.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -12),
            buttonStack.trailingAnchor.constraint(lessThanOrEqualTo: backgroundView.trailingAnchor, constant: -14),
        ])
        
        panel.contentView?.layoutSubtreeIfNeeded()
        let requiredHeight = buttonStack.frame.maxY + 12
        var frame = panel.frame
        frame.size.height = max(requiredHeight, 118)
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
        delayMenuController = DelayMenuController(options: state.allowedDelayOptions) { [weak self] seconds in
            self?.applyDelay(seconds)
        }
    }
    
    private func showDelayMenu() {
        guard let superview = delayButton.superview else { return }
        let menu = delayMenuController.menu
        let point = NSPoint(x: delayButton.frame.minX, y: delayButton.frame.minY - 4)
        menu.popUp(positioning: nil, at: point, in: superview)
    }
    
    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let remaining = self.state.remainingSeconds
            self.countdownLabel.stringValue = self.formattedCountdown()
            if remaining <= 60 { self.countdownLabel.textColor = .systemRed }
            if remaining <= 0 {
                self.timer?.cancel()
                self.handleExpiration()
            }
        }
        timer = t
        t.resume()
    }
    
    private func formattedCountdown() -> String {
        "Your system will reboot in \(CountdownFormatter.string(from: state.remainingSeconds))."
    }
    
    private func rebootNow() {
        logger.log(action: .rebootNow, state: state)
    config?.setRebootNow()
        quitApp()
    }
    
    private func applyDelay(_ seconds: Int) {
        guard state.applyDelay(seconds) else {
            NSSound.beep()
            return
        }
        logger.log(action: .delay(seconds: seconds), state: state)
        countdownLabel.textColor = .tertiaryLabelColor
        countdownLabel.stringValue = formattedCountdown()
        config?.applyDelay(seconds: seconds)
        // After applying delay, also decrement local visual state of remaining delay_counter if present.
        if let cfg = config {
            if cfg.delayCounter <= 0 { delayButton.isHidden = true }
        }
    }
    
    private func handleExpiration() {
        logger.log(action: .expired, state: state)
        quitApp()
    }

    private func applyConfigVisuals() {
        guard let cfg = config else { return }
        // Title tweak based on reboot_config and delay counter similar to Python logic
        switch cfg.rebootConfig {
        case .graceful:
            if cfg.delayCounter != 0 { titleLabel.stringValue = "Reboot Required" }
        case .forceAfterPatch:
            titleLabel.stringValue = "Device Will Reboot Shortly"
        case .other:
            break
        }
        // Hide delay button when counter exhausted or forced
        if cfg.delayCounter == 0 || cfg.rebootConfig == .forceAfterPatch { delayButton.isHidden = true; rebootButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true }
        // Hide countdown label when graceful & delays available (Python hides timer_label in that condition)
        if cfg.rebootConfig == .graceful && cfg.delayCounter > 0 { countdownLabel.isHidden = true }
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
    panel.setFrame(frame, display: true)
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
        font = .systemFont(ofSize: 12, weight: .semibold)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
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
                    bg = base.blended(withFraction: 0.28, of: .black) ?? base
                } else if hover {
                    bg = base.blended(withFraction: 0.18, of: .black) ?? base
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
