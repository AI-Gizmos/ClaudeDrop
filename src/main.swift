import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// The global hotkey: Control + Option + D. Change these two lines to rebind it.
let hotKeyCode = UInt32(kVK_ANSI_D)
let hotKeyModifiers = UInt32(controlKey | optionKey)
let hotKeyLabel = "⌃⌥D"

// MARK: Command-line mode (also used for testing): ClaudeDrop --add <project> <file|url|text>...

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--add") {
    let rest = Array(arguments[(flag + 1)...])
    guard rest.count >= 2 else {
        FileHandle.standardError.write(Data("usage: ClaudeDrop --add <project> <file|url|text>...\n".utf8))
        exit(2)
    }
    do {
        let project = try Store.createProject(rest[0])
        let items = rest.dropFirst().map { arg -> StagedItem in
            let path = (arg as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                return StagedItem(payload: .file(URL(fileURLWithPath: path)))
            }
            return StagedItem(payload: Store.classify(arg))
        }
        let count = try Store.save(items, note: "", project: project)
        print("Added \(count) item(s) to \(project)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// MARK: Global hotkey (Carbon, needs no Accessibility permission)

var hotKeyAction: () -> Void = {}

func registerHotKey() -> Bool {
    var spec = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
        GetApplicationEventTarget(),
        { _, _, _ in
            DispatchQueue.main.async { hotKeyAction() }
            return noErr
        }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x434C_4450), id: 1)  // 'CLDP'
    return RegisterEventHotKey(hotKeyCode, hotKeyModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
}

// MARK: App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = DropModel()
    private var panel: DropPanel!
    private var statusItem: NSStatusItem!
    private var loginItem: NSMenuItem!
    private var pinItem: NSMenuItem!
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        buildStatusItem()
        model.onClose = { [weak self] in self?.hidePanel() }
        hotKeyAction = { [weak self] in self?.togglePanel() }
        let registered = registerHotKey()
        if !registered {
            NSLog("ClaudeDrop: could not register the hotkey %@ (already taken?)", hotKeyLabel)
        }
        installKeyMonitor()
        if CommandLine.arguments.contains("--show") { showPanel() }
    }

    private func buildPanel() {
        panel = DropPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "Drop for Claude"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.hidePanel() }
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let host = NSHostingView(rootView: DropView(model: model).padding(.top, 14))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "ClaudeDrop")
        let menu = NSMenu()
        menu.delegate = self
        let open = NSMenuItem(title: "Open Drop Box  (\(hotKeyLabel))", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let reveal = NSMenuItem(title: "Show Inbox in Finder", action: #selector(revealInbox), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        pinItem = NSMenuItem(title: "Pin to Top", action: #selector(togglePin), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)
        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClaudeDrop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        pinItem.state = model.pinned ? .on : .off
    }

    @objc private func togglePin() { model.pinned.toggle() }

    /// The app has no menu bar, so route the standard editing shortcuts by hand.
    /// ⌘V pastes into the note field when it has focus, otherwise it stages the clipboard.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                let key = event.charactersIgnoringModifiers?.lowercased()
            else { return event }
            let editing = self.panel.firstResponder is NSTextView
            switch key {
            case "w":
                self.hidePanel()
                return nil
            case "v":
                if editing {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } else {
                    self.model.pasteClipboard()
                }
                return nil
            case "c" where editing:
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                return nil
            case "x" where editing:
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                return nil
            case "a" where editing:
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                return nil
            case "z" where editing:
                NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                return nil
            default:
                return event
            }
        }
    }

    // MARK: Panel

    private func togglePanel() {
        if panel.isVisible && panel.isKeyWindow { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            previousApp = front
        }
        model.refresh()
        if !panel.isVisible {
            panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(
                    NSPoint(
                        x: visible.midX - panel.frame.width / 2,
                        y: visible.midY - panel.frame.height / 2 + visible.height * 0.12))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
    }

    private func hidePanel() {
        panel.orderOut(nil)
        previousApp?.activate()
        previousApp = nil
    }

    @objc private func openFromMenu() { showPanel() }

    @objc private func revealInbox() {
        try? FileManager.default.createDirectory(at: Store.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Store.root)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login setting"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
