import AppKit

// Lightweight custom button to avoid default aqua pill & keep consistent styling on macOS 11+
final class ModernButton: NSButton {
    enum Style {
        case primary
        case secondary
    }
    
    private let actionHandler: () -> Void
    private let customStyle: Style
    private let fixedWidth: CGFloat?
    
    init(title: String, style: Style, width: CGFloat? = nil, action: @escaping () -> Void) {
        self.actionHandler = action
        self.customStyle = style
        self.fixedWidth = width
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(trigger)
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        updateColors(hover: false, pressed: false)
        
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
                                       owner: self,
                                       userInfo: nil))
        
        // Content margins
        contentTintColor = (customStyle == .primary) ? .white : .labelColor
        let pH: CGFloat = 14
        let pV: CGFloat = 7
        let attr = NSAttributedString(string: title,
                                      attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                   .foregroundColor: contentTintColor!])
        attributedTitle = attr
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        if let w = width {
            widthAnchor.constraint(equalToConstant: w).isActive = true
        } else {
            // Let intrinsic width drive; add horizontal padding by overriding intrinsicContentSize?
            // We'll just add a constraint for min width.
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        }
        // Add internal content insets with a dummy layer inset approach
        let insetLayer = CALayer()
        insetLayer.frame = bounds.insetBy(dx: -pH, dy: -pV)
        // Not strictly necessary; using contentEdgeInsets would be ideal (not on AppKit).
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc private func trigger() {
        actionHandler()
    }
    
    private var isHovering = false {
        didSet { updateColors(hover: isHovering, pressed: false) }
    }
    private var isPressing = false {
        didSet { updateColors(hover: isHovering, pressed: isPressing) }
    }
    
    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }
    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressing = false
    }
    override func mouseDown(with event: NSEvent) {
        isPressing = true
        super.mouseDown(with: event)
        isPressing = false
    }
    
    private func updateColors(hover: Bool, pressed: Bool) {
        let duration: TimeInterval = 0.15
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            switch customStyle {
            case .primary:
                let base = NSColor.controlAccentColor
                let bg: NSColor
                if pressed {
                    bg = base.blended(withFraction: 0.25, of: .black) ?? base
                } else if hover {
                    bg = base.blended(withFraction: 0.18, of: .black) ?? base
                } else {
                    bg = base
                }
                layer?.backgroundColor = bg.cgColor
                layer?.borderWidth = 0
                contentTintColor = .white
            case .secondary:
                let stroke = NSColor.separatorColor.withAlphaComponent(0.5)
                let fillBase = NSColor.controlAccentColor.withAlphaComponent(0.10)
                let fillHover = NSColor.controlAccentColor.withAlphaComponent(0.18)
                let fillPressed = NSColor.controlAccentColor.withAlphaComponent(0.28)
                let fill: NSColor = pressed ? fillPressed : (hover ? fillHover : fillBase)
                layer?.backgroundColor = fill.cgColor
                layer?.borderColor = stroke.cgColor
                layer?.borderWidth = 1
                contentTintColor = .labelColor
            }
        }
    }
    
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 24 // horizontal padding
        return size
    }
}