import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Menu-bar-less (accessory) apps have no Edit menu, so route the standard text shortcuts ourselves.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = flags.contains(.shift)
        let action: Selector?
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": action = #selector(NSText.selectAll(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "z": action = Selector(shift ? "redo:" : "undo:")
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = SearchModel()
    private var panel: Panel!
    private var hotKey: HotKey!
    private var statusItem: NSStatusItem!
    private var bag = Set<AnyCancellable>()
    private var voice: VoiceController!
    private var topY: CGFloat = 0
    private let hotkeyDefault = "hotkey"   // "option" | "command"

    func applicationWillTerminate(_ n: Notification) {
        WhisperServer.shared.stop()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height(rows: 0)),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SearchView(model: model))
        host.sizingOptions = []
        panel.contentView = host

        model.dismiss = { [weak self] in self?.hide() }
        model.$panelHeight.receive(on: RunLoop.main).sink { [weak self] h in self?.resize(height: h) }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }

        hotKey = HotKey { [weak self] in MainActor.assumeIsolated { self?.toggle() } }
        applyHotkey()
        setupStatusItem()
        voice = VoiceController(model: model)
        voice.showAI = { [weak self] in
            guard let self else { return }
            if !self.panel.isVisible { self.show() }
            self.model.enterAI()
        }
        voice.start()
        Task { await model.index.refresh() }
    }

    // MARK: Panel

    private func toggle() { panel.isVisible ? hide() : show() }

    private func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        topY = vf.minY + vf.height * 0.75
        model.prepareForShow()
        let h = min(model.panelHeight, max(topY - vf.minY - 12, 120))
        panel.setFrame(NSRect(x: vf.midX - Metrics.width / 2, y: topY - h, width: Metrics.width, height: h), display: true)
        let target = panel.frame
        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: 0, dy: -14), display: false)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in            // a quick upward "zing" into place
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        model.focusTick += 1
        // select the kept text so typing replaces it, while arrow keys / clicking still edit it
        DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
    }

    private func hide() {
        if panel.isVisible { model.onVoiceStop(); panel.orderOut(nil) }
    }

    private func resize(height raw: CGFloat) {
        guard panel.isVisible else { return }
        let bottom = (panel.screen ?? NSScreen.main)?.visibleFrame.minY ?? 0
        let h = min(raw, max(topY - bottom - 12, 120))       // never run off the bottom of the screen
        var f = panel.frame
        f.size.height = h
        f.origin.y = topY - h
        panel.setFrame(f, display: true)
    }

    // MARK: Hotkey + menu bar

    private func applyHotkey() {
        let cmd = (UserDefaults.standard.string(forKey: hotkeyDefault) ?? "command") == "command"
        hotKey.register(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmd ? cmdKey : optionKey))
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "FRIDAY")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show F.R.I.D.A.Y", action: #selector(showFromMenu), keyEquivalent: "").target = self

        let hk = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, id) in [("⌘ Space (disable Spotlight's shortcut first)", "command"), ("⌥ Space", "option")] {
            let item = NSMenuItem(title: title, action: #selector(pickHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            sub.addItem(item)
        }
        hk.submenu = sub
        menu.addItem(hk)

        let engineItem = NSMenuItem(title: "AI Engine", action: nil, keyEquivalent: "")
        let engineMenu = NSMenu()
        for (title, id) in [("Claude Code (your Claude login)", "claude"), ("OpenRouter (API key)", "openrouter")] {
            let item = NSMenuItem(title: title, action: #selector(pickEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "engine:\(id)"
            engineMenu.addItem(item)
        }
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)
        menu.addItem(withTitle: "Set OpenRouter API Key…", action: #selector(setGrokKey), keyEquivalent: "").target = self

        let voiceItem = NSMenuItem(title: "Voice: say “Friday”", action: #selector(toggleVoice(_:)), keyEquivalent: "")
        voiceItem.target = self
        voiceItem.representedObject = "voice"
        menu.addItem(voiceItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit F.R.I.D.A.Y", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func toggleVoice(_ item: NSMenuItem) {
        VoiceController.enabled.toggle()
        if VoiceController.enabled { voice.start() } else { voice.stop() }
    }

    @objc private func pickEngine(_ item: NSMenuItem) {
        let id = (item.representedObject as? String)?.replacingOccurrences(of: "engine:", with: "") ?? "claude"
        UserDefaults.standard.set(id, forKey: "engine")
    }

    @objc private func setGrokKey() {
        let alert = NSAlert()
        alert.messageText = "OpenRouter API key"
        alert.informativeText = "Paste an OpenRouter API key (openrouter.ai/keys). It's stored in your Keychain. Leave empty to remove it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "xai-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            Keychain.set(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @objc private func showFromMenu() { show() }

    @objc private func pickHotkey(_ item: NSMenuItem) {
        UserDefaults.standard.set(item.representedObject as? String, forKey: hotkeyDefault)
        applyHotkey()
    }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change login item"
            a.informativeText = "\(error.localizedDescription)\n\nMove FRIDAY.app to /Applications and try again."
            a.runModal()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let current = UserDefaults.standard.string(forKey: hotkeyDefault) ?? "command"
        for item in menu.items {
            if item.representedObject as? String == "voice" {
                item.state = VoiceController.enabled && model.voiceState != .off ? .on : .off
                item.title = model.voiceError.map { "Voice unavailable: \($0)" }
                    ?? "Voice: say “Friday”" + (model.voiceEngine.isEmpty ? "" : " — \(model.voiceEngine)")
            }
            if item.action == #selector(toggleLogin(_:)) { item.state = SMAppService.mainApp.status == .enabled ? .on : .off }
            if let sub = item.submenu {
                let engine = Engine.useClaude ? "engine:claude" : "engine:openrouter"
                for s in sub.items {
                    let id = s.representedObject as? String
                    s.state = (id?.hasPrefix("engine:") == true ? id == engine : id == current) ? .on : .off
                }
            }
        }
    }
}

if CommandLine.arguments.contains("--mcp") {
    MCPServer.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
