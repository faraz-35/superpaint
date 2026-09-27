// Canvas — the ink model and the per-screen drawing surface.
//
// Coordinates are flipped view-local points: origin at the screen's top-left,
// so an item drawn on a screen stays put across rearranges and reboots.

import Cocoa

// --- palette: Faraz's tokens, one accent ---

let InkColors: [NSColor] = [
    NSColor(srgbRed: 0xe6 / 255, green: 0xe7 / 255, blue: 0xea / 255, alpha: 1), // e6e7ea
    NSColor(srgbRed: 0x7b / 255, green: 0x8c / 255, blue: 0xff / 255, alpha: 1), // 7b8cff accent
    NSColor(srgbRed: 0xff / 255, green: 0x6b / 255, blue: 0x6b / 255, alpha: 1), // ff6b6b
    NSColor(srgbRed: 0x4a / 255, green: 0xde / 255, blue: 0x80 / 255, alpha: 1), // 4ade80
    NSColor(srgbRed: 0xfa / 255, green: 0xcc / 255, blue: 0x15 / 255, alpha: 1), // facc15
]

let InkSizes: [(stroke: CGFloat, text: CGFloat)] = [(2.5, 16), (4.5, 22), (7, 30)]

enum Tool: String, CaseIterable {
    case pen, highlighter, line, arrow, rect, ellipse, text, eraser

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .ellipse: return "oval"
        case .text: return "textformat"
        case .eraser: return "eraser"
        }
    }

    var label: String {
        switch self {
        case .pen: return "Pen (p)"
        case .highlighter: return "Highlighter (h)"
        case .line: return "Line (l, shift = 45°)"
        case .arrow: return "Arrow (a, shift = 45°)"
        case .rect: return "Rectangle (r, shift = square)"
        case .ellipse: return "Ellipse (o, shift = circle)"
        case .text: return "Text (t)"
        case .eraser: return "Eraser (e)"
        }
    }
}

/// Shared tool state across all screens — one toolbar, one pen.
final class AnnotationState {
    var tool: Tool = .pen { didSet { changed() } }
    var colorIndex = 1 { didSet { changed() } }   // accent
    var sizeIndex = 1 { didSet { changed() } }    // medium
    var onChange: () -> Void = {}

    var color: NSColor { InkColors[colorIndex] }
    var inkWidth: CGFloat { InkSizes[sizeIndex].stroke }
    var textSize: CGFloat { InkSizes[sizeIndex].text }

    func cycleColor() { colorIndex = (colorIndex + 1) % InkColors.count }

    private func changed() { onChange() }
}

// --- items ---

struct StrokeItem {
    var color: NSColor
    var width: CGFloat
    var alpha: CGFloat          // highlighter < 1
    var points: [NSPoint]
}

enum ShapeKind: String { case line, arrow, rect, ellipse }

struct ShapeItem {
    var kind: ShapeKind
    var color: NSColor
    var width: CGFloat
    var from: NSPoint
    var to: NSPoint
}

struct TextItem {
    var at: NSPoint             // top-left
    var string: String
    var color: NSColor
    var size: CGFloat
}

enum CanvasItem {
    case stroke(StrokeItem)
    case shape(ShapeItem)
    case text(TextItem)

    func draw() {
        switch self {
        case .stroke(let s):
            let path = smoothedPath(s.points)
            path.lineWidth = s.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            s.color.withAlphaComponent(s.alpha).setStroke()
            path.stroke()
        case .shape(let s):
            let path = shapePath(s)
            path.lineWidth = s.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            s.color.setStroke()
            path.stroke()
        case .text(let t):
            attributed(t).draw(at: t.at)
        }
    }

    func attributed(_ t: TextItem) -> NSAttributedString {
        attributedText(t)
    }

    /// Bounds for eraser hit-testing (slightly padded).
    func bounds() -> NSRect {
        let pad: CGFloat = 4
        switch self {
        case .stroke(let s):
            guard let first = s.points.first else { return .zero }
            var r = NSRect(origin: first, size: .zero)
            for p in s.points { r = r.union(NSRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -pad - s.width, dy: -pad - s.width)
        case .shape(let s):
            return NSRect(points: [s.from, s.to]).insetBy(dx: -pad - s.width, dy: -pad - s.width)
        case .text(let t):
            let size = attributed(t).size()
            return NSRect(origin: t.at, size: size).insetBy(dx: -pad, dy: -pad)
        }
    }

    /// True if the point sits on the item's ink (within `t` points).
    func hit(_ p: NSPoint, t: CGFloat) -> Bool {
        switch self {
        case .stroke(let s):
            guard s.points.count > 1 else {
                guard let only = s.points.first else { return false }
                return hypot(p.x - only.x, p.y - only.y) <= t + s.width / 2
            }
            for i in 1..<s.points.count
            where distance(p, s.points[i - 1], s.points[i]) <= t + s.width / 2 { return true }
            return false
        case .shape(let s):
            let half = s.width / 2 + t
            switch s.kind {
            case .line, .arrow:
                return distance(p, s.from, s.to) <= half
            case .rect:
                let r = NSRect(points: [s.from, s.to])
                return r.insetBy(dx: -half, dy: -half).contains(p)
                    && !r.insetBy(dx: half, dy: half).contains(p)
            case .ellipse:
                let r = NSRect(points: [s.from, s.to])
                let c = NSPoint(x: r.midX, y: r.midY)
                let outer = ratio(p, c, r.width / 2 + half, r.height / 2 + half)
                let inner = ratio(p, c, max(r.width / 2 - half, 0.01), max(r.height / 2 - half, 0.01))
                return outer <= 1 && inner >= 1
            }
        case .text:
            return bounds().contains(p)
        }
    }
}

private func ratio(_ p: NSPoint, _ c: NSPoint, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
    let x = (p.x - c.x) / a, y = (p.y - c.y) / b
    return x * x + y * y
}

func attributedText(_ t: TextItem) -> NSAttributedString {
    NSAttributedString(string: t.string, attributes: [
        .font: NSFont.systemFont(ofSize: t.size, weight: .medium),
        .foregroundColor: t.color,
    ])
}

private func distance(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
    let abx = b.x - a.x, aby = b.y - a.y
    let len2 = abx * abx + aby * aby
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
    return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
}

/// Freehand smoothing: quadratic curves through segment midpoints.
func smoothedPath(_ pts: [NSPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    guard !pts.isEmpty else { return path }
    path.move(to: pts[0])
    guard pts.count > 1 else { return path }
    for i in 1..<pts.count {
        let mid = NSPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
        path.curve(to: mid, controlPoint1: pts[i - 1], controlPoint2: pts[i - 1])
    }
    path.line(to: pts[pts.count - 1])
    return path
}

func shapePath(_ s: ShapeItem) -> NSBezierPath {
    let path = NSBezierPath()
    switch s.kind {
    case .line:
        path.move(to: s.from)
        path.line(to: s.to)
    case .arrow:
        path.move(to: s.from)
        path.line(to: s.to)
        let angle = atan2(s.to.y - s.from.y, s.to.x - s.from.x)
        let head: CGFloat = 9 + s.width * 1.8
        let spread: CGFloat = .pi / 7
        for delta in [spread, -spread] {
            path.move(to: s.to)
            path.line(to: NSPoint(x: s.to.x - head * cos(angle + delta),
                                  y: s.to.y - head * sin(angle + delta)))
        }
    case .rect:
        path.append(NSBezierPath(rect: NSRect(points: [s.from, s.to])))
    case .ellipse:
        path.append(NSBezierPath(ovalIn: NSRect(points: [s.from, s.to])))
    }
    return path
}

extension NSRect {
    init(points pts: [NSPoint]) {
        var r = NSRect(origin: pts[0], size: .zero)
        for p in pts.dropFirst() { r = r.union(NSRect(origin: p, size: .zero)) }
        self = r
    }
}

// --- model with undo ---
// Each change carries both directions; undo reverts the last change, redo
// re-applies it. LIFO keeps every index valid.

final class CanvasModel {
    struct Change {
        let apply: () -> Void
        let revert: () -> Void
    }

    private(set) var items: [CanvasItem] = []
    private var undoStack: [Change] = []
    private var redoStack: [Change] = []
    var onChange: () -> Void = {}

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func record(apply: @escaping () -> Void, revert: @escaping () -> Void) {
        apply()
        undoStack.append(Change(apply: apply, revert: revert))
        redoStack.removeAll()
        onChange()
    }

    func commit(_ item: CanvasItem) {
        record(apply: { self.items.append(item) },
               revert: { _ = self.items.popLast() })
    }

    /// Erase the topmost item under the point; returns true if something went.
    @discardableResult
    func erase(at p: NSPoint) -> Bool {
        guard let i = items.lastIndex(where: { $0.hit(p, t: 6) }) else { return false }
        let item = items[i]
        record(apply: { self.items.remove(at: i) },
               revert: { self.items.insert(item, at: i) })
        return true
    }

    func clearAll() {
        guard !items.isEmpty else { return }
        let old = items
        record(apply: { self.items = [] },
               revert: { self.items = old })
    }

    func undo() {
        guard let change = undoStack.popLast() else { return }
        change.revert()
        redoStack.append(change)
        onChange()
    }

    func redo() {
        guard let change = redoStack.popLast() else { return }
        change.apply()
        undoStack.append(change)
        onChange()
    }
}

// --- the per-screen surface ---

final class CanvasView: NSView {
    let model: CanvasModel
    let state: AnnotationState
    weak var controller: Controller?

    var isActive = false { didSet { needsDisplay = true } }
    private var live: CanvasItem?
    /// Text being typed: captured directly in keyDown and rendered in draw(),
    /// so no NSTextField/field editor exists to paint its own background.
    private var pendingText: TextItem?

    init(model: CanvasModel, state: AnnotationState) {
        self.model = model
        self.state = state
        super.init(frame: .zero)
        model.onChange = { [weak self] in
            self?.needsDisplay = true
            self?.controller?.modelChanged()   // keeps the undo/redo buttons honest
        }
    }

    required init?(coder: NSCoder) { fatalError("no coder path") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // --- drawing ---

    override func draw(_ dirtyRect: NSRect) {
        for item in model.items { item.draw() }
        live?.draw()

        if let t = pendingText {
            let attr = attributedText(t)
            attr.draw(at: t.at)
            let width = attr.size().width
            t.color.withAlphaComponent(0.75).setFill()   // static caret
            NSRect(x: t.at.x + width + 1, y: t.at.y, width: 2, height: t.size).fill()
        }

        if isActive, model.items.isEmpty, live == nil, pendingText == nil {
            let hint = NSAttributedString(string: "draw anywhere  ·  esc to hide  ·  ⌘⌥P toggles", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(srgbRed: 0x5c / 255, green: 0x60 / 255, blue: 0x68 / 255, alpha: 1),
            ])
            let size = hint.size()
            hint.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 84))
        }
    }

    // --- input ---

    private func point(_ event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        if pendingText != nil { commitPendingText() }   // click elsewhere = keep the text
        let p = point(event)
        switch state.tool {
        case .pen, .highlighter:
            let isMarker = state.tool == .highlighter
            live = .stroke(StrokeItem(
                color: state.color,
                width: isMarker ? state.inkWidth * 3 : state.inkWidth,
                alpha: isMarker ? 0.35 : 1,
                points: [p]))
        case .line, .arrow, .rect, .ellipse:
            live = .shape(ShapeItem(kind: ShapeKind(rawValue: state.tool.rawValue)!,
                                    color: state.color, width: state.inkWidth,
                                    from: p, to: p))
        case .text:
            beginText(at: p)
        case .eraser:
            model.erase(at: p)
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.toolbarFollowedMouse(to: window?.screen)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        let shift = event.modifierFlags.contains(.shift)
        switch live {
        case .stroke(var s):
            if shift, let start = s.points.first {
                s.points = [start, p]   // shift-pen = ruler: straight from the stroke start
            } else {
                if let last = s.points.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { return }
                s.points.append(p)
            }
            live = .stroke(s)
        case .shape(var s):
            s.to = constrained(s.kind, from: s.from, to: p, shift: shift)
            live = .shape(s)
        case .text:
            break
        case nil:
            if state.tool == .eraser { model.erase(at: p) }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = live else { return }
        live = nil
        switch item {
        case .stroke(let s) where s.points.count < 2:
            // a click should still leave a dot
            model.commit(.stroke(StrokeItem(color: s.color, width: s.width, alpha: s.alpha,
                                            points: [s.points[0], NSPoint(x: s.points[0].x + 0.5, y: s.points[0].y)])))
        default:
            model.commit(item)
        }
        needsDisplay = true
    }

    private func constrained(_ kind: ShapeKind, from: NSPoint, to: NSPoint, shift: Bool) -> NSPoint {
        guard shift else { return to }
        switch kind {
        case .rect, .ellipse:
            let d = max(abs(to.x - from.x), abs(to.y - from.y))
            return NSPoint(x: from.x + (to.x >= from.x ? d : -d),
                           y: from.y + (to.y >= from.y ? d : -d))
        case .line, .arrow:
            let dx = to.x - from.x, dy = to.y - from.y
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return NSPoint(x: from.x + len * cos(angle), y: from.y + len * sin(angle))
        }
    }

    // --- text tool ---
    // Click plants the caret; typing appends; enter commits, esc discards.

    private func beginText(at p: NSPoint) {
        commitPendingText()
        pendingText = TextItem(at: p, string: "", color: state.color, size: state.textSize)
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func commitPendingText() {
        guard var t = pendingText else { return }
        pendingText = nil
        t.string = t.string.trimmingCharacters(in: .whitespaces)
        if !t.string.isEmpty { model.commit(.text(t)) }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if pendingText != nil {   // typing mode swallows everything, incl. tool keys
            guard !cmd, !flags.contains(.control) else { return }
            switch key {
            case "\r", "\n":
                commitPendingText()
            case "\u{1b}":                       // esc = discard
                pendingText = nil
                needsDisplay = true
            case "\u{7f}", "\u{8}":              // delete / backspace
                if var t = pendingText, !t.string.isEmpty {
                    t.string.removeLast()
                    pendingText = t
                    needsDisplay = true
                }
            default:
                if let chars = event.characters,
                   chars.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 0xF700 }),
                   var t = pendingText {
                    t.string += chars            // printable input only (0xF700+ = arrows etc.)
                    pendingText = t
                    needsDisplay = true
                }
            }
            return
        }

        if cmd, key == "z" {
            flags.contains(.shift) ? model.redo() : model.undo()
            return
        }
        if key == "\u{1b}" {   // esc
            controller?.deactivate()
            return
        }
        guard !cmd else { return super.keyDown(with: event) }

        switch key {
        case "p": state.tool = .pen
        case "h": state.tool = .highlighter
        case "l": state.tool = .line
        case "a": state.tool = .arrow
        case "r": state.tool = .rect
        case "o": state.tool = .ellipse
        case "t": state.tool = .text
        case "e": state.tool = .eraser
        case "c": state.cycleColor()
        case "1", "2", "3": state.sizeIndex = Int(key)! - 1
        default: break
        }
    }
}
