// Panels — the window layer. NSPanel is the window class AeroSpace never
// manages (the SketchyBar trick), so the overlay survives workspace switches
// without being parked at a screen corner. Non-activating: using the canvas
// never steals focus from the app being annotated.

import Cocoa

final class DrawPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // shortcuts + the text tool need keys

    // macOS floors windows below the menu-bar band; the canvas must reach y=0.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar        // above everything, SketchyBar included
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        hidesOnDeactivate = false // an NSPanel default hides it whenever the app deactivates
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true // hidden until activated
        acceptsMouseMovedEvents = true   // the toolbar hops screens with the mouse
    }
}

final class ToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: ToolbarView.width, height: ToolbarView.height),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // One level above the canvases: same-level windows reorder to front
        // when clicked, which buried the toolbar under the canvas after the
        // first stroke — toolbar clicks then landed as strokes. A higher
        // level can't lose.
        level = .statusBar + 1
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}
