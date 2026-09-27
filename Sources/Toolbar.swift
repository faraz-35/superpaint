// Toolbar — one floating pill on the active screen, bottom-center.
// It hops to whichever screen the mouse is on. Buttons are hand-drawn views:
// dark pill, gray icons, the accent only on the selected tool/swatch.

import Cocoa

let BG = NSColor(srgbRed: 0x16 / 255, green: 0x18 / 255, blue: 0x1c / 255, alpha: 0.97)   // 16181c
let BORDER = NSColor(srgbRed: 0x23 / 255, green: 0x26 / 255, blue: 0x2d / 255, alpha: 1)  // 23262d
let ICON = NSColor(srgbRed: 0x8a / 255, green: 0x8f / 255, blue: 0x98 / 255, alpha: 1)    // 8a8f98
let ACCENT = NSColor(srgbRed: 0x7b / 255, green: 0x8c / 255, blue: 0xff / 255, alpha: 1)  // 7b8cff
let HOVER = NSColor(srgbRed: 0x1c / 255, green: 0x1f / 255, blue: 0x24 / 255, alpha: 1)   // 1c1f24

func tintedSymbol(_ name: String, _ color: NSColor, point: CGFloat) -> NSImage {
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
    let configured = base.withSymbolConfiguration(.init(pointSize: point, weight: .medium))!
    let out = NSImage(size: configured.size)
    out.lockFocus()
    configured.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    color.set()
    NSRect(origin: .zero, size: configured.size).fill(using: .sourceIn)
    out.unlockFocus()
    return out
}

final class IconButton: NSView {
    let symbol: String
    let tooltip: String
    var isSelected = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var action: () -> Void = {}
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, tooltip: String, selected: Bool = false) {
        self.symbol = symbol
        self.tooltip = tooltip
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        self.isSelected = selected
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        toolTip = tooltip
    }

    required init?(coder: NSCoder) { fatalError("no coder path") }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        action()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        if isSelected {
            ACCENT.withAlphaComponent(0.18).setFill()
            r.fill()
        } else if hovering {
            HOVER.setFill()
            r.fill()
        }
        let color = !isEnabled ? ICON.withAlphaComponent(0.35)
            : isSelected ? ACCENT : ICON
        let img = tintedSymbol(symbol, color, point: 13)
        let size = img.size
        img.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                            width: size.width, height: size.height))
    }
}

final class SwatchButton: NSView {
    let color: NSColor
    var isSelected = false { didSet { needsDisplay = true } }
    var action: () -> Void = {}
    private var hovering = false { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 30))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("no coder path") }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { action() }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        if hovering { HOVER.setFill(); r.fill() }
        let d: CGFloat = 13
        let c = NSBezierPath(ovalIn: NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d))
        color.setFill()
        c.fill()
        if isSelected {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: (bounds.width - d) / 2 - 2.5, y: (bounds.height - d) / 2 - 2.5, width: d + 5, height: d + 5))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}

final class SizeButton: NSView {
    let dot: CGFloat
    var isSelected = false { didSet { needsDisplay = true } }
    var action: () -> Void = {}
    private var hovering = false { didSet { needsDisplay = true } }

    init(dot: CGFloat, tooltip: String) {
        self.dot = dot
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 30))
        toolTip = tooltip
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("no coder path") }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { action() }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        if hovering { HOVER.setFill(); r.fill() }
        let c = NSBezierPath(ovalIn: NSRect(x: (bounds.width - dot) / 2, y: (bounds.height - dot) / 2, width: dot, height: dot))
        (isSelected ? ACCENT : ICON).setFill()
        c.fill()
    }
}

final class ToolbarView: NSView {
    private var toolButtons: [Tool: IconButton] = [:]
    private var swatches: [SwatchButton] = []
    private var sizeButtons: [SizeButton] = []
    private var undoButton: IconButton!
    private var redoButton: IconButton!
    private var actionTail: [IconButton] = []

    static let height: CGFloat = 44
    /// The pill's width — the panel is sized from this, because AppKit fits
    /// the content view to whatever the window already is, not the reverse.
    static let width: CGFloat = layoutWidth()

    init(state: AnnotationState,
         undo: @escaping () -> Void, redo: @escaping () -> Void,
         clear: @escaping () -> Void, hide: @escaping () -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))

        for tool in Tool.allCases {
            let b = IconButton(symbol: tool.symbol, tooltip: tool.label, selected: state.tool == tool)
            b.action = { state.tool = tool }
            toolButtons[tool] = b
            addSubview(b)
        }
        for (i, color) in InkColors.enumerated() {
            let s = SwatchButton(color: color)
            s.isSelected = state.colorIndex == i
            s.action = { state.colorIndex = i }
            swatches.append(s)
            addSubview(s)
        }
        for (i, _) in InkSizes.enumerated() {
            let s = SizeButton(dot: [5, 8, 11][i], tooltip: "Size \(i + 1) (\(i + 1))")
            s.isSelected = state.sizeIndex == i
            s.action = { state.sizeIndex = i }
            sizeButtons.append(s)
            addSubview(s)
        }
        undoButton = IconButton(symbol: "arrow.uturn.backward", tooltip: "Undo (⌘Z)")
        undoButton.action = undo
        redoButton = IconButton(symbol: "arrow.uturn.forward", tooltip: "Redo (⇧⌘Z)")
        redoButton.action = redo
        let clearButton = IconButton(symbol: "trash", tooltip: "Clear this screen")
        clearButton.action = clear
        let hideButton = IconButton(symbol: "eye.slash", tooltip: "Hide (esc)")
        hideButton.action = hide
        actionTail = [undoButton!, redoButton, clearButton, hideButton]
        for b in actionTail { addSubview(b) }

        layoutButtons()
        sync(state: state)
    }

    required init?(coder: NSCoder) { fatalError("no coder path") }

    private static func layoutWidth() -> CGFloat {
        let n = Tool.allCases.count
        return 10 + CGFloat(n) * 30 + 3 * 13          // tools + 3 separators
            + CGFloat(InkColors.count) * 22 + CGFloat(InkSizes.count) * 22
            + 4 * 30 + 9
    }


    private func layoutButtons() {
        var x: CGFloat = 10
        for tool in Tool.allCases {
            toolButtons[tool]!.frame.origin = NSPoint(x: x, y: 7)
            x += 30
        }
        x = separator(at: x)
        for s in swatches { s.frame.origin = NSPoint(x: x, y: 7); x += 22 }
        x = separator(at: x)
        for s in sizeButtons { s.frame.origin = NSPoint(x: x, y: 7); x += 22 }
        x = separator(at: x)
        for b in actionTail { b.frame.origin = NSPoint(x: x, y: 7); x += 30 }
    }

    /// A thin vertical divider; returns the x after it.
    private func separator(at x: CGFloat) -> CGFloat {
        let v = DividerView(frame: NSRect(x: x + 5, y: 12, width: 1, height: 20))
        addSubview(v)
        return x + 13
    }

    func sync(state: AnnotationState) {
        for (tool, b) in toolButtons { b.isSelected = state.tool == tool }
        for (i, s) in swatches.enumerated() { s.isSelected = state.colorIndex == i }
        for (i, s) in sizeButtons.enumerated() { s.isSelected = state.sizeIndex == i }
    }

    /// Reflect a canvas's undo stacks (buttons dim when empty).
    func refresh(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }
}

final class DividerView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        BORDER.setFill()
        bounds.fill()
    }
}
