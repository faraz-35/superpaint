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
    case select, pen, highlighter, line, arrow, rect, ellipse, text, eraser

    var symbol: String {
        switch self {
        case .select: return "rectangle.dashed"
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
        case .select: return "Select (v) — drag a box, drag inside it to move, ⌘C/⌘V, ⌫"
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
    var id = UUID()   // stable across moves — selection and undo key off this, not indices
    var color: NSColor
    var width: CGFloat
    var alpha: CGFloat          // highlighter < 1
    var points: [NSPoint]
}

enum ShapeKind: String { case line, arrow, rect, ellipse }

struct ShapeItem {
    var id = UUID()
    var kind: ShapeKind
    var color: NSColor
    var width: CGFloat
    var from: NSPoint
    var to: NSPoint
}

struct TextItem {
    var id = UUID()
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

    var id: UUID {
        switch self {
        case .stroke(let s): return s.id
        case .shape(let s): return s.id
        case .text(let t): return t.id
        }
    }

    /// A copy with a fresh identity — pasted/duplicated ink stays independent.
    func reID() -> CanvasItem {
        switch self {
        case .stroke(var s): s.id = UUID(); return .stroke(s)
        case .shape(var s): s.id = UUID(); return .shape(s)
        case .text(var t): t.id = UUID(); return .text(t)
        }
    }

    func translated(_ d: CGVector) -> CanvasItem {
        switch self {
        case .stroke(var s):
            s.points = s.points.map { NSPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
            return .stroke(s)
        case .shape(var s):
            s.from = NSPoint(x: s.from.x + d.dx, y: s.from.y + d.dy)
            s.to = NSPoint(x: s.to.x + d.dx, y: s.to.y + d.dy)
            return .shape(s)
        case .text(var t):
            t.at = NSPoint(x: t.at.x + d.dx, y: t.at.y + d.dy)
            return .text(t)
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

    // --- selection ---
    // Selected ids, not indices: undo/redo and delete reorder items freely.

    private(set) var selection = Set<UUID>() { didSet { onChange() } }

    /// Marquee result: everything intersecting the rect, replacing the selection.
    func select(in rect: NSRect) {
        selection = Set(items.filter { $0.bounds().intersects(rect) }.map(\.id))
    }

    /// A click picks the topmost item under it — or clears, on empty canvas.
    func selectTopmost(at p: NSPoint) {
        selection = items.last { $0.hit(p, t: 4) }.map { Set([$0.id]) } ?? []
    }

    func clearSelection() {
        selection = []
    }

    func selectedItems() -> [CanvasItem] {
        items.filter { selection.contains($0.id) }
    }

    /// Union of the selected ink's bounds; nil when the selection is empty.
    func selectionBounds() -> NSRect? {
        let sel = selectedItems()
        guard let first = sel.first else { return nil }
        var r = first.bounds()
        for i in sel.dropFirst() { r = r.union(i.bounds()) }
        return r
    }

    /// One undo step per drag, however long: the view shows the move live and
    /// commits it here on mouse-up.
    func translateSelection(by d: CGVector) {
        let ids = selection
        guard !ids.isEmpty else { return }
        record(apply: { self.translate(ids: ids, by: d) },
               revert: { self.translate(ids: ids, by: CGVector(dx: -d.dx, dy: -d.dy)) })
    }

    private func translate(ids: Set<UUID>, by d: CGVector) {
        items = items.map { ids.contains($0.id) ? $0.translated(d) : $0 }
    }

    func deleteSelected() {
        let removed = items.enumerated().filter { selection.contains($0.element.id) }
        let ids = selection
        guard !removed.isEmpty else { return }
        record(apply: {
                self.items.removeAll { ids.contains($0.id) }
                self.selection = []
               },
               revert: {   // ascending order puts every item back where it was
                for (i, item) in removed { self.items.insert(item, at: i) }
                self.selection = ids
               })
    }

    /// Paste copies (fresh ids) with their bounds' origin at `dest`; the pasted
    /// set becomes the selection. Returns the new ids.
    @discardableResult
    func paste(_ clipboard: [CanvasItem], at dest: NSPoint) -> Set<UUID> {
        let copies = clipboard.map { $0.reID() }
        guard let first = copies.first else { return [] }
        var b = first.bounds()
        for i in copies.dropFirst() { b = b.union(i.bounds()) }
        let placed = copies.map { $0.translated(CGVector(dx: dest.x - b.minX, dy: dest.y - b.minY)) }
        let ids = Set(placed.map(\.id))
        record(apply: {
                self.items.append(contentsOf: placed)
                self.selection = ids
               },
               revert: {
                self.items.removeAll { ids.contains($0.id) }
                self.selection = []
               })
        return ids
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

// --- the ink clipboard ---
// Copy on one screen, paste on any. Coordinates stay source-screen-local; the
// pasting canvas repositions if they'd land outside it.

final class InkClipboard {
    static let shared = InkClipboard()
    private(set) var items: [CanvasItem] = []
    private(set) var bounds: NSRect = .zero

    func copy(_ items: [CanvasItem]) {
        guard let first = items.first else { return }
        self.items = items
        var b = first.bounds()
        for i in items.dropFirst() { b = b.union(i.bounds()) }
        bounds = b
    }
}

// --- the per-screen surface ---

final class CanvasView: NSView {
    let model: CanvasModel
    let state: AnnotationState
    weak var controller: Controller?

    var isActive = false { didSet { needsDisplay = true } }
    var isBrowsing = false { didSet { needsDisplay = true } }
    // Select tool: the box being dragged, and a move-in-progress (offset shown
    // live, committed to the model as one undo step on mouse-up).
    private var marquee: (anchor: NSPoint, current: NSPoint)?
    private var moveOrigin: NSPoint?
    private var dragDelta = CGVector(dx: 0, dy: 0)
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
        for item in model.items {
            if model.selection.contains(item.id), dragDelta.dx != 0 || dragDelta.dy != 0 {
                NSGraphicsContext.current?.saveGraphicsState()
                let xform = NSAffineTransform()
                xform.translateX(by: dragDelta.dx, yBy: dragDelta.dy)
                xform.concat()
                item.draw()
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                item.draw()
            }
        }
        live?.draw()

        if let t = pendingText {
            let attr = attributedText(t)
            attr.draw(at: t.at)
            let width = attr.size().width
            t.color.withAlphaComponent(0.75).setFill()   // static caret
            NSRect(x: t.at.x + width + 1, y: t.at.y, width: 2, height: t.size).fill()
        }

        if isActive, model.items.isEmpty, live == nil, pendingText == nil {
            let text = isBrowsing
                ? "browsing — clicks and scrolling go to the page  ·  b or ⌘⌥B draws again"
                : "draw anywhere  ·  esc to hide  ·  ⌘⌥P toggles"
            let hint = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(srgbRed: 0x5c / 255, green: 0x60 / 255, blue: 0x68 / 255, alpha: 1),
            ])
            let size = hint.size()
            hint.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 84))
        }

        if state.tool == .select {
            if let sb = model.selectionBounds() {
                drawMarchingAnts(sb.offsetBy(dx: dragDelta.dx, dy: dragDelta.dy).insetBy(dx: -3, dy: -3))
            }
            if let m = marquee { drawMarchingAnts(NSRect(points: [m.anchor, m.current])) }
        }
    }

    /// The selection's visual: faint accent fill, dashed accent border.
    private func drawMarchingAnts(_ r: NSRect) {
        guard r.width > 0 || r.height > 0 else { return }
        ACCENT.withAlphaComponent(0.07).setFill()
        r.fill()
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        ACCENT.setStroke()
        path.lineWidth = 1.2
        path.setLineDash([5, 3], count: 2, phase: 0)
        path.stroke()
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
        case .select:
            if let sb = model.selectionBounds(), sb.insetBy(dx: -6, dy: -6).contains(p) {
                moveOrigin = p   // grab inside the selection = move it
            } else {
                marquee = (p, p)
            }
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.toolbarFollowedMouse(to: window?.screen)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if let origin = moveOrigin {
            dragDelta = CGVector(dx: p.x - origin.x, dy: p.y - origin.y)
            needsDisplay = true
            return
        }
        if var m = marquee {
            m.current = p
            marquee = m
            needsDisplay = true
            return
        }
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
        let p = point(event)
        if state.tool == .select { finishSelect(at: p); needsDisplay = true; return }
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

    // --- select tool ---
    // Drag a box: everything intersecting it is selected. Drag inside the
    // ants to move. ⌘C copies, ⌘V pastes a nudged, pre-selected copy, ⌫
    // deletes, esc drops the selection (a second esc hides the canvas).

    private func finishSelect(at p: NSPoint) {
        if moveOrigin != nil {
            moveOrigin = nil
            if abs(dragDelta.dx) > 0.5 || abs(dragDelta.dy) > 0.5 {
                model.translateSelection(by: dragDelta)
            }
            dragDelta = CGVector(dx: 0, dy: 0)
            return
        }
        guard let m = marquee else { return }
        marquee = nil
        let r = NSRect(points: [m.anchor, m.current])
        if r.width < 3, r.height < 3 {
            model.selectTopmost(at: p)   // a plain click picks the one item under it
        } else {
            model.select(in: r)
        }
    }

    private func copySelection() {
        InkClipboard.shared.copy(model.selectedItems())
    }

    private func pasteFromClipboard() {
        let clip = InkClipboard.shared
        guard !clip.items.isEmpty else { return }
        // Same-screen coordinates land a nudge from the original; a copy from
        // a bigger/other screen centers itself instead of falling off-edge.
        let b = clip.bounds
        let dest = b.maxX <= bounds.width && b.maxY <= bounds.height
            ? NSPoint(x: b.minX + 14, y: b.minY + 14)
            : NSPoint(x: (bounds.width - b.width) / 2, y: (bounds.height - b.height) / 2)
        model.paste(clip.items, at: dest)
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
        if cmd, key == "c" { copySelection(); return }
        if cmd, key == "v" { pasteFromClipboard(); return }
        if key == "\u{1b}" {   // esc drops the selection first, then hides
            model.selection.isEmpty ? controller?.deactivate() : model.clearSelection()
            return
        }
        if !model.selection.isEmpty, key == "\u{7f}" || key == "\u{F728}" {
            model.deleteSelected()
            return
        }
        guard !cmd else { return super.keyDown(with: event) }

        switch key {
        case "v": controller?.pick(.select)
        case "p": controller?.pick(.pen)
        case "h": controller?.pick(.highlighter)
        case "l": controller?.pick(.line)
        case "a": controller?.pick(.arrow)
        case "r": controller?.pick(.rect)
        case "o": controller?.pick(.ellipse)
        case "t": controller?.pick(.text)
        case "e": controller?.pick(.eraser)
        case "b": controller?.toggleBrowse()
        case "c": state.cycleColor()
        case "1", "2", "3": state.sizeIndex = Int(key)! - 1
        default: break
        }
    }
}
