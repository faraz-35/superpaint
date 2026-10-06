// Superpaint — draw over anything.
//
// ⌘⌥P turns the whole desktop into a canvas (every screen); esc hides it and
// gives clicks back. Hidden ≠ lost: ink stays until cleared. ⌘⌥B (or b, or
// the hand button) browses: the ink stays up but clicks and scrolling pass
// through to the apps underneath. No dock icon, no focus stealing — a
// status-bar pencil and the hotkeys are the whole UI.

import Cocoa
import Carbon.HIToolbox

let state = AnnotationState()

final class Controller {
    private struct Screen {
        let panel: DrawPanel
        let canvas: CanvasView
    }

    private var screens: [CGDirectDisplayID: Screen] = [:]
    private var models: [CGDirectDisplayID: CanvasModel] = [:]   // ink outlives toggles
    private let toolbarPanel = ToolbarPanel()
    private lazy var toolbarView = makeToolbar()
    private var isActive = false
    private var isBrowsing = false
    private let hotkeys = HotKeys()

    func start() {
        state.onChange = { [weak self] in self?.syncToolbar() }
        toolbarPanel.contentView = toolbarView

        hotkeys.add(key: kVK_ANSI_P, mods: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.toggle()
        }
        hotkeys.add(key: kVK_ANSI_B, mods: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.toggleBrowse()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        rebuild()
    }

    // --- screens ---

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    }

    private var mouseScreen: NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) }
    }

    private func canvas(on screen: NSScreen?) -> CanvasView? {
        guard let screen else { return nil }
        return screens[displayID(screen)]?.canvas
    }

    @objc private func rebuild() {
        for screen in screens.values {
            screen.panel.orderOut(nil)
            screen.panel.contentView = nil
        }
        screens.removeAll()
        for s in NSScreen.screens {
            let id = displayID(s)
            let model = models[id] ?? {
                let m = CanvasModel()
                models[id] = m
                return m
            }()
            let canvas = CanvasView(model: model, state: state)
            canvas.controller = self
            canvas.isActive = isActive
            canvas.isBrowsing = isBrowsing
            let panel = DrawPanel(screen: s)
            panel.contentView = canvas
            if isActive {
                panel.ignoresMouseEvents = isBrowsing
                panel.orderFrontRegardless()
            }
            screens[id] = Screen(panel: panel, canvas: canvas)
        }
        if isActive { placeToolbar(on: mouseScreen ?? NSScreen.screens.first); toolbarPanel.orderFrontRegardless() }
    }

    // --- activate / deactivate ---

    func toggle() { isActive ? deactivate() : activate() }

    func activate() {
        isActive = true
        rebuild()
        let keyScreen = mouseScreen ?? NSScreen.screens.first
        if let keyScreen, let screen = screens[displayID(keyScreen)] {
            screen.panel.makeKeyAndOrderFront(nil)   // shortcuts + text land here
        }
        placeToolbar(on: mouseScreen ?? keyScreen)
        toolbarPanel.orderFrontRegardless()
    }

    func deactivate() {
        isActive = false
        isBrowsing = false
        toolbarView.setBrowsing(false)
        for screen in screens.values {
            screen.canvas.commitPendingText()
            screen.canvas.isActive = false
            screen.canvas.isBrowsing = false
            screen.panel.ignoresMouseEvents = true
            screen.panel.orderOut(nil)
        }
        toolbarPanel.orderOut(nil)
    }

    // --- browse mode ---

    /// Browse mode: the canvas steps out of the mouse's way — scrolling,
    /// clicks and drags reach the apps underneath. The toolbar stays live and
    /// the ink stays visible; b, ⌘⌥B or the hand button returns to drawing.
    func toggleBrowse() { isBrowsing ? exitBrowse() : enterBrowse() }

    private func enterBrowse() {
        guard isActive, !isBrowsing else { return }
        isBrowsing = true
        for screen in screens.values {
            screen.canvas.commitPendingText()
            screen.canvas.isBrowsing = true
            screen.panel.ignoresMouseEvents = true
        }
        toolbarView.setBrowsing(true)
    }

    private func exitBrowse() {
        guard isBrowsing else { return }
        isBrowsing = false
        for screen in screens.values {
            screen.canvas.isBrowsing = false
            screen.panel.ignoresMouseEvents = false
        }
        toolbarView.setBrowsing(false)
        let keyScreen = mouseScreen ?? NSScreen.screens.first
        if let keyScreen, let screen = screens[displayID(keyScreen)] {
            screen.panel.makeKeyAndOrderFront(nil)   // tool shortcuts land here again
        }
    }

    /// An explicit tool pick always ends browse mode; leaving select drops
    /// the selection — the ants only mean something in select mode.
    func pick(_ tool: Tool) {
        exitBrowse()
        if tool != .select { for s in screens.values { s.canvas.model.clearSelection() } }
        state.tool = tool
    }

    // --- toolbar ---

    private func makeToolbar() -> ToolbarView {
        ToolbarView(state: state,
                    pick: { self.pick($0) },
                    undo: { self.targetCanvas()?.model.undo() },
                    redo: { self.targetCanvas()?.model.redo() },
                    clear: { self.targetCanvas()?.model.clearAll() },
                    hide: { self.deactivate() },
                    browse: { self.toggleBrowse() })
    }

    /// The canvas the toolbar acts on: the screen it sits on, else the mouse's.
    private func targetCanvas() -> CanvasView? {
        canvas(on: toolbarPanel.screen ?? mouseScreen)
    }

    private func placeToolbar(on screen: NSScreen?) {
        guard let screen else { return }
        toolbarPanel.setFrame(NSRect(x: screen.frame.midX - ToolbarView.width / 2,
                                     y: screen.frame.minY + 16,
                                     width: ToolbarView.width, height: ToolbarView.height),
                              display: true)
    }

    /// The mouse crossed onto another screen — the toolbar follows.
    func toolbarFollowedMouse(to screen: NSScreen?) {
        guard isActive, let screen else { return }
        if displayID(screen) != displayID(toolbarPanel.screen ?? screen) {
            placeToolbar(on: screen)
        }
    }

    private func syncToolbar() {
        toolbarView.sync(state: state)
        if let c = targetCanvas() {
            toolbarView.refresh(canUndo: c.model.canUndo, canRedo: c.model.canRedo)
        }
    }

    /// A canvas's model changed (draw/erase/undo) — refresh the undo buttons.
    func modelChanged() {
        if let c = targetCanvas() {
            toolbarView.refresh(canUndo: c.model.canUndo, canRedo: c.model.canRedo)
        }
    }

    // --- status item ---

    func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = tintedSymbol("scribble.variable", .white, point: 13)
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Toggle Canvas", action: #selector(toggleAction), keyEquivalent: "p")
        toggle.keyEquivalentModifierMask = [.command, .option]
        toggle.target = self
        menu.addItem(toggle)
        let browse = NSMenuItem(title: "Browse Mode", action: #selector(browseAction), keyEquivalent: "b")
        browse.keyEquivalentModifierMask = [.command, .option]
        browse.target = self
        menu.addItem(browse)
        let clear = NSMenuItem(title: "Clear This Screen", action: #selector(clearAction), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Superpaint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    @objc private func toggleAction() { toggle() }

    @objc private func browseAction() { toggleBrowse() }

    @objc private func clearAction() {
        let target = isActive ? targetCanvas() : canvas(on: mouseScreen)
        target?.model.clearAll()
    }
}

/// Global hotkeys via Carbon — no Accessibility permission needed.
final class HotKeys {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private let signature = OSType(0x5370_6170)   // 'Spap'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ctx = Unmanaged.passRetained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return noErr }
            Unmanaged<HotKeys>.fromOpaque(userData!).takeUnretainedValue().handlers[id.id]?()
            return noErr
        }, 1, &spec, ctx, nil)
    }

    func add(key: Int, mods: UInt32, handler: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?   // Carbon returns paramErr (-50) for a nil out-pointer
        let status = RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        precondition(status == noErr, "RegisterEventHotKey failed: \(status)")
        refs.append(ref)   // refs live for the process lifetime; hotkeys are never unregistered
    }
}

let controller = Controller()
let appDelegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = appDelegate
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.makeStatusItem()
        controller.start()
    }
}
